-- features/move.lua - :ZortexMove (<leader>zM): move or rename what is under
-- the cursor, as `mv` does a file, and keep every link to it working.
--
--   :ZortexMove                on a heading, bold heading or label: asks for
--                              its new name; leave it as it is to pick a
--                              place instead. Anywhere else (or on a
--                              selection): pick a place in the structural
--                              search
--   :ZortexMove New title      rename the section under the cursor
--   :ZortexMove [P/#7 Home]    move it under that place
--
-- Renaming (features/rename) rewrites the component of every link that
-- found the old title. Moving (services/move) puts the section, or the line
-- with what is nested under it, under the place picked, and rewrites the
-- links that would no longer reach it (services/move.link_edits). Either way
-- the notes changed are one batch: :ZortexUndo takes it all back. When links
-- in other notes change, it says which and asks first.
--
-- The picker is the search picker: sections (headings, bold headings,
-- labels, notes) and the lines that match. Picking a section puts what
-- moves under it; picking a line (a list item) nests it under that line.
local M = {}

local Move = require("zortex.services.move")
local workspace = require("zortex.core.workspace")

local SECTION = { heading = true, bold_heading = true, label = true }

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Zortex" })
end

local function full(path)
	return vim.fn.fnamemodify(path, ":p")
end

-- =============================================================================
-- Asking first
-- =============================================================================

--- Ask before changing notes other than `here`: `summary` (a sentence),
--- then the changed lines (`edits`: { file, lnum, line }), with Go / List /
--- Cancel. List puts the lines in the quickfix list and asks again. True to
--- go ahead; true without asking when only `here` (and `also`, the notes the
--- user chose) change. Tests replace it.
function M.confirm(summary, edits, here, also)
	local mine = { [full(here)] = true }
	for _, f in ipairs(also or {}) do
		mine[full(f)] = true
	end
	local others, closed, seen = 0, 0, {}
	for _, e in ipairs(edits) do
		local p = full(e.file)
		if not mine[p] and not seen[p] then
			seen[p] = true
			others = others + 1
			local b = vim.fn.bufnr(p)
			if b <= 0 or not vim.api.nvim_buf_is_loaded(b) then
				closed = closed + 1
			end
		end
	end
	if others == 0 then
		return true
	end
	local lines = {
		summary
			.. string.format(
				" Links change in %d other note%s%s.",
				others,
				others == 1 and "" or "s",
				closed > 0 and string.format(" (%d not open: loaded, changed and saved)", closed) or ""
			),
		"",
	}
	for i, e in ipairs(edits) do
		if i > 8 then
			lines[#lines + 1] = string.format("… and %d more", #edits - 8)
			break
		end
		lines[#lines + 1] = string.format("%s:%d  %s", vim.fn.fnamemodify(e.file, ":t"), e.lnum, vim.trim(e.line))
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = ":ZortexUndo takes it back afterwards."
	while true do
		local choice = vim.fn.confirm(table.concat(lines, "\n"), "&Go ahead\n&List\n&Cancel", 1)
		if choice == 1 then
			return true
		elseif choice == 2 then
			local items = {}
			for _, e in ipairs(edits) do
				items[#items + 1] = { filename = e.file, lnum = e.lnum, text = vim.trim(e.line) }
			end
			vim.fn.setqflist({}, "r", { title = "Move: the lines as they will read", items = items })
			vim.cmd("copen")
			vim.cmd("redraw")
		else
			return false
		end
	end
end

-- =============================================================================
-- Moving
-- =============================================================================

-- Where a picked search result points: file, line, and whether it is a
-- section (else a line)
local function place_of(result)
	if result.result_type == "section" then
		local article = result.node.type == "article"
		return { file = result.filepath, lnum = article and 1 or result.node.start_line, section = true, text = result.breadcrumb }
	end
	return { file = result.filepath, lnum = result.lnum, line = result.line, text = vim.trim(result.line or "") }
end

--- The move of `src` (services/move.source) of `file` to `place` ({ file,
--- lnum, line?, text? }): { src, dst, place, edits (links to rewrite) }, or
--- nil and why. Nothing is written.
function M.plan(file, src, place)
	local doc = workspace.document(place.file)
	if not doc then
		return nil, "can't read " .. place.file
	end
	-- the place came from the search index: the line must still be there
	if place.line and doc.lines[place.lnum] ~= place.line then
		return nil, "the notes changed since the search: try again"
	end
	local dst, err = Move.target(doc, place.lnum, src)
	if not dst then
		return nil, err
	end
	if full(file) == full(place.file) and dst.lnum >= src.first and dst.lnum <= src.last then
		return nil, "it can't go inside itself"
	end
	return { file = file, src = src, dst = dst, place = place, edits = Move.link_edits(file, src, place.file, dst) }
end

--- Make a plan: the link edits, then the move, as one batch (core/workspace).
--- Returns { at, file, where, links } or nil and an error.
function M.apply(plan)
	local files = { plan.file, plan.place.file }
	for _, e in ipairs(plan.edits) do
		files[#files + 1] = e.file
	end
	local at, err = workspace.batch("move", files, function()
		for _, e in ipairs(plan.edits) do
			local ok, eerr = workspace.set_line(e.file, e.lnum, e.line)
			if not ok then
				return nil, eerr
			end
		end
		return Move.move(plan.file, plan.src, plan.place.file, plan.dst)
	end)
	if not at then
		return nil, err
	end
	return { at = at, file = plan.place.file, where = plan.place.text, links = #plan.edits }
end

--- Move `src` of `file` to the search result picked (or a place).
function M.move_to(file, src, result)
	local plan, err = M.plan(file, src, result.filepath and place_of(result) or result)
	if not plan then
		return nil, err
	end
	return M.apply(plan)
end

-- Plan, ask, move, say what happened
local function run_move(file, src, place, n)
	local plan, err = M.plan(file, src, place)
	if not plan then
		return notify("Can't move: " .. err, vim.log.levels.WARN)
	end
	local where = place.text or vim.fn.fnamemodify(place.file, ":t")
	local what = vim.trim(workspace.get_lines(file)[src.first] or "")
	if not M.confirm(string.format("Move %q under %s.", what, where), plan.edits, file, { place.file }) then
		return notify("Move cancelled")
	end
	local done, merr = M.apply(plan)
	if not done then
		return notify("Can't move: " .. merr .. " (:ZortexUndo takes back what was written)", vim.log.levels.WARN)
	end
	local msg = string.format("Moved %d line%s under %s", n, n == 1 and "" or "s", where)
	if done.links > 0 then
		msg = msg .. string.format(" · %d line%s of links rewritten", done.links, done.links == 1 and "" or "s")
	end
	notify(msg .. " · :ZortexUndo takes it back")
	return done
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
		local done = run_move(file, src, place_of(result), n)
		if done and on_done then
			on_done(done)
		end
	end
	return require("zortex.ui.picker").pick(spec)
end

--- Move what starts on line `lnum` of `file` under the place a link names.
function M.to_link(file, lnum, link)
	local doc = workspace.document(file)
	local src, err = Move.source(doc, lnum)
	if not src then
		return notify("Can't move: " .. err, vim.log.levels.WARN)
	end
	local target = require("zortex.core.link").resolve_first(link, { doc = doc, lnum = lnum })
	if not target then
		return notify("Can't move: nothing found for " .. link, vim.log.levels.WARN)
	end
	return run_move(file, src, { file = target.file, lnum = target.lnum, text = link }, src.last - src.first + 1)
end

-- =============================================================================
-- :ZortexMove
-- =============================================================================

--- Rename the section starting on `lnum` of `file` to `new` (features/rename).
function M.rename(file, lnum, new)
	local Rename = require("zortex.features.rename")
	local plan, err = Rename.plan(file, lnum, new)
	if not plan then
		return notify("Can't rename: " .. err, vim.log.levels.WARN)
	end
	local old = plan.node.text
	if not M.confirm(string.format("Rename %q to %q.", old, vim.trim(new)), plan.links, file) then
		return notify("Rename cancelled")
	end
	local files, aerr = Rename.apply(plan)
	if not files then
		return notify("Can't rename: " .. aerr .. " (:ZortexUndo takes back what was written)", vim.log.levels.ERROR)
	end
	notify(
		string.format(
			"Renamed to %s; %d link%s rewritten in %d note%s%s",
			vim.trim(new),
			plan.count,
			plan.count == 1 and "" or "s",
			files,
			files == 1 and "" or "s",
			files > 1 and " · :ZortexUndo takes it back" or ""
		)
	)
	return plan
end

--- :ZortexMove [new title | [link]]: rename or move what is under the
--- cursor (or the selected lines).
---@param opts { line1?: integer, line2?: integer, range?: integer, args?: string }?
function M.move_current(opts)
	opts = opts or {}
	local ctx = workspace.get_doc_context()
	if not ctx then
		return notify("Not a note buffer", vim.log.levels.WARN)
	end
	local file = ctx.filepath
	if (opts.range or 0) > 0 and opts.line2 and opts.line2 > opts.line1 then
		return M.pick(file, opts.line1, opts.line2)
	end
	local lnum = (opts.range or 0) > 0 and opts.line1 or ctx.lnum
	local doc = workspace.document(file)
	local node = doc and doc:node_starting_at(lnum)
	local section = node and SECTION[node.type] and node or nil

	local function go(text)
		text = vim.trim(text or "")
		if text:match("^%[.+%]$") then
			return M.to_link(file, lnum, text)
		end
		if text == "" or not section or text == section.text then
			return M.pick(file, lnum)
		end
		return M.rename(file, section.start_line, text)
	end

	local given = opts.args and vim.trim(opts.args) or ""
	if given ~= "" then
		if not section and not given:match("^%[.+%]$") then
			return notify("Only a heading, bold heading or label can be renamed; give a [link] to move", vim.log.levels.WARN)
		end
		return go(given)
	end
	if not section then
		return M.pick(file, lnum)
	end
	vim.ui.input({ prompt = "Rename to (as is: pick a place; [link]: move there): ", default = section.text }, function(text)
		if text ~= nil then
			go(text)
		end
	end)
end

return M
