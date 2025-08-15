-- services/xp/calculator.lua - Core XP calculations and formulas
local M = {}

-- Configuration (will be set by setup)
local cfg = {} -- Config.xp

-- =============================================================================
-- Size Multipliers
-- =============================================================================

-- Task size definitions with XP multipliers
M.TASK_SIZES = {
	xs = { duration = 15, multiplier = 0.5, base_xp = 10 },
	sm = { duration = 30, multiplier = 0.8, base_xp = 20 },
	md = { duration = 60, multiplier = 1.0, base_xp = 30 },
	lg = { duration = 120, multiplier = 1.5, base_xp = 50 },
	xl = { duration = 240, multiplier = 2.0, base_xp = 80 },
}

-- Project size definitions with global multipliers
M.PROJECT_SIZES = {
	xs = { multiplier = 0.5 },
	sm = { multiplier = 0.8 },
	md = { multiplier = 1.0 },
	lg = { multiplier = 1.5 },
	xl = { multiplier = 2.0 },
	epic = { multiplier = 3.0 },
	legendary = { multiplier = 5.0 },
	mythic = { multiplier = 8.0 },
	ultimate = { multiplier = 12.0 },
}

-- =============================================================================
-- Level Calculations (unchanged)
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
-- Project-Centric XP Calculations
-- =============================================================================

-- Calculate total XP for a project based on its tasks
function M.calculate_project_xp(project_data)
	local total_xp = 0
	local completed_xp = 0

	-- Get project size multiplier
	local project_size = project_data.attributes and project_data.attributes.size or "md"
	local project_multiplier = M.PROJECT_SIZES[project_size] and M.PROJECT_SIZES[project_size].multiplier or 1.0

	-- Priority and importance multipliers
	local priority_mult = 1.0
	local importance_mult = 1.0

	if project_data.attributes then
		if project_data.attributes.p then
			priority_mult = M.get_priority_multiplier(project_data.attributes.p)
		end
		if project_data.attributes.i then
			importance_mult = M.get_importance_multiplier(project_data.attributes.i)
		end
	end

	-- Calculate XP from tasks
	for _, task in ipairs(project_data.tasks or {}) do
		local task_size = task.attributes and task.attributes.size or "md"
		local task_def = M.TASK_SIZES[task_size] or M.TASK_SIZES.md
		local task_xp = task_def.base_xp

		-- Apply task-specific modifiers
		if task.attributes then
			if task.attributes.p then
				task_xp = task_xp * M.get_priority_multiplier(task.attributes.p)
			end
			if task.attributes.i then
				task_xp = task_xp * M.get_importance_multiplier(task.attributes.i)
			end
		end

		total_xp = total_xp + task_xp

		if task.completed then
			completed_xp = completed_xp + task_xp
		end
	end

	-- Apply project-level multipliers
	total_xp = math.floor(total_xp * project_multiplier * priority_mult * importance_mult)
	completed_xp = math.floor(completed_xp * project_multiplier * priority_mult * importance_mult)

	-- Add completion bonus if project is done
	if project_data.completed_tasks == project_data.total_tasks and project_data.total_tasks > 0 then
		local completion_bonus = math.floor(total_xp * 0.2) -- 20% completion bonus
		completed_xp = completed_xp + completion_bonus
		total_xp = total_xp + completion_bonus
	end

	return {
		total_xp = total_xp,
		earned_xp = completed_xp,
		remaining_xp = total_xp - completed_xp,
		completion_percentage = project_data.total_tasks > 0
				and (project_data.completed_tasks / project_data.total_tasks)
			or 0,
	}
end

-- Calculate XP for standalone tasks (not in a project)
function M.calculate_standalone_task_xp(task)
	local task_size = task.attributes and task.attributes.size or "md"
	local task_def = M.TASK_SIZES[task_size] or M.TASK_SIZES.md
	local base_xp = task_def.base_xp * 1.5 -- 50% bonus for standalone tasks

	-- Apply priority/importance modifiers
	if task.attributes then
		if task.attributes.p then
			base_xp = base_xp * M.get_priority_multiplier(task.attributes.p)
		end
		if task.attributes.i then
			base_xp = base_xp * M.get_importance_multiplier(task.attributes.i)
		end
	end

	return math.floor(base_xp)
end

-- =============================================================================
-- XP Multipliers and Modifiers
-- =============================================================================

-- Get priority multiplier
function M.get_priority_multiplier(priority)
	local multipliers = {
		["1"] = 1.5,
		["2"] = 1.2,
		["3"] = 1.0,
	}
	return multipliers[tostring(priority)] or 1.0
end

-- Get importance multiplier
function M.get_importance_multiplier(importance)
	local multipliers = {
		["1"] = 1.5,
		["2"] = 1.2,
		["3"] = 1.0,
	}
	return multipliers[tostring(importance)] or 1.0
end

-- Get time horizon multiplier for objectives
function M.get_time_multiplier(time_horizon)
	local multipliers = cfg.area.time_multipliers
	return multipliers[time_horizon:lower()] or 1.0
end

-- Calculate decay factor for old objectives
function M.calculate_decay_factor(days_old)
	local decay = cfg.area.decay_rate
	local grace = cfg.area.decay_grace_days or 30

	if days_old <= grace then
		return 1.0
	end

	local days_decaying = days_old - grace
	return math.max(0.5, 1.0 - (decay * days_decaying))
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

	local transfer_rate = cfg.project.area_transfer_rate or 0.1
	local total_transfer = math.floor(project_xp * transfer_rate)
	return math.floor(total_transfer / num_areas)
end

-- Calculate parent area XP from child area XP
function M.calculate_parent_bubble(child_xp, num_parents)
	if num_parents <= 0 then
		return 0
	end

	local bubble_rate = cfg.area.bubble_percentage or 0.75
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

function M.setup(opts)
	cfg = opts
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
