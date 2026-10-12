-- services/tasks.lua - Task operations (toggle/complete/convert) on any note
local M = {}

local Events = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local Item = require("zortex.core.item")
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

-- Find a task by @id(...) across the project sources and the calendar.
-- Returns: task, document, line_number (or nil)
function M.find_task_by_id(task_id)
	if not task_id then
		return nil
	end

	local Document = require("zortex.core.document")
	local paths = require("zortex.services.projects").sources()
	table.insert(paths, require("zortex.utils.filesystem").get_calendar_file())

	local needle = "@id(" .. task_id .. ")"
	for _, path in ipairs(paths) do
		local doc = Document.get(path)
		if doc then
			for lnum, line in ipairs(doc.lines) do
				if line:find(needle, 1, true) then
					return Item.task(line), doc, lnum
				end
			end
		end
	end
	return nil
end

-- =============================================================================
-- Task Completion Operations
-- =============================================================================

-- The task's line with its checkbox set to `mark` and @done(...) added or
-- removed. Edits the original line in place, so every other attribute, tag
-- and spacing is kept exactly as written.
function M.build_task_line(task)
	local mark = task.completed and constants.TASK_MARKS.COMPLETED or constants.TASK_MARKS.TODO
	local line = task:with_mark(mark)
	if task.completed then
		local done = task.attributes and task.attributes.done
		local value = type(done) == "string" and done or os.date("%Y-%m-%d")
		line = attributes.update_attribute(line, "done", value)
	else
		line = attributes.remove_attribute(line, "done")
	end
	return line
end

-- Complete a task
function M.complete_task(task, doc_context)
	if task.completed then
		return nil, "Task already completed"
	end

	-- Update line: toggle checkbox and add attributes
	task.completed = true
	task.mark = constants.TASK_MARKS.COMPLETED
	task.attributes["done"] = os.date("%Y-%m-%d")

	local new_line = M.build_task_line(task)

	-- Update document
	local success = workspace.set_line(doc_context.bufnr, doc_context.lnum, new_line)
	if not success then
		return nil, "Failed to update line"
	end

	-- Emit event
	Events.emit("task:completed", { task = task, doc_context = doc_context })
	return task
end

-- Uncomplete a task
function M.uncomplete_task(task, doc_context)
	if not task.completed then
		return nil, "Task already uncompleted"
	end

	-- Update line: toggle checkbox and remove completion attributes
	task.completed = false
	task.mark = constants.TASK_MARKS.TODO
	task.attributes["done"] = nil

	local new_line = M.build_task_line(task)

	-- Update document
	local success = workspace.set_line(doc_context.bufnr, doc_context.lnum, new_line)
	if not success then
		return nil, "Failed to update line"
	end

	-- Emit event
	Events.emit("task:uncompleted", { task = task, doc_context = doc_context })

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
	local task = Item.task(task_line)

	return task, task_line
end

-- =============================================================================
-- Task Completion Handler
-- =============================================================================

-- Change task completion at current doc_context, main entrypoint for (un)complete or creating tasks
function M.change_task_completion(doc_context, should_complete)
	if not doc_context or not doc_context.doc then
		return nil, "Invalid doc_context"
	end

	-- Get task at current line
	local task = Item.task(doc_context.line)

	-- If there's still no task object, it means the line is not a task. Convert it.
	if not task then
		-- After converting, the toggle action is complete for this call.
		local new_line
		task, new_line = M.convert_line_to_task(doc_context.line)
		workspace.set_line(doc_context.bufnr, doc_context.lnum, new_line)

		-- Emit event
		Events.emit("task:created", { task = task, doc_context = doc_context })

		return task, nil
	end

	-- Ensure task has ID
	if not task.attributes or not task.attributes.id then
		local id = generate_task_id()
		local new_line = attributes.add_attribute(doc_context.line, "id", id)
		workspace.set_line(doc_context.bufnr, doc_context.lnum, new_line)
		task = Item.task(new_line)

		if not task then
			return nil, "Failed to parse task: " .. new_line
		end
	end

	-- Handle completion based on should_complete parameter
	local result, err
	if should_complete == nil then
		-- Toggle
		if task.completed then
			result, err = M.uncomplete_task(task, doc_context)
		else
			result, err = M.complete_task(task, doc_context)
		end
	elseif should_complete and not task.completed then
		result, err = M.complete_task(task, doc_context)
	elseif not should_complete and task.completed then
		result, err = M.uncomplete_task(task, doc_context)
	else
		-- No change needed
		result = task
	end

	return result, err
end

-- =============================================================================
-- Public Commands
-- =============================================================================

function M.toggle_current_task()
	local doc_context = workspace.get_doc_context()
	if not doc_context then
		return nil, "Not in a note buffer"
	end
	return M.change_task_completion(doc_context, nil)
end

function M.complete_current_task()
	local doc_context = workspace.get_doc_context()
	if not doc_context then
		return nil, "Not in a note buffer"
	end
	return M.change_task_completion(doc_context, true)
end

function M.uncomplete_current_task()
	local doc_context = workspace.get_doc_context()
	if not doc_context then
		return nil, "Not in a note buffer"
	end
	return M.change_task_completion(doc_context, false)
end

return M
