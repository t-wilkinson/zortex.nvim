-- services/areas/assign.lua - Giving finished work an area
--
-- Area XP goes to the areas work is linked to: the objective a key result
-- links its project to, the project's @area(…), the task's own. Work with
-- none of those earns for the default area (xp.default_area, @a(0.1)) and
-- is `unassigned` in the ledger. The daily review lists what was finished
-- that way, so it can get a real area (A), and when it closes writes
-- @a(<default>) on the rest: the note then says where its XP went.
--
-- A project task is given its area on its project's heading (the project
-- and its sub-projects inherit it); a task outside projects (the calendar,
-- any note), or one directly under a project note's root, on its own line.
--
--   local assign = require("zortex.services.areas.assign")
--   assign.unassigned(from, to)   -- { { kind = "project"|"task", file, lnum, title, xp, count, date, project?, tasks? } }
--   assign.set(item, "4.1")       -- @a(4.1) on its line (one undoable batch)
--   assign.stamp(items)           -- @a(<default>) on each still without one
local M = {}

local function ws()
	return require("zortex.core.workspace")
end

local function ledger()
	return require("zortex.services.xp.ledger")
end

--- Finished work without an area, dated in [from, to] (YYYY-MM-DD): one
--- item per project (its tasks counted together, and listed in `tasks`:
--- each can get an area of its own), one per loose task. Newest first.
function M.unassigned(from, to, l)
	l = l or ledger().get()
	local projects = require("zortex.services.projects")
	local notes = require("zortex.core.notes")
	local by_project, out = {}, {}
	for _, e in ipairs(l.entries) do
		-- archived work is out of sight: it keeps earning for the default area
		if
			e.unassigned
			and e.date
			and e.date >= from
			and e.date <= to
			and e.file
			and e.lnum
			and not notes.is_archived(e.file)
		then
			local p = e.project and projects.get(e.project)
			if p and not p:is_root() then
				local item = by_project[p.key]
				if not item then
					item = {
						kind = "project",
						project = p,
						key = p.key,
						file = p.file,
						lnum = p.lnum,
						title = p.name,
						link = p.link,
						xp = 0,
						count = 0,
						date = e.date,
						kr = e.aligned == "kr",
						tasks = {},
					}
					by_project[p.key] = item
					out[#out + 1] = item
				end
				item.xp = item.xp + (e.xp or 0)
				item.count = item.count + (e.source == "project_done" and 0 or 1)
				if e.source == "project_task" then
					item.tasks[#item.tasks + 1] = {
						kind = "task",
						file = e.file,
						lnum = e.lnum,
						title = e.title,
						xp = e.xp or 0,
						count = 1,
						date = e.date,
					}
				end
				if e.date > item.date then
					item.date = e.date
				end
			elseif e.source == "task" or e.source == "project_task" then
				out[#out + 1] = {
					kind = "task",
					file = e.file,
					lnum = e.lnum,
					title = e.title,
					xp = e.xp or 0,
					count = 1,
					date = e.date,
				}
			end
		end
	end
	table.sort(out, function(a, b)
		if a.date ~= b.date then
			return a.date > b.date
		end
		return (a.title or "") < (b.title or "")
	end)
	return out
end

-- The line still is the item: its project's heading, or a checked task
-- with its title
local function still_there(item, line)
	if not line then
		return false
	end
	if item.kind == "project" then
		local p = require("zortex.services.projects").get(item.key)
		return p ~= nil and p.lnum == item.lnum and vim.fn.fnamemodify(p.file, ":p") == vim.fn.fnamemodify(item.file, ":p")
	end
	local plain = require("zortex.core.syntax").strip_attributes(line)
	return plain:find(item.title or "", 1, true) ~= nil
end

-- `line` with @a(value) as its only area attribute
local function with_area(line, value)
	local attributes = require("zortex.utils.attributes")
	line = attributes.remove_attribute(line, "area")
	line = attributes.remove_attribute(line, "a")
	return attributes.update_attribute(line, "a", value)
end

local function write(item, value)
	local lines = ws().get_lines(item.file)
	local line = lines[item.lnum]
	if not still_there(item, line) then
		return nil, "the line changed: refresh first"
	end
	local new = with_area(line, value)
	if new == line then
		return true
	end
	return ws().set_line(item.file, item.lnum, new)
end

--- Give `item` (from M.unassigned) the area `value` (an @area(…) value:
--- "4.1", "1.2/Fitness"). One batch: :ZortexUndo takes it back.
function M.set(item, value)
	if not (item and value and value ~= "") then
		return nil, "no area"
	end
	return ws().batch("area " .. value, { item.file }, function()
		return write(item, value)
	end)
end

--- Write @a(<xp.default_area>) on every item still without an area (one
--- batch). Returns how many were written, or nil and why not.
function M.stamp(items)
	local value = require("zortex.services.xp.calculator").default_area_value()
	if not value then
		return 0
	end
	-- an @a(0.1) that names no area would say nothing: areas.zortex needs it
	if not require("zortex.services.areas").default_area() then
		return nil, "@a(" .. value .. ") names no area: add a heading for it to areas.zortex (## " .. value .. " Unassigned)"
	end
	if not (items and #items > 0) then
		return 0
	end
	local files = {}
	for _, it in ipairs(items) do
		files[#files + 1] = it.file
	end
	local n = 0
	local ok, err = ws().batch("default area " .. value, files, function()
		-- bottom up per file, so line numbers above stay put
		local sorted = { unpack(items) }
		table.sort(sorted, function(a, b)
			if a.file ~= b.file then
				return a.file < b.file
			end
			return a.lnum > b.lnum
		end)
		for _, it in ipairs(sorted) do
			if write(it, value) then
				n = n + 1
			end
		end
		return true
	end)
	if ok == nil then
		return nil, err
	end
	return n
end

M._with_area = with_area

return M
