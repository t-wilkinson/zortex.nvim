-- services/task.lua - Stateless service for task operations using workspace
local M = {}

local Events = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local parser = require("zortex.utils.parser")
local workspace = require("zortex.core.workspace")
local attributes = require("zortex.utils.attributes")
local constants = require("zortex.constants")

-- =============================================================================
-- ID Generation
-- =============================================================================

local CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local BASE = #CHARS
local TIME_MOD = 131072
local RAND_MAX = 4096

-- Generate unique task ID
local function generate_task_id()
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

	-- Generate and ensure uniqueness by checking workspace
	local id
	local attempts = 0
	repeat
		id = generate_base_id()
		attempts = attempts + 1
		if attempts > 100 then
			-- Fallback to timestamp-based ID
			id = "T" .. tostring(vim.loop.hrtime())
			break
		end
	until not M.find_task_by_id(id)

	return id
end

-- =============================================================================
-- Task Finding and Retrieval
-- =============================================================================
function M.get_all_ids(doc)
	local lines = vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false)

	local all_ids = {}
	for _, line in ipairs(lines) do
		for match in string.gmatch(line, "@id%((%w+)%)") do
			table.insert(all_ids, match)
		end
	end

	return all_ids
end

-- Find a task by ID across all workspace documents
-- Returns: task_data, document, line_number
function M.find_task_by_id(task_id)
	if not task_id then
		Logger.warn("tasks", "find_task_by_id called with nil task_id")
		return nil
	end

	Logger.debug("tasks", "Searching for task", { task_id = task_id })

	-- Search in all workspace documents
	local docs_to_search = {
		workspace.projects(),
		workspace.calendar(),
	}

	for _, doc in ipairs(docs_to_search) do
		if doc and doc.sections then
			return false
			-- Get all tasks from document
			-- local ids = M.get_all_ids(doc)

			-- for _, id in ipairs(ids) do
			-- 	if id == task_id then
			-- 		return true
			-- 	end
			-- end
		end
	end

	Logger.debug("tasks", "Task not found", { task_id = task_id })
	return nil
end

-- =============================================================================
-- Task Completion Operations
-- =============================================================================

function M.build_task_line(task)
	local mark = task.completed and constants.TASK_MARKS.COMPLETED or constants.TASK_MARKS.TODO
	return task.indent .. "- [" .. mark .. "] " .. task.text .. " " .. attributes.to_line(task.attributes)
end

-- Complete a task
function M.complete_task(task, context)
	if task.completed then
		return nil, "Task already completed"
	end

	-- Update line: toggle checkbox and add attributes
	task.completed = true
	task.mark = constants.TASK_MARKS.COMPLETED
	task.attributes["done"] = os.date("%Y-%m-%d")

	local new_line = M.build_task_line(task)

	-- Update document
	local success = context.doc:change_line(context.lnum, new_line)
	if not success then
		return nil, "Failed to update line"
	end

	-- Emit event
	Events.emit("task:completed", {
		xp_context = M._build_xp_context(task, context),
	})
	return task
end

-- Uncomplete a task
function M.uncomplete_task(task, context)
	if not task.completed then
		return nil, "Task already uncompleted"
	end

	-- Update line: toggle checkbox and remove completion attributes
	task.completed = false
	task.mark = constants.TASK_MARKS.TODO
	task.attributes["done"] = nil

	local new_line = M.build_task_line(task)

	-- Update document
	local success = context.doc:change_line(context.lnum, new_line)
	if not success then
		return nil, "Failed to update line"
	end

	-- Emit event
	Events.emit("task:uncompleted", {
		xp_context = M._build_xp_context(task, context),
	})

	return task
end

-- =============================================================================
-- Task Creation and Conversion
-- =============================================================================

-- Convert a line to a task
function M.convert_line_to_task(line)
	if not line or line:match("^%s*$") then
		return nil, "Empty line"
	end

	-- Parse the line structure
	local indent, content = line:match("^(%s*)(.-)%s*$")

	-- Check if content starts with a list marker and extract the actual text
	-- Handles: "- text", "-text", "* text", "+ text", etc.
	local list_text = content:match("^[-*+]%s*(.+)") or content

	-- Build the task line
	local task_id = generate_task_id()
	local task_line = indent .. "- [ ] " .. list_text
	task_line = attributes.add_attribute(task_line, "id", task_id)
	local task = parser.parse_task(task_line)

	-- Emit event
	Events.emit("task:created", task)

	return task, task_line
end

-- =============================================================================
-- Task Completion Handler
-- =============================================================================

-- Change task completion at current context, main entrypoint for (un)complete or creating tasks
function M.change_task_completion(context, should_complete)
	if not context or not context.doc then
		Logger.error("tasks", "Invalid context")
		return nil, "Invalid context"
	end

	-- Get task at current line
	local task = parser.parse_task(context.line)

	-- If there's still no task object, it means the line is not a task. Convert it.
	if not task then
		-- After converting, the toggle action is complete for this call.
		local task, new_line = M.convert_line_to_task(context.line)
		context.doc:change_line(context.lnum, new_line)

		return task, nil
	end

	-- Ensure task has ID
	if not task.attributes or not task.attributes.id then
		local id = generate_task_id()
		local new_line = attributes.add_attribute(context.line, "id", id)
		context.doc:change_line(context.lnum, new_line)
		task = parser.parse_task(new_line)

		if not task then
			return nil, "Failed to parse task: " .. new_line
		end
	end

	-- Handle completion based on should_complete parameter
	local result, err
	if should_complete == nil then
		-- Toggle
		if task.completed then
			result, err = M.uncomplete_task(task, context)
		else
			result, err = M.complete_task(task, context)
		end
	elseif should_complete and not task.completed then
		result, err = M.complete_task(task, context)
	elseif not should_complete and task.completed then
		result, err = M.uncomplete_task(task, context)
	else
		-- No change needed
		result = task
	end

	return result, err
end

-- =============================================================================
-- Context Building Helpers
-- =============================================================================

-- Build XP context for a task
function M._build_xp_context(task, context)
	local projects_service = require("zortex.services.projects")
	local section = projects_service.find_project(context.section)
	local project = projects_service.get_project(section, context.doc)

	return {
		task = task,
		context = context,
		project = project,
	}
end

-- =============================================================================
-- Public Commands
-- =============================================================================

function M.toggle_current_task()
	local context = workspace.get_context()
	if not context then
		Logger.error("tasks", "No workspace context")
		return nil, "No workspace context"
	end
	return M.change_task_completion(context, nil)
end

function M.complete_current_task()
	local context = workspace.get_context()
	if not context then
		return nil, "No workspace context"
	end
	return M.change_task_completion(context, true)
end

function M.uncomplete_current_task()
	local context = workspace.get_context()
	if not context then
		return nil, "No workspace context"
	end
	return M.change_task_completion(context, false)
end

return M
