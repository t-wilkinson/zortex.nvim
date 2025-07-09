-- features/xp_config.lua - XP System Configuration
local M = {}

-- =============================================================================
-- Default Configuration
-- =============================================================================

M.defaults = {
	-- Area XP System (Long-term Mastery)
	area = {
		-- Exponential curve: XP = base * level^exponent
		level_curve = {
			base = 1000,
			exponent = 2.5,
		},

		-- XP bubbling to parent areas
		bubble_percentage = 0.75, -- 75% of XP bubbles up

		-- Time horizon multipliers for objectives
		time_multipliers = {
			daily = 0.1, -- Very short term
			weekly = 0.25,
			monthly = 0.5,
			quarterly = 1.0,
			yearly = 3.0, -- Long-term goals worth more
			["5year"] = 10.0,
		},

		-- Relevance decay (per day)
		decay_rate = 0.001, -- 0.1% per day
		decay_grace_days = 30, -- No decay for first 30 days
	},

	-- Project XP System (Seasonal Momentum)
	project = {
		-- Polynomial curve for seasonal levels: XP = base * level^exponent
		season_curve = {
			base = 100,
			exponent = 1.2,
		},

		-- 3-stage task reward structure
		task_rewards = {
			-- Initiation stage (first N tasks)
			initiation = {
				task_count = 3,
				base_xp = 50,
				curve = "logarithmic", -- Front-loaded rewards
				multiplier = 2.0,
			},

			-- Execution stage (main body)
			execution = {
				base_xp = 20,
				curve = "linear",
			},

			-- Completion bonus (final task)
			completion = {
				multiplier = 5.0, -- 5x the execution XP
				bonus_xp = 200, -- Plus flat bonus
			},
		},

		-- Integration with Area system
		area_transfer_rate = 0.10, -- 10% of project XP goes to area
	},

	-- Season Configuration
	seasons = {
		-- Default season length (days)
		default_length = 90, -- Quarterly

		-- Battle pass tiers
		tiers = {
			{ name = "Bronze", required_level = 1 },
			{ name = "Silver", required_level = 5 },
			{ name = "Gold", required_level = 10 },
			{ name = "Platinum", required_level = 15 },
			{ name = "Diamond", required_level = 20 },
			{ name = "Master", required_level = 30 },
		},

		-- Rewards can be customized per season
		tier_rewards = {
			Bronze = "Unlock custom theme",
			Silver = "Achievement badge",
			Gold = "Priority support",
			Platinum = "Exclusive content",
			Diamond = "Beta features",
			Master = "Season champion title",
		},
	},
}

-- Current configuration
M.config = {}

-- =============================================================================
-- Configuration Management
-- =============================================================================

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
	return M.config
end

function M.get(path)
	local value = M.config
	for key in path:gmatch("[^%.]+") do
		value = value[key]
		if value == nil then
			return nil
		end
	end
	return value
end

-- =============================================================================
-- XP Calculation Functions
-- =============================================================================

-- Calculate XP required for area level
function M.calculate_area_level_xp(level)
	local curve = M.config.area.level_curve
	return math.floor(curve.base * math.pow(level, curve.exponent))
end

-- Calculate XP required for season level
function M.calculate_season_level_xp(level)
	local curve = M.config.project.season_curve
	return math.floor(curve.base * math.pow(level, curve.exponent))
end

-- Calculate time horizon multiplier
function M.get_time_multiplier(time_horizon)
	local multipliers = M.config.area.time_multipliers
	return multipliers[time_horizon:lower()] or 1.0
end

-- Calculate relevance decay
function M.calculate_decay_factor(days_old)
	local decay = M.config.area.decay
	if days_old <= decay.grace_days then
		return 1.0
	end

	local days_decaying = days_old - decay.grace_days
	return math.max(0.1, 1.0 - (decay.rate * days_decaying))
end

-- Calculate task XP based on position in project
function M.calculate_task_xp(task_position, total_tasks)
	local rewards = M.config.project.task_rewards

	-- Completion bonus for final task
	if task_position == total_tasks and total_tasks > 1 then
		local base = rewards.execution.base_xp
		return math.floor(base * rewards.completion.multiplier + rewards.completion.bonus_xp)
	end

	-- Initiation stage
	if task_position <= rewards.initiation.task_count then
		local base = rewards.initiation.base_xp
		if rewards.initiation.curve == "logarithmic" then
			-- Front-loaded: more XP for first tasks
			local factor = math.log(rewards.initiation.task_count - task_position + 2)
			return math.floor(base * rewards.initiation.multiplier * factor)
		end
		return math.floor(base * rewards.initiation.multiplier)
	end

	-- Execution stage
	return rewards.execution.base_xp
end

-- =============================================================================
-- Season Management
-- =============================================================================

-- Get current tier based on level
function M.get_season_tier(level)
	local tiers = M.config.seasons.tiers
	local current_tier = nil

	for _, tier in ipairs(tiers) do
		if level >= tier.required_level then
			current_tier = tier
		else
			break
		end
	end

	return current_tier
end

-- Get next tier
function M.get_next_tier(level)
	local tiers = M.config.seasons.tiers

	for _, tier in ipairs(tiers) do
		if level < tier.required_level then
			return tier
		end
	end

	return nil -- Max tier reached
end

-- Calculate progress to next tier
function M.calculate_tier_progress(current_xp, current_level)
	local current_required = M.calculate_season_level_xp(current_level)
	local next_required = M.calculate_season_level_xp(current_level + 1)

	local progress = (current_xp - current_required) / (next_required - current_required)
	return math.max(0, math.min(1, progress))
end

return M
