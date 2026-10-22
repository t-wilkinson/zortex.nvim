-- services/tasks.lua - Task operations (toggle/complete/convert) on any note
local M = {}

local Events = require("zortex.core.event_bus")
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
	-- The only task of a calendar block, unsized: the block's length
	new_line = M.size_from_block(doc_context.bufnr, doc_context.lnum) or new_line
	-- The same task elsewhere (its project, other calendar days), and the
	-- tasks of its group
	M.propagate(doc_context.filepath, doc_context.lnum, new_line)

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
	M.propagate(doc_context.filepath, doc_context.lnum, new_line)

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

	-- A timed line keeps its time in front: "16:00 Report" -> "16:00 [ ] Report"
	local timed = require("zortex.core.syntax").item(line)
	if timed and timed.marker_type == "time" and not timed.mark then
		local rest = line:sub(timed.content_col + 1):match("^%s*(.-)%s*$")
		local task_line = attributes.add_attribute(line:sub(1, timed.content_col) .. "[ ] " .. rest, "id", id or generate_task_id())
		return Item.task(task_line), task_line
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
-- Sizing a calendar task by its block
-- =============================================================================

local function indent_width(line)
	return #line:match("^[ \t]*")
end

local function minutes(hm)
	local h, m = (hm or ""):match("^(%d%d?):(%d%d)$")
	return h and tonumber(h) * 60 + tonumber(m) or nil
end

--- The size a just-completed calendar task gets from its block, or nil.
--- The task at `lnum` (no @size of its own) must be a timed task with no
--- tasks under it ("16:00 [ ] Task"), or the only task nested under a timed
--- line; the block lasts its own range ("16:00 - 17:30") or
--- until the next timed line of the day at its indent. The size is the one
--- whose hours are closest by ratio (45 minutes is md, not sm), the larger
--- on a tie. `sizes` maps size -> hours (xp.sizes.task). app/edit
--- CalendarSize is the same, checked by tests/fixtures/autosize.json.
---@return string? size
function M.calendar_size(lines, lnum, sizes)
	local syntax = require("zortex.core.syntax")
	local line = lines[lnum]
	local t = line and Item.task(line)
	if not t or not t.completed or (t.attributes and t.attributes.size) then
		return nil
	end
	-- the timed line it is, or is nested under
	local own = indent_width(line)
	local head
	local d0 = syntax.classify(line)
	if d0.item and d0.item.marker_type == "time" then
		head = lnum -- "16:00 [ ] Task": its own block
	end
	for l = head and 0 or lnum - 1, 1, -1 do
		local text = lines[l]
		if text:match("%S") then
			if indent_width(text) < own then
				local d = syntax.classify(text)
				if d.kind == "item" and d.item and d.item.marker_type == "time" then
					head = l
				end
				break
			end
			if require("zortex.utils.datetime").date_heading(text) then
				break
			end
		end
	end
	if not head then
		return nil
	end
	local base = indent_width(lines[head])
	local time = syntax.classify(lines[head]).item.time
	-- exactly one task in the block
	local count, after = 0, #lines + 1
	for l = head + 1, #lines do
		local text = lines[l]
		if text:match("%S") then
			if indent_width(text) <= base or require("zortex.utils.datetime").date_heading(text) then
				after = l
				break
			end
			local d = syntax.classify(text)
			if d.kind == "item" and d.item and d.item.mark then
				count = count + 1
			end
		end
	end
	-- exactly one task: itself (a timed task with tasks under it is a group)
	if count ~= (head == lnum and 0 or 1) then
		return nil
	end
	-- its length in minutes
	local start = minutes(time.from or time.at)
	local stop = minutes(time.to)
	if not stop then
		for l = after, #lines do
			local text = lines[l]
			if require("zortex.utils.datetime").date_heading(text) then
				break
			end
			if text:match("%S") and indent_width(text) == base then
				local d = syntax.classify(text)
				if d.kind == "item" and d.item and d.item.marker_type == "time" then
					stop = minutes(d.item.time.from or d.item.time.at)
					break
				end
			end
		end
	end
	if not start or not stop or stop <= start then
		return nil
	end
	local hours = (stop - start) / 60
	local best, best_d, best_h
	for name, h in pairs(sizes or {}) do
		if type(h) == "number" and h > 0 then
			local d = math.abs(math.log(h / hours))
			if not best or d < best_d - 1e-9 or (math.abs(d - best_d) <= 1e-9 and h > best_h) then
				best, best_d, best_h = name, d, h
			end
		end
	end
	return best
end

--- Add the block's size to a just-completed calendar task (calendar_size),
--- in a buffer or file. Returns the new line, or nil.
function M.size_from_block(path_or_buf, lnum)
	local lines = workspace.get_lines(path_or_buf)
	local Config = require("zortex.config")
	local conf = Config.xp or Config.defaults.xp
	local size = M.calendar_size(lines, lnum, (conf.sizes or Config.defaults.xp.sizes).task)
	if not size then
		return nil
	end
	local new_line = lines[lnum] .. " @" .. size
	workspace.set_line(path_or_buf, lnum, new_line)
	return new_line
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

	-- A project heading: mark the project done (or reopen it)
	if not task then
		local project, perr = M.toggle_project(doc_context, should_complete)
		if project or perr then
			return project, perr
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

	-- Ensure task has ID: a calendar task linking a task takes that task's
	-- @id (becoming its copy); anything else gets a new one
	if not task.attributes or not task.attributes.id then
		local id = M.linked_id(doc_context) or generate_task_id()
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

