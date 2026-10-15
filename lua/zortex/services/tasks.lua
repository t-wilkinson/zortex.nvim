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
		local time_part = vim.uv.hrtime() % TIME_MOD
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
			id = "T" .. tostring(vim.uv.hrtime())
			break
		end
	until not M.find_task_by_id(id)

	return id
end

--- A new task id, unused in the project sources and the calendar.
M.new_id = generate_task_id

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
	-- The same task elsewhere (its project, other calendar days)
	require("zortex.services.mirrors").sync(doc_context.filepath, doc_context.lnum, new_line)

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
	require("zortex.services.mirrors").sync(doc_context.filepath, doc_context.lnum, new_line)

	-- Emit event
	Events.emit("task:uncompleted", { task = task, doc_context = doc_context })

	return task
end

-- =============================================================================
-- Task Creation and Conversion
-- =============================================================================

-- Convert a line to a task (id: the @id to use; default a new one)
function M.convert_line_to_task(line, id)
	if not line or line:match("^%s*$") then
		return nil, "Empty line"
	end

	-- Parse the line structure
	local indent, content = line:match("^(%s*)(.-)%s*$")

	-- Drop a list marker: "- text", "-text"
	local list_text = content:match("^%-%s*(.+)") or content

	-- Build the task line
	local task_id = id or generate_task_id()
	local task_line = indent .. "- [ ] " .. list_text
	task_line = attributes.add_attribute(task_line, "id", task_id)
	local task = Item.task(task_line)

	return task, task_line
end

-- =============================================================================
-- Pure line edits (shared with the web app)
-- =============================================================================

-- The line with its checkbox set and @done added (today) or removed.
local function set_done(line, done, today)
	local t = Item.task(line)
	local new = t:with_mark(done and constants.TASK_MARKS.COMPLETED or constants.TASK_MARKS.TODO)
	if done then
		return attributes.update_attribute(new, "done", today)
	end
	return attributes.remove_attribute(new, "done")
end

--- Edit one line the way the task commands do, without touching a buffer:
---   "open"    a task, not done (text becomes a task; done is reopened)
---   "done"    a completed task with @done(today) (text becomes a task first)
---   "toggle"  done <-> open; text becomes an open task
---   "text"    a plain list item: checkbox and @done removed
--- Tasks always end up with an @id. Returns the new line, or nil and an
--- error. `zortex serve` implements the same edits (app/edit), checked
--- against tests/fixtures/edits.json, which tests/gen_edits.lua writes from
--- this function.
---@param opts { today?: string, id?: string }?
function M.edit_line(line, op, opts)
	opts = opts or {}
	local today = opts.today or os.date("%Y-%m-%d")
	local task = Item.task(line)

	if op == "text" then
		if not task then
			return line
		end
		local before, after = line:sub(1, task.mark_col), line:sub(task.mark_col + 4)
		after = after:gsub("^ ", "", 1)
		return attributes.remove_attribute(before .. after, "done")
	end
	if op ~= "open" and op ~= "done" and op ~= "toggle" then
		return nil, "unknown edit: " .. tostring(op)
	end

	if not task then
		local converted, new_line = M.convert_line_to_task(line, opts.id)
		if not converted then
			return nil, new_line
		end
		if op == "done" then
			return set_done(new_line, true, today)
		end
		return new_line
	end

	if not (task.attributes and task.attributes.id) then
		line = attributes.add_attribute(line, "id", opts.id or generate_task_id())
	end
	local want_done
	if op == "toggle" then
		want_done = not task.completed
	else
		want_done = op == "done"
	end
	if want_done == task.completed then
		return line
	end
	return set_done(line, want_done, today)
end

-- =============================================================================
-- Task Completion Handler
-- =============================================================================

-- Lines that never become tasks
local NOT_TASKS = {
	article = true,
	tag = true,
	heading = true,
	bold_heading = true,
	fence = true,
	code = true,
	math_fence = true,
	math = true,
	table = true,
	blank = true,
}

-- Change task completion at current doc_context, main entrypoint for (un)complete or creating tasks
function M.change_task_completion(doc_context, should_complete)
	if not doc_context or not doc_context.doc then
		return nil, "Invalid doc_context"
	end

	-- Get task at current line
	local task = Item.task(doc_context.line)

	-- A calendar line without a checkbox that links a task stands for it:
	-- toggle the task it points at
	if not task then
		local forwarded, err = M.toggle_reference(doc_context, should_complete)
		if forwarded or err then
			return forwarded, err
		end
	end

	-- If there's still no task object, it means the line is not a task. Convert it.
	if not task then
		-- Structure isn't a task: toggling with the cursor on a (folded)
		-- heading must not turn "# Project" into "- [ ] # Project"
		local kind = require("zortex.core.syntax").classify(doc_context.line).kind
		if NOT_TASKS[kind] then
			return nil, "not a task: this line is a " .. kind:gsub("_", " ")
		end
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

--- Toggle the task a calendar reference line points at. Returns the task
--- (nil, nil when the line is no reference).
function M.toggle_reference(doc_context, should_complete)
	local mirrors = require("zortex.services.mirrors")
	local path = doc_context.filepath and vim.fn.fnamemodify(doc_context.filepath, ":p")
	if path ~= mirrors.calendar_path() then
		return nil
	end
	local lines = doc_context.doc and doc_context.doc.lines or workspace.get_lines(doc_context.bufnr)
	local ref = mirrors.reference(lines, doc_context.lnum, doc_context.doc)
	if not ref then
		return nil
	end
	local want = should_complete
	if want == nil then
		want = not ref.task.completed
	end
	if want == ref.task.completed then
		return ref.task
	end
	local new_line, err = M.edit_line(ref.line, want and "done" or "open")
	if not new_line then
		return nil, err
	end
	workspace.set_line(ref.file, ref.lnum, new_line)
	mirrors.sync(ref.file, ref.lnum, new_line)
	local task = Item.task(new_line, { lnum = ref.lnum, file = ref.file })
	local ctx = { file = ref.file, filepath = ref.file, lnum = ref.lnum, line = new_line }
	Events.emit(want and "task:completed" or "task:uncompleted", { task = task, doc_context = ctx })
	vim.notify(
		string.format("%s %s (%s)", want and "Done:" or "Reopened:", task.text, vim.fn.fnamemodify(ref.file, ":t")),
		vim.log.levels.INFO,
		{ title = "Zortex" }
	)
	return task
end

-- =============================================================================
-- Public Commands
-- =============================================================================

local function at_cursor(should_complete)
	local doc_context = workspace.get_doc_context()
	if not doc_context then
		vim.notify("Not a note buffer", vim.log.levels.WARN, { title = "Zortex" })
		return nil, "Not in a note buffer"
	end
	local result, err = M.change_task_completion(doc_context, should_complete)
	if not result and err then
		vim.notify("Zortex: " .. err, vim.log.levels.WARN, { title = "Zortex" })
	end
	return result, err
end

function M.toggle_current_task()
	return at_cursor(nil)
end

function M.complete_current_task()
	return at_cursor(true)
end

function M.uncomplete_current_task()
	return at_cursor(false)
end

return M
