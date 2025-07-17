-- stores/tasks.lua - Task state persistence
local M = {}

local BaseStore = require("zortex.stores.base")
local constants = require("zortex.constants")

-- Create the singleton store
local store = BaseStore:new(constants.FILES.TASK_STATE_DATA)

-- Override init_empty
function store:init_empty()
	self.data = {
		tasks = {}, -- task_id -> task_data
		project_tasks = {}, -- project_name -> array of task_ids
		next_id = 1, -- For fallback ID generation
	}
	self.loaded = true
end

-- Migrate old data formats
function store:migrate()
	-- Convert old project_tasks format (sets) to arrays if needed
	if self.data.project_tasks then
		for project, task_data in pairs(self.data.project_tasks) do
			-- If it's a table with numeric indices, it's already an array
			local is_array = false
			for k, v in pairs(task_data) do
				if type(k) == "number" then
					is_array = true
					break
				end
			end

			-- Convert set to array
			if not is_array then
				local task_list = {}
				for task_id in pairs(task_data) do
					table.insert(task_list, task_id)
				end
				self.data.project_tasks[project] = task_list
			end
		end
	end
end

-- Task CRUD operations
function M.get_task(id)
	store:ensure_loaded()
	return store.data.tasks[id]
end

function M.create_task(id, task_data)
	store:ensure_loaded()
	store.data.tasks[id] = task_data

	-- Add to project mapping
	if task_data.project then
		local project_tasks = store.data.project_tasks[task_data.project] or {}
		table.insert(project_tasks, id)
		store.data.project_tasks[task_data.project] = project_tasks
	end

	store:save()
	return task_data
end

function M.update_task(id, updates)
	store:ensure_loaded()
	local task = store.data.tasks[id]
	if not task then
		return nil
	end

	-- Handle project change
	if updates.project and updates.project ~= task.project then
		-- Remove from old project
		if task.project and store.data.project_tasks[task.project] then
			local old_tasks = store.data.project_tasks[task.project]
			for i, task_id in ipairs(old_tasks) do
				if task_id == id then
					table.remove(old_tasks, i)
					break
				end
			end
		end

		-- Add to new project
		local new_tasks = store.data.project_tasks[updates.project] or {}
		table.insert(new_tasks, id)
		store.data.project_tasks[updates.project] = new_tasks
	end

	-- Apply updates
	for k, v in pairs(updates) do
		task[k] = v
	end

	store:save()
	return task
end

function M.delete_task(id)
	store:ensure_loaded()
	local task = store.data.tasks[id]
	if not task then
		return false
	end

	-- Remove from project mapping
	if task.project and store.data.project_tasks[task.project] then
		local project_tasks = store.data.project_tasks[task.project]
		for i, task_id in ipairs(project_tasks) do
			if task_id == id then
				table.remove(project_tasks, i)
				break
			end
		end
	end

	store.data.tasks[id] = nil
	store:save()
	return true
end

-- Bulk operations
function M.get_project_tasks(project_name)
	store:ensure_loaded()
	local task_ids = store.data.project_tasks[project_name] or {}
	local tasks = {}

	for _, id in ipairs(task_ids) do
		local task = store.data.tasks[id]
		if task then
			table.insert(tasks, task)
		end
	end

	return tasks
end

function M.get_all_tasks()
	store:ensure_loaded()
	local tasks = {}
	for _, task in pairs(store.data.tasks) do
		table.insert(tasks, task)
	end
	return tasks
end

-- Task statistics
function M.get_stats()
	store:ensure_loaded()
	local stats = {
		total_tasks = 0,
		completed_tasks = 0,
		total_xp_awarded = 0,
		tasks_by_project = {},
	}

	for _, task in pairs(store.data.tasks) do
		stats.total_tasks = stats.total_tasks + 1

		if task.completed then
			stats.completed_tasks = stats.completed_tasks + 1
			stats.total_xp_awarded = stats.total_xp_awarded + (task.xp_awarded or 0)
		end

		-- Count by project
		local project = task.project
		if project then
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
				proj_stats.xp = proj_stats.xp + (task.xp_awarded or 0)
			end
		end
	end

	return stats
end

-- ID management
function M.get_next_numeric_id()
	store:ensure_loaded()
	local id = store.data.next_id or 1
	store.data.next_id = id + 1
	store:save()
	return id
end

function M.task_exists(id)
	store:ensure_loaded()
	return store.data.tasks[id] ~= nil
end

-- Archive completed tasks older than N days
function M.archive_old_tasks(days_old)
	store:ensure_loaded()
	local cutoff_time = os.time() - (days_old * 86400)
	local archived = {}

	for id, task in pairs(store.data.tasks) do
		if task.completed and task.completed_at and task.completed_at < cutoff_time then
			table.insert(archived, task)
			M.delete_task(id)
		end
	end

	if #archived > 0 then
		-- Save to archive file
		local archive_store = BaseStore:new(constants.FILES.ARCHIVE_TASK_STATE)
		archive_store:load()

		local archive_tasks = archive_store.data.tasks or {}
		for _, task in ipairs(archived) do
			archive_tasks[task.id] = task
		end
		archive_store.data.tasks = archive_tasks
		archive_store:save()
	end

	return #archived
end

-- Force operations
function M.reload()
	store.loaded = false
	store:load()
end

function M.save()
	return store:save()
end

return M

