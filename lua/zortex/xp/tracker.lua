-- Feature tracking for Zortex XP system
local M = {}

-- Initialize tracker
function M.initialize()
	-- Set up any initial tracking state
	M.update_heat()
end

-- Track task completion
function M.track_completion(task)
	local state = require("zortex.xp.state")

	-- Track habits
	if task.habit then
		M.track_habit_completion(task.habit, task.frequency or "daily")
	end

	-- Track resources
	if task.type == "resource" then
		M.track_resource(task.name, task.action, task.amount)
	end

	-- Track budget
	if task.budget then
		M.track_budget(task)
	end

	-- Update project fatigue
	if task.duration then
		M.update_project_fatigue(task)
	end

	-- Update objective heat
	M.update_task_heat(task)
end

-- Habit tracking
function M.track_habit_completion(habit_id, frequency)
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	-- Track in state
	local completed = state.track_habit(habit_id, frequency)

	if completed then
		-- Award habit bonus XP
		local bonus_xp = cfg.habits[frequency .. "_bonus"] or cfg.habits.daily_bonus

		-- Add chain multiplier
		local habit_data = state.data.habits[frequency][habit_id]
		if habit_data and habit_data.current_chain > 1 then
			bonus_xp = bonus_xp * (1 + (habit_data.current_chain - 1) * 0.1)
		end

		-- Create a pseudo-task for XP logging
		local habit_task = {
			text = "Habit: " .. habit_id,
			type = "habit",
			areas = {},
		}

		state.award_xp(bonus_xp, habit_task, {
			total = bonus_xp,
			base = bonus_xp,
			bonuses = { habit = bonus_xp },
		})

		return true
	end

	return false
end

-- Resource tracking
function M.track_resource(resource_name, action, amount)
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	amount = amount or 1

	-- Track in state
	state.track_resource(resource_name, action, amount)

	-- Award/deduct XP based on action
	local xp_amount = 0

	if action == "create" and cfg.resources.creation_bonus then
		xp_amount = cfg.resources.creation_bonus * amount
	elseif action == "consume" and cfg.resources.consumption_penalty then
		xp_amount = cfg.resources.consumption_penalty * amount
	elseif action == "share" and cfg.resources.sharing_bonus then
		xp_amount = cfg.resources.sharing_bonus * amount
	end

	if xp_amount ~= 0 then
		-- Create pseudo-task for logging
		local resource_task = {
			text = string.format("Resource %s: %s x%d", action, resource_name, amount),
			type = "resource",
			areas = {},
		}

		state.award_xp(xp_amount, resource_task, {
			total = xp_amount,
			base = xp_amount,
			bonuses = { resource = xp_amount },
		})
	end
end

-- Budget tracking
function M.track_budget(task)
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	if not task.budget or not cfg.budget.enabled then
		return
	end

	-- Check if it's a saving (negative expense)
	if task.budget < 0 then
		state.add_savings(math.abs(task.budget))
	else
		state.add_expense(task.budget, task.category)
	end
end

-- Heat tracking
function M.get_task_heat(task)
	local state = require("zortex.xp.state")
	local graph = require("zortex.xp.graph")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	-- Find parent objective
	local objectives = M.find_task_objectives(task)

	if #objectives == 0 then
		return cfg.heat.default or 1.0
	end

	-- Average heat from all connected objectives
	local total_heat = 0
	for _, obj_id in ipairs(objectives) do
		total_heat = total_heat + state.get_objective_heat(obj_id)
	end

	return total_heat / #objectives
end

function M.update_task_heat(task)
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	-- Find parent objectives
	local objectives = M.find_task_objectives(task)

	-- Increase heat for completed objectives
	for _, obj_id in ipairs(objectives) do
		local current_heat = state.get_objective_heat(obj_id)
		local new_heat = math.min(cfg.heat.max or 2.0, current_heat + cfg.heat.completion_increase or 0.1)
		state.set_objective_heat(obj_id, new_heat)
	end
end

function M.update_heat()
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	-- Decay all objective heat values
	local current_time = os.time()

	for obj_id, heat_data in pairs(state.data.objective_heat) do
		if type(heat_data) == "table" then
			local weeks_elapsed = (current_time - heat_data.last_update) / (7 * 24 * 60 * 60)
			if weeks_elapsed >= 1 then
				local decay = cfg.heat.decay_per_week * weeks_elapsed
				local new_value = math.max(cfg.heat.min or 0.1, heat_data.value - decay)
				state.set_objective_heat(obj_id, new_value)
			end
		end
	end
end

-- Fatigue tracking
function M.update_project_fatigue(task)
	local state = require("zortex.xp.state")
	local graph = require("zortex.xp.graph")

	if not task.duration then
		return
	end

	-- Find parent project
	local calculator = require("zortex.xp.calculator")
	local project = calculator.find_parent_project(task)

	if project then
		state.update_project_fatigue(project, task.duration)
	end
end

function M.get_fatigue_multiplier(task)
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	-- Find parent project
	local calculator = require("zortex.xp.calculator")
	local project = calculator.find_parent_project(task)

	if not project then
		return 1.0
	end

	local hours_today = state.get_project_fatigue(project)

	if hours_today > cfg.fatigue.after_hours then
		return cfg.fatigue.penalty
	end

	return 1.0
end

-- Check habits for completion
function M.check_habits()
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	local today = os.date("%Y-%m-%d")

	-- Check daily habits
	for habit_id, habit in pairs(state.data.habits.daily) do
		if not habit.completed_today and habit.last_completed then
			-- Check if chain was broken
			local last_date = habit.last_completed
			local days_diff = M.days_between(last_date, today)

			if days_diff > 1 then
				-- Chain broken
				habit.current_chain = 0
			end
		end
	end

	-- Similar checks for weekly/monthly habits
end

-- Helper functions

function M.find_task_objectives(task)
	local graph = require("zortex.xp.graph")
	local node_id = graph.get_node_id(task)
	return graph.find_connected_of_type(node_id, "objective", 3)
end

function M.days_between(date1, date2)
	-- Simple date comparison (assumes YYYY-MM-DD format)
	local y1, m1, d1 = date1:match("(%d+)-(%d+)-(%d+)")
	local y2, m2, d2 = date2:match("(%d+)-(%d+)-(%d+)")

	if not (y1 and y2) then
		return 0
	end

	local time1 = os.time({ year = y1, month = m1, day = d1 })
	local time2 = os.time({ year = y2, month = m2, day = d2 })

	return math.floor((time2 - time1) / 86400)
end

-- Vision quota tracking
function M.get_vision_quota_status()
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	if not cfg.vision_quota.enabled then
		return nil
	end

	local today = os.date("%Y-%m-%d")
	local vision_xp = 0

	-- Sum XP from vision-aligned tasks today
	for i = #state.data.xp_log, 1, -1 do
		local entry = state.data.xp_log[i]
		if os.date("%Y-%m-%d", entry.timestamp) ~= today then
			break
		end

		-- Check if task is close to vision
		if entry.distance and entry.distance <= cfg.vision_quota.max_distance and entry.distance < 999999 then
			vision_xp = vision_xp + entry.xp
		end
	end

	return {
		current = vision_xp,
		required = cfg.vision_quota.min_xp,
		met = vision_xp >= cfg.vision_quota.min_xp,
	}
end

return M
