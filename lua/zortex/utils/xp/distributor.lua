-- domain/xp/distributor.lua - Handles XP distribution logic and rules
local M = {}

local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local xp_store = require("zortex.stores.xp")
local xp_calculator = require("zortex.utils.xp.calculator")

-- =============================================================================
-- Distribution Rules
-- =============================================================================

-- Distribution configuration
local distribution_rules = {
	-- Task XP distribution
	task = {
		project = 1.0, -- 100% to project
		season = 1.0, -- 100% to season
		area = 0.1, -- 10% to each linked area
		parent_bubble = 0.75, -- 75% bubbles to parent areas
	},

	-- Objective XP distribution
	objective = {
		area = 1.0, -- 100% to each linked area
		parent_bubble = 0.75, -- 75% bubbles to parent areas
	},

	-- Daily review XP
	daily_review = {
		season = 1.0, -- 100% to season
		bonus_multiplier = 1.5, -- 50% bonus for consistency
	},
}

-- =============================================================================
-- Distribution Functions
-- =============================================================================

-- Distribute XP with full tracking
function M.distribute(source_type, source_id, base_amount, targets)
	local stop_timer = Logger.start_timer("xp_distributor.distribute")

	local distribution = {
		source = {
			type = source_type,
			id = source_id,
			base_amount = base_amount,
		},
		distributions = {},
		total_distributed = 0,
		timestamp = os.time(),
	}

	-- Apply distribution rules based on source type
	if source_type == "task" then
		M._distribute_task_xp(distribution, targets)
	elseif source_type == "objective" then
		M._distribute_objective_xp(distribution, targets)
	elseif source_type == "daily_review" then
		M._distribute_daily_review_xp(distribution, targets)
	else
		Logger.warn("xp_distributor", "Unknown source type", { type = source_type })
	end

	-- Emit distribution completed event
	EventBus.emit("xp:distributed", distribution)

	Logger.debug("xp_distributor", "Distribution completed", {
		source = source_type,
		total = distribution.total_distributed,
		targets = #distribution.distributions,
	})

	stop_timer()
	return distribution
end

