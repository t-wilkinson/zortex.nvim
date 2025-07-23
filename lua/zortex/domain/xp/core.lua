-- xp/core.lua - Core XP calculations and formulas
local M = {}

-- Configuration (will be set by setup)
local cfg = {}

-- =============================================================================
-- Level Calculations
-- =============================================================================

-- Calculate XP required for a specific area level
function M.calculate_area_level_xp(level)
	local curve = cfg.area.level_curve
	return math.floor(curve.base * math.pow(level, curve.exponent))
end

-- Calculate XP required for a specific season level
function M.calculate_season_level_xp(level)
	local curve = cfg.project.season_curve
	return math.floor(curve.base * math.pow(level, curve.exponent))
end

-- Calculate level from total XP (area)
function M.calculate_area_level(xp)
	local level = 1
	while xp >= M.calculate_area_level_xp(level + 1) do
		level = level + 1
	end
	return level
end

-- Calculate level from total XP (season)
function M.calculate_season_level(xp)
	local level = 1
	while xp >= M.calculate_season_level_xp(level + 1) do
		level = level + 1
	end
	return level
end

-- Get progress towards next level
function M.get_level_progress(xp, level, level_calc_fn)
	local current_threshold = level_calc_fn(level)
	local next_threshold = level_calc_fn(level + 1)

	local progress = (xp - current_threshold) / (next_threshold - current_threshold)
	local xp_to_next = next_threshold - xp

	return {
		current_level = level,
		progress = math.max(0, math.min(1, progress)),
		xp_to_next = xp_to_next,
		current_threshold = current_threshold,
		next_threshold = next_threshold,
	}
end

-- =============================================================================
-- XP Multipliers and Modifiers
-- =============================================================================

-- Get time horizon multiplier for objectives
function M.get_time_multiplier(time_horizon)
	local multipliers = cfg.area.time_multipliers
	return multipliers[time_horizon:lower()] or 1.0
end

-- Calculate decay factor for old objectives
function M.calculate_decay_factor(days_old)
	local decay = cfg.area.decay
	if days_old <= decay.grace_days then
		return 1.0
	end

	local days_decaying = days_old - decay.grace_days
	return math.max(decay.min_factor, 1.0 - (decay.rate * days_decaying))
end

-- =============================================================================
-- Task XP Calculations
-- =============================================================================

-- Calculate XP for a task based on its position in the project
function M.calculate_task_xp(task_position, total_tasks)
	local rewards = cfg.project.task_rewards

	-- Single task project
	if total_tasks == 1 then
		return rewards.single_task or rewards.execution.base_xp
	end

	-- Completion bonus for final task
	if task_position == total_tasks then
		local base = rewards.execution.base_xp
		return math.floor(base * rewards.completion.multiplier + rewards.completion.bonus_xp)
	end

	-- Initiation stage (first N tasks)
	if task_position <= rewards.initiation.task_count then
		local base = rewards.initiation.base_xp

		if rewards.initiation.curve == "logarithmic" then
			-- Front-loaded: more XP for first tasks
			local factor = math.log(rewards.initiation.task_count - task_position + 2)
			return math.floor(base * rewards.initiation.multiplier * factor)
		else
			-- Flat multiplier
			return math.floor(base * rewards.initiation.multiplier)
		end
	end

	-- Execution stage (middle tasks)
	return rewards.execution.base_xp
end

-- Calculate total potential XP for a project
function M.calculate_project_total_xp(total_tasks)
	local total = 0
	for i = 1, total_tasks do
		total = total + M.calculate_task_xp(i, total_tasks)
	end
	return total
end

-- =============================================================================
-- Objective XP Calculations
-- =============================================================================

-- Calculate XP for completing an objective
function M.calculate_objective_xp(time_horizon, created_date)
	local base_xp = cfg.area.objective_base_xp or 500
	local time_mult = M.get_time_multiplier(time_horizon)

	-- Calculate decay if objective is old
	local decay_factor = 1.0
	if created_date then
		local days_old = math.floor((os.time() - created_date) / 86400)
		decay_factor = M.calculate_decay_factor(days_old)
	end

	return math.floor(base_xp * time_mult * decay_factor)
end

-- =============================================================================
-- Transfer Rates
-- =============================================================================

-- Calculate area XP from project XP
function M.calculate_area_transfer(project_xp, num_areas)
	if num_areas <= 0 then
		return 0
	end

	local transfer_rate = cfg.project.area_transfer_rate
	local total_transfer = math.floor(project_xp * transfer_rate)
	return math.floor(total_transfer / num_areas)
end

-- Calculate parent area XP from child area XP
function M.calculate_parent_bubble(child_xp, num_parents)
	if num_parents <= 0 then
		return 0
	end

	local bubble_rate = cfg.area.bubble_percentage
	local total_bubble = math.floor(child_xp * bubble_rate)
	return math.floor(total_bubble / num_parents)
end

-- =============================================================================
-- Season Tiers
-- =============================================================================

-- Get tier information for a season level
function M.get_season_tier(level)
	local tiers = cfg.seasons.tiers
	local current_tier = nil
	local next_tier = nil

	for i, tier in ipairs(tiers) do
		if level >= tier.required_level then
			current_tier = tier
			next_tier = tiers[i + 1]
		else
			if not next_tier then
				next_tier = tier
			end
			break
		end
	end

	return {
		current = current_tier,
		next = next_tier,
		is_max_tier = current_tier and not next_tier,
	}
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup(config)
	cfg = config
end

-- =============================================================================
-- Utility Functions
-- =============================================================================

-- Format XP display
function M.format_xp(xp)
	if xp >= 1000000 then
		return string.format("%.1fM", xp / 1000000)
	elseif xp >= 1000 then
		return string.format("%.1fK", xp / 1000)
	else
		return tostring(xp)
	end
end

-- Get color for level (for UI)
function M.get_level_color(level, max_level)
	max_level = max_level or 20
	local ratio = math.min(1, level / max_level)

	if ratio < 0.25 then
		return "DiagnosticWarn" -- Levels 1-5
	elseif ratio < 0.5 then
		return "DiagnosticInfo" -- Levels 6-10
	elseif ratio < 0.75 then
		return "DiagnosticOk" -- Levels 11-15
	else
		return "DiagnosticHint" -- Levels 16+
	end
end

return M

