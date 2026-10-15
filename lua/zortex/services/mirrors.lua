-- services/mirrors.lua - One task in several places: shared @id
--
-- Putting a project task on the calendar copies it there with the same
-- @id ("- [ ] [P/#1.4 - zortex/-Improve website] @id(aB3x9)"), so you can
-- tick it and track time on it from the day. Lines in the calendar and the
-- project sources (the Projects note and @P notes) that carry the same @id
-- are the same task:
--
--   status   a project task is done when it, or any calendar copy, is checked;
--            its @done is the earliest of them (Project:tasks applies this)
--   XP       paid once, by the project (services/xp/ledger skips calendar
--            copies of project tasks)
--   time     @spent adds up over the copies (spent_total)
--   toggling a line in Neovim or on the web updates every other line with
--            its @id (sync), so the files read the same; when they don't
--            (a hand edit), the rule above still holds
--
-- Copies carried to a later day are marked [>] (moved, see carry_forward):
-- neither open nor done, and left alone by sync.
--
-- A calendar line without a checkbox whose link points at a task
-- ("- [P/#1.4 - zortex/-Improve website]", "09:00 [./-Improve website]") is a
-- reference: it shows the task's state and toggling it toggles the task
-- (reference).
--
-- `zortex serve` has the same rules (app/web/mirrors.go).
local M = {}

M.MOVED = ">"

local Item = require("zortex.core.item")
local attributes = require("zortex.utils.attributes")

local function Document()
	return require("zortex.core.document")
end

local function fs()
	return require("zortex.utils.filesystem")
end

local function normalize(path)
	return vim.fn.fnamemodify(path, ":p")
end

local function date_string(v)
	return require("zortex.services.xp.ledger").date_string(v)
end

local function minutes(v)
	if type(v) == "number" then
		return v
	elseif type(v) == "string" then
		return require("zortex.utils.datetime").parse_durations(v) or 0
	end
	return 0
end
M.minutes = minutes

--- "@id(x)" of a line, or nil.
function M.id_of(line)
	return line and line:match("@id%(([^)%s]+)%)")
end

--- The calendar note (path) and its current snapshot (nil when missing).
function M.calendar_path()
	return normalize(fs().get_calendar_file())
end

function M.calendar_doc()
	local path = M.calendar_path()
	if not vim.uv.fs_stat(path) and vim.fn.bufnr(path) <= 0 then
		return nil
	end
	return Document().get(path)
end

