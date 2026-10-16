-- features/move.lua - :ZortexMove (<leader>zM): move the section or line
-- under the cursor (or the selected lines) to a place picked in the
-- structural search (services/move does the edit).
--
-- The picker is the search picker: sections (headings, bold headings,
-- labels, notes) and the lines that match. Picking a section puts what
-- moves under it; picking a line (a list item) nests it under that line.
local M = {}

local Move = require("zortex.services.move")
local workspace = require("zortex.core.workspace")

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Zortex" })
end

-- Where a picked search result points: file, line, and whether it is a
-- section (else a line)
local function place_of(result)
	if result.result_type == "section" then
		local article = result.node.type == "article"
		return { file = result.filepath, lnum = article and 1 or result.node.start_line, section = true, text = result.breadcrumb }
	end
	return { file = result.filepath, lnum = result.lnum, line = result.line, text = vim.trim(result.line or "") }
end

--- Move `src` (services/move.source) of `file` to the search result picked.
function M.move_to(file, src, result)
	local place = place_of(result)
	local doc = workspace.document(place.file)
	if not doc then
		return nil, "can't read " .. place.file
	end
	-- the result came from the search index: the line must still be there
	if place.line and doc.lines[place.lnum] ~= place.line then
		return nil, "the notes changed since the search: try again"
	end
	local dst, err = Move.target(doc, place.lnum, src)
	if not dst then
		return nil, err
	end
	-- links into what moves may need a look afterwards
	local refs = 0
	local ok_refs, list = pcall(require("zortex.core.link_index").references, file, src.first, src.last)
	if ok_refs then
		for _, r in ipairs(list) do
			if not (vim.fn.fnamemodify(r.file, ":p") == vim.fn.fnamemodify(file, ":p") and r.lnum >= src.first and r.lnum <= src.last) then
				refs = refs + 1
			end
		end
	end
	local at, merr = Move.move(file, src, place.file, dst)
	if not at then
		return nil, merr
	end
	return { at = at, file = place.file, where = place.text, links = refs }
end

--- Move line `first` of `file` (with what is nested under it; or the lines
--- first..last) to a place picked in the structural search. `on_done(res)`
--- runs after a move.
function M.pick(file, first, last, on_done)
	local doc = workspace.document(file)
	if not doc then
		return notify("Can't read " .. file, vim.log.levels.WARN)
	end
	local src, err = Move.source(doc, first, last)
	if not src then
		return notify("Can't move: " .. err, vim.log.levels.WARN)
	end
	local what = vim.trim(doc.lines[src.first])
	local n = src.last - src.first + 1

	local search = require("zortex.ui.picker.search")
	local spec = search.spec({ all_sections = true, new_note = false })
	local base_title = spec.title
	spec.title = function()
		return string.format("Move %q%s to…  %s", #what > 40 and (what:sub(1, 40) .. "…") or what, n > 1 and (" (" .. n .. " lines)") or "", base_title())
	end
	spec.on_open = nil -- not a visit: leave the search history alone
	spec.open = function(result)
		local done, merr = M.move_to(file, src, result)
		if not done then
			return notify("Can't move: " .. merr, vim.log.levels.WARN)
		end
		local where = done.where or vim.fn.fnamemodify(done.file, ":t")
		local msg = string.format("Moved %d line%s under %s", n, n == 1 and "" or "s", where)
		if done.links > 0 then
			msg = msg .. string.format(" · %d link%s pointed into it: :ZortexBrokenLinks shows any that broke", done.links, done.links == 1 and "" or "s")
		end
		notify(msg)
		if on_done then
			on_done(done)
		end
	end
	return require("zortex.ui.picker").pick(spec)
end

--- :ZortexMove: what is under the cursor (or lines line1..line2) to a place
--- picked in the structural search.
---@param opts { line1?: integer, line2?: integer, range?: integer }?
function M.move_current(opts)
	opts = opts or {}
	local ctx = workspace.get_doc_context()
	if not ctx then
		return notify("Not a note buffer", vim.log.levels.WARN)
	end
	local first = (opts.range or 0) > 0 and opts.line1 or ctx.lnum
	local last = (opts.range or 0) > 0 and opts.line2 or nil
	return M.pick(ctx.filepath, first, last)
end

return M
