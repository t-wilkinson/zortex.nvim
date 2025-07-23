-- models/task.lua - Task model with methods
local M = {}
local M_mt = { __index = M }

local task_store = require("zortex.stores.tasks")
local parser = require("zortex.core.parser")
local attributes = require("zortex.core.attributes")

local CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local BASE = #CHARS
local TIME_MOD = 131072 -- 2^17
local RAND_MAX = 4096 -- 2^12

-- =============================================================================
-- Task Creation
-- =============================================================================

-- Create a new task instance
function M:new(data)
	local task = {
		id = data.id or M.generate_id(),
		project = data.project,
		text = data.text,
		completed = data.completed or false,
		xp_awarded = data.xp_awarded or 0,
		position = data.position or 0,
		total_in_project = data.total_in_project or 0,
		area_links = data.area_links or {},
		created_at = data.created_at or os.time(),
		completed_at = data.completed_at,
		attributes = data.attributes or {},
	}
	setmetatable(task, M_mt)
	return task
end

-- Generate a unique ID
function M.generate_id()
	local function generate_base_id()
		local time_part = vim.loop.hrtime() % TIME_MOD
		local rand_part = math.random(0, RAND_MAX - 1)
		local id_num = time_part * RAND_MAX + rand_part

		local out = {}
		for i = 5, 1, -1 do
			local idx = (id_num % BASE) + 1
			out[i] = CHARS:sub(idx, idx)
			id_num = math.floor(id_num / BASE)
		end
		return table.concat(out)
	end

	-- Ensure uniqueness
	local id
	local attempts = 0
	repeat
		id = generate_base_id()
		attempts = attempts + 1
		if attempts > 100 then
			-- Fallback to numeric ID
			id = "T" .. task_store.get_next_numeric_id()
			break
		end
	until not task_store.task_exists(id)

	return id
end

-- =============================================================================
-- Task Methods
-- =============================================================================

-- Save task to store
function M:save()
	if task_store.get_task(self.id) then
		-- Update existing
		task_store.update_task(self.id, self)
	else
		-- Create new
		task_store.create_task(self.id, self)
	end
	return self
end

-- Delete task
function M:delete()
	return task_store.delete_task(self.id)
end

-- Complete task
function M:complete()
	if self.completed then
		return self
	end

	self.completed = true
	self.completed_at = os.time()
	return self:save()
end

-- Uncomplete task
function M:uncomplete()
	if not self.completed then
		return self
	end

	self.completed = false
	self.completed_at = nil
	self.xp_awarded = 0
	return self:save()
end

-- Update attributes
function M:set_attributes(attributes)
	self.attributes = attributes or {}
	return self:save()
end

-- Update position
function M:set_position(position, total_in_project)
	self.position = position
	self.total_in_project = total_in_project
	return self:save()
end

-- Move to different project
function M:move_to_project(new_project)
	if self.project == new_project then
		return self
	end

	self.project = new_project
	-- Reset position info since it's project-specific
	self.position = 0
	self.total_in_project = 0
	return self:save()
end

-- =============================================================================
-- Task Line Parsing
-- =============================================================================

-- Parse a task from a line
function M.from_line(line, line_num)
	local is_task, is_completed = parser.is_task_line(line)
	if not is_task then
		return nil
	end

	local task_text = parser.get_task_text(line)
	if not task_text then
		return nil
	end

	-- Extract ID
	local id = parser.extract_attribute(line, "id")

	-- Parse attributes
	local task_attributes = attributes.parse_task_attributes(task_text)

	return M:new({
		id = id,
		text = task_text,
		completed = is_completed,
		attributes = task_attributes,
		line_num = line_num,
	})
end

-- Convert task to line
function M:to_line()
	local checkbox = self.completed and "[x]" or "[ ]"
	local line = "- " .. checkbox .. " " .. self.text

	-- Add ID if not present
	if self.id and not line:match("@id%(") then
		line = parser.update_attribute(line, "id", self.id)
	end

	return line
end

-- =============================================================================
-- Static Methods
-- =============================================================================

-- Load task by ID
function M.load(id)
	local data = task_store.get_task(id)
	if data then
		return M:new(data)
	end
	return nil
end

-- Get all tasks for a project
function M.get_project_tasks(project_name)
	local tasks = task_store.get_project_tasks(project_name)
	local models = {}
	for _, data in ipairs(tasks) do
		table.insert(models, M:new(data))
	end
	return models
end

-- Ensure task has ID in line
function M.ensure_id_in_line(line)
	local is_task = parser.is_task_line(line)
	if not is_task then
		return line, nil
	end

	local id = parser.extract_attribute(line, "id")
	if id then
		return line, id
	end

	-- Generate and add ID
	id = M.generate_id()
	return parser.update_attribute(line, "id", id), id
end

return M
