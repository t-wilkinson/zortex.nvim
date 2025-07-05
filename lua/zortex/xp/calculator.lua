-- XP calculation for Zortex XP system
local M = {}

-- Calculate total XP for a task
function M.calculate_total_xp(task)
	local xp = require("zortex.xp")
	local state = require("zortex.xp.state")
	local graph = require("zortex.xp.graph")
	local tracker = require("zortex.xp.tracker")

	local cfg = xp.get_config()

	-- Get base XP
	local base_xp = M.calculate_base_xp(task, cfg)

	-- Calculate multipliers
	local multipliers = M.calculate_multipliers(task, cfg)

	-- Apply multipliers to base
	local modified_xp = base_xp
	for name, mult in pairs(multipliers) do
		modified_xp = modified_xp * mult
	end
	modified_xp = math.floor(modified_xp)

	-- Calculate bonuses
	local bonuses = M.calculate_bonuses(task, cfg)

	-- Calculate penalties
	local penalties = M.calculate_penalties(task, cfg)

	-- Total XP
	local total_xp = modified_xp + bonuses.total - penalties.total

	return {
		total = math.max(1, total_xp), -- Minimum 1 XP
		base = base_xp,
		modified = modified_xp,
		multipliers = multipliers,
		bonuses = bonuses,
		penalties = penalties,
	}
end

-- Calculate base XP based on distance from vision
function M.calculate_base_xp(task, cfg)
	local graph = require("zortex.xp.graph")

	-- Get task distance from vision
	local node_id = M.get_task_node_id(task)
	local distance = graph.get_distance(node_id)

	-- Store distance on task for logging
	task.distance = distance

	-- Special handling for project tasks
	if task.in_project or (task.file and task.file:match("project")) then
		-- Project tasks get a minimum multiplier even if orphaned
		if distance >= 999999 then
			-- Orphan project task - give better base XP than regular orphan
			return cfg.base_xp * (cfg.project_orphan_multiplier or 0.7)
		end
	end

	-- Base XP calculation
	if distance >= 999999 then -- Changed from math.huge
		-- Orphan task - still give reasonable XP
		return cfg.orphan_xp or 5
	elseif cfg.distance_multipliers and cfg.distance_multipliers[distance] then
		-- Use specific distance multiplier
		return cfg.base_xp * cfg.distance_multipliers[distance]
	else
		-- Use decay formula or default multiplier
		if cfg.distance_multipliers and cfg.distance_multipliers.default then
			return cfg.base_xp * cfg.distance_multipliers.default
		else
			local decay = cfg.distance_decay or 0.8
			return math.floor(cfg.base_xp * math.pow(decay, distance))
		end
	end
end

-- Calculate all multipliers
function M.calculate_multipliers(task, cfg)
	local multipliers = {}

	-- Priority multiplier
	if task.priority and cfg.priority[task.priority] then
		multipliers.priority = cfg.priority[task.priority]
	end

	-- Size multiplier
	local size = task.size or "m"
	if cfg.size_multipliers[size] then
		multipliers.size = cfg.size_multipliers[size]
	end

	-- Urgency multiplier
	multipliers.urgency = M.calculate_urgency_multiplier(task, cfg)

	-- Heat multiplier
	multipliers.heat = M.calculate_heat_multiplier(task, cfg)

	-- Fatigue multiplier
	multipliers.fatigue = M.calculate_fatigue_multiplier(task, cfg)

	-- Habit multiplier
	if task.habit then
		multipliers.habit = cfg.habits.completion_multiplier or 1.5
	end

	-- Resource creation multiplier
	if task.type == "resource" and task.action == "create" then
		multipliers.resource = cfg.resources.creation_multiplier or 1.2
	end

	return multipliers
end

-- Calculate urgency based on due date
function M.calculate_urgency_multiplier(task, cfg)
	if not task.due then
		return 1.0
	end

	local due_date = M.parse_date(task.due)
	if not due_date then
		return 1.0
	end

	local days_until = (due_date - os.time()) / 86400

	if days_until < 0 then
		-- Overdue
		return cfg.urgency.overdue or 2.0
	elseif days_until < 1 then
		-- Due today
		return cfg.urgency.today or 1.5
	else
		-- Future due date
		local factor = cfg.urgency.day_factor or 0.2
		return 1 + factor / (days_until + 1)
	end
end

-- Calculate heat multiplier from parent objective
function M.calculate_heat_multiplier(task, cfg)
	local tracker = require("zortex.xp.tracker")
	local heat = tracker.get_task_heat(task)
	return heat
end

-- Calculate fatigue multiplier
function M.calculate_fatigue_multiplier(task, cfg)
	local tracker = require("zortex.xp.tracker")
	return tracker.get_fatigue_multiplier(task)
end