--- Calendar tasks with an @id: id -> { lines = { Item }, done, date (the
--- earliest @done value of a checked copy), spent (minutes) }. Cached on the
--- calendar snapshot.
function M.copies()
	local doc = M.calendar_doc()
	if not doc then
		return {}
	end
	if doc._mirror_copies then
		return doc._mirror_copies
	end
	local out = {}
	for lnum, line in ipairs(doc.lines) do
		if line:find("@id(", 1, true) and not doc:in_code(lnum) then
			local t = Item.task(line, { lnum = lnum, file = doc.filepath })
			local id = t and t.attributes.id
			if id then
				local c = out[id] or { lines = {}, done = false, spent = 0 }
				out[id] = c
				c.lines[#c.lines + 1] = t
				c.spent = c.spent + minutes(t.attributes.spent)
				if t.completed then
					c.done = true
					local d = date_string(t.attributes.done)
					if d and (not c.date_str or d < c.date_str) then
						c.date_str, c.date = d, t.attributes.done
					end
				end
			end
		end
	end
	doc._mirror_copies = out
	return out
end

--- Apply the calendar copies to a project's tasks (in place): a task with a
--- checked copy is completed (task.done_on_calendar, its @done the copy's
--- when it has none); task.copies are its copies, task.spent_total its
--- @spent plus theirs.
function M.apply(tasks)
	local copies = M.copies()
	for _, task in ipairs(tasks) do
		local id = task.attributes and task.attributes.id
		local c = id and copies[id]
		task.spent_total = minutes(task.attributes and task.attributes.spent)
		if c then
			task.copies = c.lines
			task.spent_total = task.spent_total + c.spent
			if c.done and not task.completed then
				task.completed = true
				task.done_on_calendar = true
				task.attributes.done = task.attributes.done or c.date
			end
		end
	end
	return tasks
end

--- Paths whose tasks can share an @id: the project sources and the calendar.
function M.paths()
	local out = vim.list_slice(require("zortex.services.projects").sources())
	local cal = M.calendar_path()
	if not vim.tbl_contains(out, cal) and (vim.uv.fs_stat(cal) or vim.fn.bufnr(cal) > 0) then
		out[#out + 1] = cal
	end
	return out
end

--- @id -> { file, lnum } of the project tasks that carry one (the first, when
--- several do: see issues).
function M.project_ids()
	local out = {}
	for _, p in ipairs(require("zortex.services.projects").all()) do
		for _, t in ipairs(p:tasks()) do
			local id = t.attributes and t.attributes.id
			if id and not out[id] then
				out[id] = { file = t.file or p.doc.filepath, lnum = t.lnum, task = t, project = p }
			end
		end
	end
	return out
end

-- =============================================================================
-- Editing
-- =============================================================================

--- `line` with its checkbox done (with @done(date)) or open.
function M.set_done(line, done, date)
	local t = Item.task(line)
	if not t then
		return line
	end
	local constants = require("zortex.constants")
	local new = t:with_mark(done and constants.TASK_MARKS.COMPLETED or constants.TASK_MARKS.TODO)
	if done then
		return attributes.update_attribute(new, "done", date or os.date("%Y-%m-%d"))
	end
	return attributes.remove_attribute(new, "done")
end

--- After the task on `path`:`lnum` changed to `line`, give every other line
--- with its @id (project sources and calendar) the same state. Copies marked
--- [>] (moved) are left alone. Returns how many lines changed.
function M.sync(path, lnum, line)
	local t = Item.task(line)
	local id = t and t.attributes.id
	if not id or t.mark == M.MOVED then
		return 0
	end
	local done = t.completed
	local date = line:match("@done%(([^)]*)%)")
	local workspace = require("zortex.core.workspace")
	path = path and normalize(path)
	local needle = "@id(" .. id .. ")"
	local changed = 0
	for _, p in ipairs(M.paths()) do
		local lines = workspace.get_lines(p)
		for l, text in ipairs(lines) do
			if not (p == path and l == lnum) and text:find(needle, 1, true) then
				local other = Item.task(text)
				if other and other.mark ~= M.MOVED and other.completed ~= done then
					workspace.set_line(p, l, M.set_done(text, done, date))
					changed = changed + 1
				end
			end
		end
	end
	return changed
end

--- The id of the task on `path`:`lnum`, adding a new @id to it when it has
--- none (written to the buffer or file).
function M.ensure_id(path, lnum)
	local workspace = require("zortex.core.workspace")
	local line = workspace.get_lines(path)[lnum]
	if not line then
		return nil, "No line " .. lnum
	end
	local id = M.id_of(line)
	if id then
		return id
	end
	id = require("zortex.services.tasks").new_id()
	workspace.set_line(path, lnum, attributes.add_attribute(line, "id", id))
	return id
end

-- =============================================================================
-- References: a line without a checkbox linking a task
-- =============================================================================

--- When line `lnum` of `lines` (in `doc`) has no checkbox and its first link
--- points at a task: { file, lnum, task (Item), line }. Otherwise nil.
function M.reference(lines, lnum, doc)
	local line = lines[lnum]
	if not line or not line:find("[", 1, true) then
		return nil
	end
	local item = Item.from_line(line)
	if item and item.mark then
		return nil
	end
	local link = require("zortex.core.link")
	local first = link.links_on(line)[1]
	if not first then
		return nil
	end
	local def, err = link.absolute(first.definition, lines, lnum)
	if not def or err or link.relative_path(def, (doc and doc.filepath) or "") then
		return nil
	end
	local ok, r = pcall(link.resolve_first, "[" .. def .. "]", { doc = doc, lnum = lnum })
	if not ok or not r or r.whole then
		return nil
	end
	local target = r.doc.lines[r.lnum]
	local task = Item.task(target, { lnum = r.lnum, file = r.file })
	if not task then
		return nil
	end
	return { file = r.file, lnum = r.lnum, task = task, line = target }
end

-- =============================================================================
-- Problems worth a look
-- =============================================================================

--- Copies and ids that don't line up: { { file, lnum, text, problem } }.
---   two project tasks with the same @id (a copied line): the first counts
---   a calendar copy whose link points at a different task than its @id
function M.issues()
	local out = {}
	local seen = {}
	for _, p in ipairs(require("zortex.services.projects").all()) do
		for _, t in ipairs(p:tasks()) do
			local id = t.attributes and t.attributes.id
			if id then
				if seen[id] then
					out[#out + 1] = {
						file = t.file or p.doc.filepath,
						lnum = t.lnum,
						text = t.text,
						problem = "@id(" .. id .. ") is also on " .. vim.fn.fnamemodify(seen[id].file, ":t") .. ":" .. seen[id].lnum,
					}
				else
					seen[id] = { file = t.file or p.doc.filepath, lnum = t.lnum }
				end
			end
		end
	end
	local doc = M.calendar_doc()
	if doc then
		for id, c in pairs(M.copies()) do
			local origin = seen[id]
			if origin then
				for _, copy in ipairs(c.lines) do
					local ref = M.reference_of_copy(doc, copy.lnum)
					if ref and not (normalize(ref.file) == normalize(origin.file) and ref.lnum == origin.lnum) then
						out[#out + 1] = {
							file = doc.filepath,
							lnum = copy.lnum,
							text = copy.text,
							problem = "@id(" .. id .. ") is "
								.. vim.fn.fnamemodify(origin.file, ":t")
								.. ":"
								.. origin.lnum
								.. " but the link points at "
								.. vim.fn.fnamemodify(ref.file, ":t")
								.. ":"
								.. ref.lnum,
						}
					end
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.lnum < b.lnum
	end)
	return out
end

--- Where a calendar copy's own link points (a task line), or nil.
function M.reference_of_copy(doc, lnum)
	local line = doc.lines[lnum]
	local link = require("zortex.core.link")
	local first = link.links_on(line)[1]
	if not first then
		return nil
	end
	local def = link.absolute(first.definition, doc.lines, lnum)
	if not def or link.relative_path(def, doc.filepath) then
		return nil
	end
	local ok, r = pcall(link.resolve_first, "[" .. def .. "]", { doc = doc, lnum = lnum })
	if not ok or not r or r.whole or not Item.task(r.doc.lines[r.lnum]) then
		return nil
	end
	return { file = r.file, lnum = r.lnum }
end

return M
