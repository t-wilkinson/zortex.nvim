-- State management for Zortex XP system
local M = {}

local Path = require("plenary.path")

-- Initialize state
M.data = {
	-- Core XP tracking
	total_xp = 0,
	daily_xp = 0,
	level = 1,
	xp_log = {},

	-- Streaks and combos
	current_streak = 0,
	last_completion_date = nil,
	combo = { project = nil, count = 0, last_time = 0 },

	-- Area/skill tracking
	area_xp = {},

	-- Budget tracking
	budget = {
		spent_today = 0,
		spent_total = 0,
		saved_total = 0,
		category_spending = {},
		last_milestone = 0,
	},

	-- Habit tracking
	habits = {
		daily = {},
		weekly = {},
		monthly = {},
		chains = {},
	},

	-- Resource tracking
	resources = {
		created = {},
		consumed = {},
		shared = {},
	},

	-- Task tracking
	objective_heat = {},
	project_fatigue = {},
	last_line_states = {},
	completed_tasks = {},

	-- Badges
	badges = {},

	-- Metadata
	version = 2,
	last_save = nil,
}

-- Get state file path
function M.get_path()
	return Path:new(vim.fn.stdpath("data"), "zortex", "xp_state.json")
end

-- Save state to disk
function M.save()
	local path = M.get_path()
	path:parent():mkdir({ parents = true })

	M.data.last_save = os.time()

	-- Sanitize data before JSON encoding
	local safe_data = M.sanitize_for_json(M.data)

	local ok, json = pcall(vim.fn.json_encode, safe_data)
	if not ok then
		vim.notify("Error saving XP state: " .. tostring(json), "error", { title = "Zortex XP" })
		return false
	end

	path:write(json, "w")
	return true
end

-- Sanitize data for JSON encoding
function M.sanitize_for_json(data)
	local function sanitize_value(v)
		if type(v) == "number" then
			-- Replace infinity and NaN with large numbers
			if v == math.huge then
				return 999999
			elseif v == -math.huge then
				return -999999
			elseif v ~= v then -- NaN check
				return 0
			else
				return v
			end
		elseif type(v) == "table" then
			local result = {}
			for k, val in pairs(v) do
				result[k] = sanitize_value(val)
			end
			return result
		else
			return v
		end
	end

	return sanitize_value(data)
end

-- Load state from disk
function M.load()
	local path = M.get_path()

	if path:exists() then
		local content = path:read()
		if content then
			local loaded = vim.fn.json_decode(content)

			-- Merge with defaults to handle new fields
			M.data = vim.tbl_deep_extend("force", M.data, loaded)

			-- Handle version migrations
			if loaded.version ~= M.data.version then
				M.migrate(loaded.version)
			end
		end
	end
end

-- Migrate state between versions
function M.migrate(from_version)
	if from_version == 1 then
		-- Migrate from v1 to v2
		-- Initialize new tracking structures
		if not M.data.habits then
			M.data.habits = { daily = {}, weekly = {}, monthly = {}, chains = {} }
		end
		if not M.data.resources then
			M.data.resources = { created = {}, consumed = {}, shared = {} }
		end
		if not M.data.budget.category_spending then
			M.data.budget.category_spending = {}
		end

		M.data.version = 2
		M.save()

		vim.notify("Migrated XP state to version 2", "info", { title = "Zortex XP" })
	end
end

-- Check and perform daily reset
function M.check_daily_reset()
	local today = os.date("%Y-%m-%d")

	if M.data.last_completion_date ~= today then
		-- Reset daily values
		M.data.daily_xp = 0
		M.data.budget.spent_today = 0

		-- Update streak
		if M.data.last_completion_date == os.date("%Y-%m-%d", os.time() - 86400) then
			-- Completed yesterday, continue streak
			M.data.current_streak = M.data.current_streak + 1
		else
			-- Missed a day, reset streak
			M.data.current_streak = 0
		end

		-- Reset daily habits
		for habit_id, _ in pairs(M.data.habits.daily) do
			M.data.habits.daily[habit_id].completed_today = false
		end

		-- Check weekly habits (on Sunday)
		if os.date("%w") == "0" then
			for habit_id, _ in pairs(M.data.habits.weekly) do
				M.data.habits.weekly[habit_id].completed_this_week = false
			end
		end

		-- Check monthly habits (on 1st)
		if os.date("%d") == "01" then
			for habit_id, _ in pairs(M.data.habits.monthly) do
				M.data.habits.monthly[habit_id].completed_this_month = false
			end
		end

		M.save()
	end
end