-- Distribute task XP
function M._distribute_task_xp(distribution, targets)
	local rules = distribution_rules.task
	local base_xp = distribution.source.base_amount

	-- 1. Project XP (100%)
	if targets.project_name then
		local project_xp = math.floor(base_xp * rules.project)

		M._add_distribution(distribution, {
			type = "project",
			name = targets.project_name,
			amount = project_xp,
			rate = rules.project,
		})
	end

	-- 2. Season XP (100%)
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		local season_xp = math.floor(base_xp * rules.season)

		M._add_distribution(distribution, {
			type = "season",
			name = season_data.current_season.name,
			amount = season_xp,
			rate = rules.season,
		})
	end

	-- 3. Area XP (10% to each)
	if targets.area_links and #targets.area_links > 0 then
		local area_xp_total = math.floor(base_xp * rules.area)
		local area_xp_each = math.floor(area_xp_total / #targets.area_links)

		for _, area_link in ipairs(targets.area_links) do
			local area_path = require("zortex.xp.areas").parse_area_path(area_link)
			if area_path then
				M._add_distribution(distribution, {
					type = "area",
					name = area_path,
					amount = area_xp_each,
					rate = rules.area / #targets.area_links,
					bubble_to_parents = true,
				})
			end
		end
	end
end

-- Distribute objective XP
function M._distribute_objective_xp(distribution, targets)
	local rules = distribution_rules.objective
	local base_xp = distribution.source.base_amount

	-- Area XP (100% to each linked area)
	if targets.area_links and #targets.area_links > 0 then
		local area_xp_each = math.floor(base_xp / #targets.area_links)

		for _, area_link in ipairs(targets.area_links) do
			local area_path = require("zortex.xp.areas").parse_area_path(area_link)
			if area_path then
				M._add_distribution(distribution, {
					type = "area",
					name = area_path,
					amount = area_xp_each,
					rate = rules.area / #targets.area_links,
					bubble_to_parents = true,
				})
			end
		end
	end
end

-- Distribute daily review XP
function M._distribute_daily_review_xp(distribution, targets)
	local rules = distribution_rules.daily_review
	local base_xp = distribution.source.base_amount

	-- Apply consistency bonus if applicable
	if targets.consecutive_days and targets.consecutive_days >= 7 then
		base_xp = math.floor(base_xp * rules.bonus_multiplier)
		distribution.source.bonus_applied = true
		distribution.source.bonus_reason = "7+ day streak"
	end

	-- Season XP (100%)
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		M._add_distribution(distribution, {
			type = "season",
			name = season_data.current_season.name,
			amount = base_xp,
			rate = rules.season,
		})
	end
end

-- Add a distribution entry
function M._add_distribution(distribution, entry)
	table.insert(distribution.distributions, entry)
	distribution.total_distributed = distribution.total_distributed + entry.amount

	-- Log high-value distributions
	if entry.amount >= 100 then
		Logger.info("xp_distributor", "High-value distribution", entry)
	end
end

-- =============================================================================
-- XP Flow Management
-- =============================================================================

-- Initialize distributor with event listeners
function M.init()
	-- Listen for XP awarded events and handle special distributions
	EventBus.on("xp:awarded", function(data)
		-- Handle parent area bubbling
		if data.distribution then
			for _, dist in ipairs(data.distribution.distributions) do
				if dist.type == "area" and dist.bubble_to_parents then
					M._bubble_to_parent_areas(dist.name, dist.amount)
				end
			end
		end
	end, {
		priority = 70,
		name = "xp_distributor.bubble_handler",
	})

	-- Track distribution statistics
	EventBus.on("xp:distributed", function(data)
		M._update_distribution_stats(data)
	end, {
		priority = 10,
		name = "xp_distributor.stats_tracker",
	})

	Logger.info("xp_distributor", "XP Distributor initialized")
end

-- Bubble XP to parent areas
function M._bubble_to_parent_areas(area_path, base_amount)
	local parent_links = M._get_parent_area_links(area_path)
	if #parent_links == 0 then
		return
	end

	local bubble_amount = math.floor(base_amount * distribution_rules.task.parent_bubble)
	local amount_per_parent = math.floor(bubble_amount / #parent_links)

	for _, parent_path in ipairs(parent_links) do
		require("zortex.xp.areas").add_xp(parent_path, amount_per_parent, nil)
	end

	Logger.debug("xp_distributor", "Bubbled XP to parents", {
		child = area_path,
		parents = parent_links,
		amount = amount_per_parent,
	})
end

-- Get parent area links (simplified for now)
function M._get_parent_area_links(area_path)
	-- Extract parent from path (e.g., "Tech/Programming/Lua" -> "Tech/Programming")
	local parts = {}
	for part in area_path:gmatch("[^/]+") do
		table.insert(parts, part)
	end

	if #parts <= 1 then
		return {}
	end

	-- Remove last part to get parent
	table.remove(parts)
	return { table.concat(parts, "/") }
end

-- Update distribution statistics
function M._update_distribution_stats(distribution)
	-- This could write to a stats store for analytics
	Logger.debug("xp_distributor", "Distribution stats", {
		source = distribution.source.type,
		total = distribution.total_distributed,
		targets = #distribution.distributions,
	})
end

-- =============================================================================
-- Utility Functions
-- =============================================================================

-- Calculate effective XP with all modifiers
function M.calculate_effective_xp(base_xp, modifiers)
	local effective = base_xp

	-- Apply time decay
	if modifiers.days_old then
		local decay_factor = xp_calculator.calculate_decay_factor(modifiers.days_old)
		effective = math.floor(effective * decay_factor)
	end

	-- Apply priority multiplier
	if modifiers.priority then
		local mult = xp_calculator.get_priority_multiplier(modifiers.priority)
		effective = math.floor(effective * mult)
	end

	-- Apply importance multiplier
	if modifiers.importance then
		local mult = xp_calculator.get_importance_multiplier(modifiers.importance)
		effective = math.floor(effective * mult)
	end

	return effective
end

-- Validate distribution targets
function M.validate_targets(source_type, targets)
	if source_type == "task" then
		return targets.project_name ~= nil
	elseif source_type == "objective" then
		return targets.area_links and #targets.area_links > 0
	elseif source_type == "daily_review" then
		return true
	end

	return false
end

return M