--- For a calendar task line with no @id whose link points at a task in
--- another note: that task's @id, added to the task first when it has none.
--- Toggling the line then makes it a copy of the task (services/mirrors).
function M.linked_id(doc_context)
	local mirrors = require("zortex.services.mirrors")
	local path = doc_context.filepath and vim.fn.fnamemodify(doc_context.filepath, ":p")
	if not path or path ~= mirrors.calendar_path() or not doc_context.doc then
		return nil
	end
	local target = mirrors.reference_of_copy(doc_context.doc, doc_context.lnum)
	if not target or vim.fn.fnamemodify(target.file, ":p") == path then
		return nil
	end
	return (mirrors.ensure_id(target.file, target.lnum))
end

--- On a project's heading: add @done(today) to it, or take it off. A
--- project with open tasks asks first (vim.ui.select). Returns the project
--- (nil, nil when the line is no project heading); with opts.on_done, it is
--- called once the edit is made (or not, when the question is declined).
---@param opts { today?: string, on_done?: fun(done: boolean?) }?
function M.toggle_project(doc_context, should_complete, opts)
	opts = opts or {}
	local kind = require("zortex.core.syntax").classify(doc_context.line).kind
	if kind ~= "heading" then
		return nil
	end
	local ok, project = pcall(require("zortex.services.projects").at, doc_context.bufnr, doc_context.lnum)
	if not ok or not project or project.lnum ~= doc_context.lnum or project:is_root() then
		return nil
	end
	local done = project.attributes.done ~= nil
	local want = should_complete
	if want == nil then
		want = not done
	end
	local function finish(result)
		if opts.on_done then
			opts.on_done(result)
		end
	end
	if want == done then
		finish(want)
		return project
	end
	local function apply()
		local line = vim.api.nvim_buf_get_lines(doc_context.bufnr, doc_context.lnum - 1, doc_context.lnum, false)[1]
		local new_line = want and attributes.update_attribute(line, "done", opts.today or os.date("%Y-%m-%d"))
			or attributes.remove_attribute(line, "done")
		workspace.set_line(doc_context.bufnr, doc_context.lnum, new_line)
		Events.emit(want and "project:completed" or "project:uncompleted", { project = project, doc_context = doc_context })
		vim.notify(
			string.format("%s project %s", want and "Done:" or "Reopened:", project.name),
			vim.log.levels.INFO,
			{ title = "Zortex" }
		)
		finish(want)
	end
	local open = want and project:rollup().open or 0
	if open == 0 then
		apply()
		return project
	end
	vim.ui.select({ "Mark it done", "Cancel" }, {
		prompt = string.format("%s has %d open task%s:", project.name, open, open == 1 and "" or "s"),
	}, function(choice)
		if choice == "Mark it done" then
			apply()
		else
			finish(nil)
		end
	end)
	return project
end

--- After the task on `path`:`lnum` was checked or reopened (`line`, as it
--- now reads): its copies follow (services/mirrors), and so do the tasks of
--- its group (services/task_groups: checking a group checks its tasks, the
--- last task checked checks the group, a task reopened reopens the groups
--- above it), then their copies, and so on.
function M.propagate(path, lnum, line)
	if not path then
		return
	end
	local mirrors = require("zortex.services.mirrors")
	local groups = require("zortex.services.task_groups")
	local today = os.date("%Y-%m-%d")
	local queue, seen, i = { { path = path, lnum = lnum, line = line } }, {}, 1
	while i <= #queue do
		local q = queue[i]
		i = i + 1
		local key = vim.fn.fnamemodify(q.path, ":p") .. ":" .. q.lnum
		if not seen[key] then
			seen[key] = true
			local _, copies = mirrors.sync(q.path, q.lnum, q.line)
			vim.list_extend(queue, copies or {})
			for _, e in ipairs(groups.cascade(workspace.get_lines(q.path), q.lnum, today, mirrors.set_done)) do
				workspace.set_line(q.path, e.lnum, e.line)
				queue[#queue + 1] = { path = q.path, lnum = e.lnum, line = e.line }
			end
		end
	end
end

--- Toggle the task on `path`:`lnum` (a buffer when loaded, else the file),
--- as the toggle key does there: its copies and group follow, and the only
--- task of a calendar block gets its size. Returns the task.
function M.toggle_at(path, lnum)
	local line = workspace.get_lines(path)[lnum]
	local task = line and Item.task(line)
	if not task then
		return nil, "not a task"
	end
	local want = not task.completed
	local new_line, err = M.edit_line(line, want and "done" or "open")
	if not new_line then
		return nil, err
	end
	workspace.set_line(path, lnum, new_line)
	if want then
		new_line = M.size_from_block(path, lnum) or new_line
	end
	M.propagate(path, lnum, new_line)
	local t = Item.task(new_line, { lnum = lnum, file = path })
	local ctx = { file = path, filepath = path, lnum = lnum, line = new_line }
	Events.emit(want and "task:completed" or "task:uncompleted", { task = t, doc_context = ctx })
	return t
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
	M.propagate(ref.file, ref.lnum, new_line)
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

return M
