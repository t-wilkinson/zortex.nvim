-- modules/task_tracker.lua - Track individual task states and XP
local M = {}

local fs = require("zortex.core.filesystem")
local constants = require("zortex.constants")
local xp_config = require("zortex.modules.xp_config")

-- =============================================================================
-- ID Generation
-- =============================================================================

local CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local BASE = #CHARS -- 62
local TIME_MOD = 131072 -- 2^17  ( ~131 µs rollover window )
local RAND_MAX = 4096 -- 2^12

-- Generate a 5-character base-62 ID using 17 bits of time + 12 bits random.
function M.generate_id()
	-- 17-bit time slice (ns counter modulo 2^17)
	local time_part = vim.loop.hrtime() % TIME_MOD -- 0-131 071
	-- 12-bit random component
	local rand_part = math.random(0, RAND_MAX - 1) -- 0-4 095

	-- Pack: (time_part << 12) | rand_part  →  time_part*4096 + rand_part
	local id_num = time_part * RAND_MAX + rand_part -- fits in 29 bits

	-- Base-62 encode to exactly five chars
	local out = {}
	for i = 5, 1, -1 do
		local idx = (id_num % BASE) + 1
		out[i] = CHARS:sub(idx, idx)
		id_num = math.floor(id_num / BASE)
	end
	return table.concat(out)
end

-- =============================================================================
-- State Management
-- =============================================================================

local state = {
	-- task_id -> task_data
	tasks = {},

	-- project_name -> Set of task_ids
	project_tasks = {},
}

-- Task data structure:
-- {
--   id = "abc123",
--   project = "Project Name",
--   completed = false,
--   xp_awarded = 0,
--   position = 1,
--   total_in_project = 5,
--   area_links = { ... },
--   created_at = timestamp,
--   completed_at = timestamp or nil,
--   attributes = { size = "md", priority = "p1", ... }
-- }

-- =============================================================================
-- Task Operations
-- =============================================================================

-- Register a new task
function M.register_task(id, project_name, attributes, area_links)
	if state.tasks[id] then
		-- Task already exists, just update project if needed
		local task = state.tasks[id]
		if task.project ~= project_name then
			M.move_task(id, project_name)
		end
		return id
	end

	-- Create new task
	state.tasks[id] = {
		id = id,
		project = project_name,
		completed = false,
		xp_awarded = 0,
		position = 0, -- Will be updated
		total_in_project = 0, -- Will be updated
		area_links = area_links or {},
		created_at = os.time(),
		completed_at = nil,
		attributes = attributes or {},
	}

	-- Add to project mapping
	if not state.project_tasks[project_name] then
		state.project_tasks[project_name] = {}
	end
	state.project_tasks[project_name][id] = true

	return id
end

-- Remove a task from the tracker
function M.remove_task(id)
	local task = state.tasks[id]
	if not task then
		return
	end

	-- Remove from project mapping
	if task.project and state.project_tasks[task.project] then
		state.project_tasks[task.project][id] = nil
	end

	-- Remove from tasks
	state.tasks[id] = nil
end

-- Update task completion status
function M.update_task_status(id, completed, position, total_in_project)
	local task = state.tasks[id]
	if not task then
		return 0 -- No XP change
	end

	local xp_delta = 0

	-- Update position and total
	task.position = position
	task.total_in_project = total_in_project

	-- Check if completion status changed
	if task.completed ~= completed then
		task.completed = completed

		if completed then
			-- Task was completed
			task.completed_at = os.time()

			-- Calculate XP for this task
			local task_xp = xp_config.calculate_task_xp(position, total_in_project)
			task.xp_awarded = task_xp
			xp_delta = task_xp
		else
			-- Task was uncompleted - remove XP
			xp_delta = -task.xp_awarded
			task.xp_awarded = 0
			task.completed_at = nil
		end
	end

	return xp_delta
end

-- Move task to different project
function M.move_task(id, new_project)
	local task = state.tasks[id]
	if not task or task.project == new_project then
		return 0
	end

	local xp_delta = 0

	-- If task was completed, we need to recalculate XP
	if task.completed then
		-- Remove old XP
		xp_delta = -task.xp_awarded
		task.xp_awarded = 0
	end

	-- Update project mappings
	if state.project_tasks[task.project] then
		state.project_tasks[task.project][id] = nil
	end

	if not state.project_tasks[new_project] then
		state.project_tasks[new_project] = {}
	end
	state.project_tasks[new_project][id] = true

	task.project = new_project

	return xp_delta