-- Calculate bonuses
function M.calculate_bonuses(task, cfg)
	local state = require("zortex.xp.state")
	local bonuses = {
		duration = 0,
		streak = 0,
		combo = 0,
		habit_chain = 0,
		milestone = 0,
		total = 0,
	}

	-- Duration bonus
	if task.duration then
		bonuses.duration = math.floor(cfg.xp_per_hour * task.duration)
	end

	-- Streak bonus
	if state.data.current_streak > 0 then
		bonuses.streak = cfg.streak.daily_bonus * state.data.current_streak

		-- Cap streak bonus
		local cap = state.data.daily_xp * cfg.streak.cap_pct_of_day
		bonuses.streak = math.min(bonuses.streak, cap)
	end

	-- Combo bonus
	local project = M.find_parent_project(task)
	if project then
		local combo_count = state.update_combo(project)
		if combo_count > 1 then
			bonuses.combo = cfg.combo.init + (combo_count - 1) * cfg.combo.step
		end
	end

	-- Habit chain bonus
	if task.habit then
		local chain_length = M.get_habit_chain(task.habit)
		if chain_length > 0 then
			bonuses.habit_chain = cfg.habits.chain_bonus * chain_length
		end
	end

	-- Milestone bonuses (budget savings, etc)
	bonuses.milestone = M.check_milestones(task, cfg)

	-- Total
	bonuses.total = bonuses.duration + bonuses.streak + bonuses.combo + bonuses.habit_chain + bonuses.milestone

	return bonuses
end

-- Calculate penalties
function M.calculate_penalties(task, cfg)
	local state = require("zortex.xp.state")
	local penalties = {
		budget = 0,
		resource = 0,
		repeat_miss = 0,
		total = 0,
	}

	-- Budget penalty
	if task.budget and cfg.budget.enabled then
		local category = task.category or "discretionary"
		local category_mult = 1.0

		if cfg.budget.categories[category] then
			category_mult = cfg.budget.categories[category].multiplier
		end

		-- Check exemptions
		local is_exempt = M.is_budget_exempt(task, cfg)

		if not is_exempt then
			penalties.budget = task.budget * cfg.budget.xp_per_dollar * category_mult
			state.add_expense(task.budget, category)
		end
	end

	-- Resource consumption penalty
	if task.type == "resource" and task.action == "consume" then
		penalties.resource = cfg.resources.consumption_penalty * (task.amount or 1)
	end

	-- Missed repeat penalty
	if task.repeat_type and M.is_repeat_missed(task) then
		penalties.repeat_miss = cfg.repeat_task.miss_penalty or 50
	end

	-- Total
	penalties.total = penalties.budget + penalties.resource + penalties.repeat_miss

	return penalties
end

-- Helper functions

function M.get_task_node_id(task)
	if task.name then
		return task.name
	else
		return task.file .. ":" .. (task.text or task.line_number or "")
	end
end

function M.find_parent_project(task)
	local graph = require("zortex.xp.graph")

	if task.links then
		for _, link in ipairs(task.links) do
			local node = graph.get_node(link)
			if node and node.type == "project" then
				return link
			end
		end
	end

	-- Check backlinks
	return graph.find_parent_of_type(M.get_task_node_id(task), "project")
end

function M.parse_date(date_str)
	-- Parse various date formats
	local patterns = {
		"(%d+)-(%d+)-(%d+)", -- YYYY-MM-DD
		"(%d+)/(%d+)/(%d+)", -- MM/DD/YYYY or DD/MM/YYYY
		"(%d+)%.(%d+)%.(%d+)", -- DD.MM.YYYY
	}

	for _, pattern in ipairs(patterns) do
		local a, b, c = date_str:match(pattern)
		if a then
			-- Assume YYYY-MM-DD for first pattern
			if pattern:match("%-") then
				return os.time({ year = a, month = b, day = c })
			else
				-- Handle other formats based on locale
				-- This is simplified - you might want more robust parsing
				return os.time({ year = c, month = a, day = b })
			end
		end
	end

	-- Relative dates
	if date_str:lower() == "today" then
		return os.time()
	elseif date_str:lower() == "tomorrow" then
		return os.time() + 86400
	end

	return nil
end

function M.get_habit_chain(habit_id)
	local state = require("zortex.xp.state")
	local habit = state.data.habits.daily[habit_id]

	if habit then
		return habit.current_chain or 0
	end

	return 0
end

function M.check_milestones(task, cfg)
	local state = require("zortex.xp.state")
	local bonus = 0

	-- Check budget savings milestones
	if cfg.budget.savings_milestones then
		for amount, xp in pairs(cfg.budget.savings_milestones) do
			if state.data.budget.saved_total >= amount and state.data.budget.last_milestone < amount then
				bonus = bonus + xp
				state.data.budget.last_milestone = amount
			end
		end
	end

	return bonus
end

function M.is_budget_exempt(task, cfg)
	if not cfg.budget.exempt_areas then
		return false
	end

	local graph = require("zortex.xp.graph")
	local task_areas = graph.find_task_areas(task)

	for _, area in ipairs(task_areas) do
		for _, exempt in ipairs(cfg.budget.exempt_areas) do
			if area == exempt then
				return true
			end
		end
	end

	return false
end

function M.is_repeat_missed(task)
	if not task.repeat_type then
		return false
	end

	local state = require("zortex.xp.state")
	local task_id = M.get_task_node_id(task)
	local last_completed = state.data.completed_tasks[task_id]

	if not last_completed then
		return false
	end

	local days_since = (os.time() - last_completed) / 86400

	if task.repeat_type == "daily" and days_since > 1 then
		return true
	elseif task.repeat_type == "weekly" and days_since > 7 then
		return true
	elseif task.repeat_type == "monthly" and days_since > 30 then
		return true
	end

	return false
end

return M