-- Award XP
function M.award_xp(amount, task, breakdown)
	local today = os.date("%Y-%m-%d")

	-- Update totals
	M.data.total_xp = M.data.total_xp + amount
	M.data.daily_xp = M.data.daily_xp + amount

	-- Update level
	M.data.level = math.floor(math.sqrt(M.data.total_xp / 100)) + 1

	-- Update area XP
	if task.areas then
		for _, area in ipairs(task.areas) do
			M.data.area_xp[area] = (M.data.area_xp[area] or 0) + amount
		end
	end

	-- Log the XP gain
	table.insert(M.data.xp_log, {
		timestamp = os.time(),
		task = task.text or task.name,
		xp = amount,
		breakdown = breakdown,
		level = M.data.level,
		distance = task.distance,
		areas = task.areas,
		size = task.size,
		type = task.type,
		file = task.file,
	})

	-- Update completion date
	M.data.last_completion_date = today

	-- Track completed task
	local task_id = task.file .. ":" .. (task.text or task.name or "")
	M.data.completed_tasks[task_id] = os.time()
end

-- Get/set line states
function M.get_line_state(key)
	return M.data.last_line_states[key]
end

function M.set_line_state(key, value)
	M.data.last_line_states[key] = value
end

-- Budget operations
function M.add_expense(amount, category)
	M.data.budget.spent_today = M.data.budget.spent_today + amount
	M.data.budget.spent_total = M.data.budget.spent_total + amount

	if category then
		M.data.budget.category_spending[category] = (M.data.budget.category_spending[category] or 0) + amount
	end
end

function M.add_savings(amount)
	M.data.budget.saved_total = M.data.budget.saved_total + amount
end

-- Habit operations
function M.track_habit(habit_id, frequency)
	local today = os.date("%Y-%m-%d")

	if frequency == "daily" then
		if not M.data.habits.daily[habit_id] then
			M.data.habits.daily[habit_id] = {
				created = today,
				completed_today = false,
				total_completions = 0,
				current_chain = 0,
				best_chain = 0,
			}
		end

		local habit = M.data.habits.daily[habit_id]
		if not habit.completed_today then
			habit.completed_today = true
			habit.total_completions = habit.total_completions + 1
			habit.current_chain = habit.current_chain + 1
			habit.best_chain = math.max(habit.best_chain, habit.current_chain)
			habit.last_completed = today
			return true
		end
	end
	-- Similar for weekly/monthly

	return false
end

-- Resource operations
function M.track_resource(resource_name, action, amount)
	amount = amount or 1

	if action == "create" then
		M.data.resources.created[resource_name] = (M.data.resources.created[resource_name] or 0) + amount
	elseif action == "consume" then
		M.data.resources.consumed[resource_name] = (M.data.resources.consumed[resource_name] or 0) + amount
	elseif action == "share" then
		M.data.resources.shared[resource_name] = (M.data.resources.shared[resource_name] or 0) + amount
	end
end

-- Heat operations
function M.get_objective_heat(objective_id)
	local heat_data = M.data.objective_heat[objective_id]
	if not heat_data then
		return 1.0
	end

	-- Apply time-based decay
	local current_time = os.time()
	local weeks_elapsed = (current_time - heat_data.last_update) / (7 * 24 * 60 * 60)
	local decayed_value = heat_data.value - (0.1 * weeks_elapsed)

	return math.max(0.1, math.min(2.0, decayed_value))
end

function M.set_objective_heat(objective_id, value)
	M.data.objective_heat[objective_id] = {
		value = value,
		last_update = os.time(),
	}
end

-- Fatigue operations
function M.update_project_fatigue(project_id, hours)
	local today = os.date("%Y-%m-%d")

	if not M.data.project_fatigue[project_id] then
		M.data.project_fatigue[project_id] = {
			last_date = today,
			hours_today = 0,
		}
	end

	local fatigue = M.data.project_fatigue[project_id]

	-- Reset if new day
	if fatigue.last_date ~= today then
		fatigue.hours_today = 0
		fatigue.last_date = today
	end

	fatigue.hours_today = fatigue.hours_today + hours
end

function M.get_project_fatigue(project_id)
	local fatigue = M.data.project_fatigue[project_id]
	if not fatigue then
		return 0
	end

	-- Reset if old data
	local today = os.date("%Y-%m-%d")
	if fatigue.last_date ~= today then
		return 0
	end

	return fatigue.hours_today
end

-- Combo operations
function M.update_combo(project_id)
	local now = os.time()

	if M.data.combo.project == project_id then
		local time_diff = now - M.data.combo.last_time
		if time_diff <= 5400 then -- 90 minutes
			M.data.combo.count = M.data.combo.count + 1
			M.data.combo.last_time = now
			return M.data.combo.count
		end
	end

	-- New combo
	M.data.combo = {
		project = project_id,
		count = 1,
		last_time = now,
	}
	return 1
end

-- Badge operations
function M.award_badge(badge_name)
	if not M.data.badges[badge_name] then
		M.data.badges[badge_name] = os.time()
		return true
	end
	return false
end

return M
