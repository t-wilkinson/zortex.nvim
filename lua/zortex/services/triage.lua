-- services/triage.lua - Inbox triage: @project(…) says where a line goes
--
-- An inbox line, or a task anywhere, can carry @project(1.4): the project it
-- belongs to, the way @a(4.1) names an area. The daily review lists them
-- with the rest of the inbox, and `m` moves each one (with the lines nested
-- under it) to the end of its project's own lines, dropping the attribute.
-- A line without @project goes to review.inbox_default when it is set (a
-- place in the notes, e.g. "P/#Areas": a copy of the area tree in the
-- projects note for maintenance tasks too small to be projects); otherwise
-- `m` asks where, with :ZortexMove's search.
--
--   M.link(value)        "1.4" -> "[P/#1.4]", "1/1.4" -> "[P/#1/#1.4]",
--                        "P/#Kitchen" or "[P/#Kitchen]" as written
--   M.items()            inbox lines, then lines elsewhere with @project
--   M.destination(item)  the link `m` would move it to, or nil
--   M.move(item, link?)  the move (services/move); returns where it went
local M = {}

local workspace = require("zortex.core.workspace")

--- The link a @project(...) value names (nil for an empty one). Plain
--- headings of the projects note ("1.4", "1/1.4", "Kitchen shelves"), or a
--- link written out ("P/#Kitchen", "[Flipping/#Subaru]").
function M.link(value)
	value = vim.trim(value or "")
	if value == "" then
		return nil
	end
	if value:sub(1, 1) == "[" then
		return value
	end
	if value:find("#", 1, true) or value:find("^@") then
		return "[" .. value .. "]"
	end
	local parts = {}
	for part in value:gmatch("[^/]+") do
		parts[#parts + 1] = "#" .. vim.trim(part)
	end
	return "[P/" .. table.concat(parts, "/") .. "]"
end

--- The @project value of a line, or nil.
function M.value(line)
	return line and line:match("@project%(([^)]*)%)")
end

local function default_link()
	local d = (require("zortex.config").review or {}).inbox_default
	if not d or d == "" then
		return nil
	end
	return d:sub(1, 1) == "[" and d or ("[" .. d .. "]")
end

--- What to sort: every inbox line (agenda.inbox), then the lines of other
--- notes that carry @project. Each { file, lnum, text, project? (a link) }.
function M.items()
	local inbox = require("zortex.services.agenda").inbox()
	local out, seen = {}, {}
	for _, x in ipairs(inbox) do
		local v = M.value(x.text)
		x.project = v and M.link(v) or nil
		x.inbox = true
		out[#out + 1] = x
		seen[vim.fn.fnamemodify(x.file, ":p") .. ":" .. x.lnum] = true
	end
	local Document = require("zortex.core.document")
	for _, path in ipairs(require("zortex.core.notes").index({ fresh = true }).files) do
		local doc = Document.get(path)
		for lnum, line in ipairs(doc and doc.lines or {}) do
			if line:find("@project(", 1, true) and not doc:in_code(lnum) then
				local key = vim.fn.fnamemodify(path, ":p") .. ":" .. lnum
				local d = doc:info(lnum)
				local mark = d and d.item and d.item.mark
				if not seen[key] and mark ~= "x" and mark ~= "X" and mark ~= ">" then
					out[#out + 1] = { file = path, lnum = lnum, text = vim.trim(line), project = M.link(M.value(line)) }
				end
			end
		end
	end
	return out
end

--- Where `m` moves the item: its @project, else review.inbox_default.
function M.destination(item)
	return item.project or default_link()
end

--- Move `item` (from M.items) to `link` (default M.destination): the line
--- and the lines nested under it, without its @project, to the end of the
--- place's own lines. Returns { file, at, link } or nil, err.
function M.move(item, link)
	link = link or M.destination(item)
	local target = link and require("zortex.core.link").resolve_first(link)
	-- one batch (core/workspace): :ZortexUndo takes it back in every note,
	-- the ones whose links follow the line too (services/move.link_edits)
	local files = { item.file, target and target.file }
	local src = require("zortex.services.move").source(workspace.document(item.file), item.lnum)
	if src then
		local ok, refs = pcall(require("zortex.core.link_index").references, item.file, src.first, src.last)
		for _, r in ipairs(ok and refs or {}) do
			files[#files + 1] = r.file
		end
	end
	return workspace.batch("inbox: move to " .. tostring(link), files, function()
		return M._move(item, link)
	end)
end

function M._move(item, link)
	if not link then
		return nil, "no @project, and review.inbox_default isn't set"
	end
	local lines = workspace.get_lines(item.file)
	local line = lines[item.lnum]
	if not line or vim.trim(line) ~= item.text then
		return nil, "the line changed since the review: refresh with r"
	end
	local target = require("zortex.core.link").resolve_first(link)
	if not target then
		return nil, "nothing found for " .. link
	end
	if vim.fn.fnamemodify(target.file, ":p") == vim.fn.fnamemodify(item.file, ":p") and target.lnum == item.lnum then
		return nil, "it is already there"
	end
	workspace.set_line(item.file, item.lnum, require("zortex.utils.attributes").remove_attribute(line, "project"))
	local Move = require("zortex.services.move")
	local src, err = Move.source(workspace.document(item.file), item.lnum)
	if not src then
		workspace.set_line(item.file, item.lnum, line)
		return nil, err
	end
	local dst, derr = Move.target(workspace.document(target.file), target.lnum, src)
	if not dst then
		workspace.set_line(item.file, item.lnum, line)
		return nil, derr
	end
	for _, e in ipairs(Move.link_edits(item.file, src, target.file, dst)) do
		workspace.set_line(e.file, e.lnum, e.line)
	end
	local at, merr = Move.move(item.file, src, target.file, dst)
	if not at then
		workspace.set_line(item.file, item.lnum, line)
		return nil, merr
	end
	return { file = target.file, at = at, link = link }
end

return M