end

-- Update task attributes
function M.update_task_attributes(id, attributes)
	local task = state.tasks[id]
	if not task then
		return
	end

	task.attributes = attributes
end

-- Update task area links
function M.update_task_area_links(id, area_links)
	local task = state.tasks[id]
	if not task then
		return
	end

	task.area_links = area_links
end

-- Return the sum of XP awarded to every task in a project
function M.get_project_total_xp(project_name)
	local total = 0
	for _, task in ipairs(M.get_project_tasks(project_name)) do
		total = total + (task.xp_awarded or 0)
	end
	return total
end

-- Get all tasks for a project
function M.get_project_tasks(project_name)
	local task_ids = state.project_tasks[project_name] or {}
	local tasks = {}

	for id in pairs(task_ids) do
		local task = state.tasks[id]
		if task then
			table.insert(tasks, task)
		end
	end

	return tasks
end

-- Get direct task count for project (excluding children)
function M.get_direct_task_count(project_name)
	local tasks = M.get_project_tasks(project_name)
	local total = #tasks
	local completed = 0

	for _, task in ipairs(tasks) do
		if task.completed then
			completed = completed + 1
		end
	end

	return total, completed
end

-- Clean up orphaned tasks
function M.cleanup_orphaned_tasks()
	local removed = 0

	for id, task in pairs(state.tasks) do
		-- Check if task's project still exists
		local project_exists = false
		-- This would need to check against actual projects in the file
		-- For now, we'll keep all tasks
	end

	return removed
end

-- =============================================================================
-- ID Management
-- =============================================================================

-- Generate a new unique ID
function M.generate_unique_id()
	local id
	local attempts = 0

	repeat
		id = M.generate_id()
		attempts = attempts + 1
		if attempts > 100 then
			error("Failed to generate unique ID after 100 attempts")
		end
	until not state.tasks[id]

	return id
end

-- Check if ID exists
function M.id_exists(id)
	return state.tasks[id] ~= nil
end

-- =============================================================================
-- State Persistence
-- =============================================================================

function M.save_state()
	local data_file = fs.get_file_path(constants.FILES.TASK_STATE_DATA)
	if data_file then
		fs.ensure_directory(data_file)

		-- Convert state to saveable format
		local save_data = {
			tasks = state.tasks,
			project_tasks = {},
		}

		-- Convert project_tasks sets to arrays
		for project, task_set in pairs(state.project_tasks) do
			save_data.project_tasks[project] = {}
			for id in pairs(task_set) do
				table.insert(save_data.project_tasks[project], id)
			end
		end

		fs.write_json(data_file, save_data)
	end
end

function M.load_state()
	local data_file = fs.get_file_path(constants.FILES.TASK_STATE_DATA)
	if data_file and fs.file_exists(data_file) then
		local loaded = fs.read_json(data_file)
		if loaded then
			state.tasks = loaded.tasks or {}

			-- Convert arrays back to sets
			state.project_tasks = {}
			for project, task_list in pairs(loaded.project_tasks or {}) do
				state.project_tasks[project] = {}
				for _, id in ipairs(task_list) do
					state.project_tasks[project][id] = true
				end
			end

			return true
		end
	end

	-- Initialize empty state
	state = {
		tasks = {},
		project_tasks = {},
	}
	return false
end

-- =============================================================================
-- Statistics
-- =============================================================================

-- Get task statistics
function M.get_stats()
	local stats = {
		total_tasks = 0,
		completed_tasks = 0,
		total_xp_awarded = 0,
		tasks_by_project = {},
	}

	for _, task in pairs(state.tasks) do
		stats.total_tasks = stats.total_tasks + 1

		if task.completed then
			stats.completed_tasks = stats.completed_tasks + 1
			stats.total_xp_awarded = stats.total_xp_awarded + task.xp_awarded
		end

		-- Count by project
		local project = task.project
		if not stats.tasks_by_project[project] then
			stats.tasks_by_project[project] = {
				total = 0,
				completed = 0,
				xp = 0,
			}
		end

		local proj_stats = stats.tasks_by_project[project]
		proj_stats.total = proj_stats.total + 1
		if task.completed then
			proj_stats.completed = proj_stats.completed + 1
			proj_stats.xp = proj_stats.xp + task.xp_awarded
		end
	end

	return stats
end

-- Get task by ID
function M.get_task(id)
	return state.tasks[id]
end

return M
