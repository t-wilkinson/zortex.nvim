-- services/move.lua - Move a section or a line (with what is nested under
-- it) to another place in the notes, in the same note or another one.
--
--   M.source(doc, lnum, last?)      what moves: the section a heading, bold
--                                   heading or label starts; else the line
--                                   and the lines nested deeper under it;
--                                   with `last`, exactly those lines
--   M.target(doc, lnum, src)        where it goes: under a section (or the
--                                   note itself), or under a line, as a child
--   M.reshape(lines, src, dst)      the lines as they will read there:
--                                   headings re-levelled under their new
--                                   parent, everything re-indented
--   M.move(src_file, src, dst_file, dst)
--                                   the edit (core/workspace: buffers when
--                                   loaded, else the files)
--   M.link_edits(src_file, src, dst_file, dst)
--                                   the lines whose links must change for
--                                   the move to break none (below)
--
-- Links follow what moves. Before the move, every link that reaches into
-- it (core/link_index) is checked: the components that find the moved lines
-- are kept, and what comes before them is replaced by the new place's path
-- only when that part no longer holds the new place ([P/#6.3 Tools] keeps
-- working when 6.3 moves within Projects: headings match at any depth).
-- Inside what moves, "./" links whose parent line stays behind are written
-- out, and "/" links to the rest of the old note get its name when the
-- lines go to another note.
--
-- Where things land:
--   * a heading section goes last among the target's sub-sections, its
--     headings one level below the target heading (# under a note);
--   * anything else goes at the end of the target's own lines, before its
--     first sub-section, indented like those lines (a label's lines start at
--     the label's indent);
--   * under a line (a list item), it goes after that line's nested lines,
--     indented one step (2 spaces) deeper.
-- A heading can only go under a heading or a note: under a label or an item
-- it would end that label's section instead of joining it.
local M = {}

local workspace = require("zortex.core.workspace")

local SECTION = { heading = true, bold_heading = true, label = true }

local function blank(line)
	return not line or not line:find("%S")
end

local function link_mod()
	return require("zortex.core.link")
end

local function indent_of(line)
	return #(line or ""):match("^%s*")
end

-- The last non-blank line of first..last (first when all are blank)
local function trim_end(lines, first, last)
	while last > first and blank(lines[last]) do
		last = last - 1
	end
	return last
end

-- The line plus the lines below it indented deeper (blank lines between
-- them included, trailing ones not); stops at a section start.
local function block_end(doc, lnum)
	local lines = doc.lines
	local w = indent_of(lines[lnum])
	local last = lnum
	for i = lnum + 1, #lines do
		if not blank(lines[i]) then
			if indent_of(lines[i]) <= w or doc:node_starting_at(i) then
				break
			end
			last = i
		end
	end
	return last
end

--- What moves from `lnum` (to `last`, for a range).
---@return { first: integer, last: integer, kind: "heading"|"section"|"lines", node: table? }? src, string? err
function M.source(doc, lnum, last)
	local header_end = (doc.header and doc.header.last_lnum) or 0
	if lnum <= header_end then
		return nil, "the note's header can't move"
	end
	if last and last > lnum then
		return { first = lnum, last = trim_end(doc.lines, lnum, last), kind = "lines" }
	end
	if blank(doc.lines[lnum]) then
		return nil, "nothing to move on a blank line"
	end
	local node = doc:node_starting_at(lnum)
	if node and SECTION[node.type] then
		return {
			first = node.start_line,
			last = trim_end(doc.lines, node.start_line, node.end_line),
			kind = node.type == "heading" and "heading" or "section",
			node = node,
		}
	end
	return { first = lnum, last = block_end(doc, lnum), kind = "lines" }
end

-- The indent of a section's own lines (before its first sub-section), or
-- `default` when it has none
local function own_indent(doc, node, default)
	local first = node:is_root() and ((doc.header and doc.header.last_lnum or 0) + 1) or (node.start_line + 1)
	local last = node:get_direct_end_line()
	local min
	for i = first, last do
		if not blank(doc.lines[i]) then
			local w = indent_of(doc.lines[i])
			min = min and math.min(min, w) or w
		end
	end
	return min or default
end

--- Where `src` goes when the target is line `lnum` of `doc`: a section
--- starting there (or the note, at its first line or header), else that
--- line as a parent.
---@return { at: integer, indent: integer, level: integer?, node: table?, lnum: integer, blank_before: boolean? }? dst, string? err
function M.target(doc, lnum, src)
	local lines = doc.lines
	local header_end = (doc.header and doc.header.last_lnum) or 0
	if doc:in_code(lnum) then
		return nil, "that line is inside a code block"
	end
	local node = doc:node_starting_at(lnum)
	if lnum <= math.max(1, header_end) then
		node = doc:article() or doc.tree -- the note itself
	end

	if node then
		local is_note = node:is_root() or node.type == "article"
		if src.kind == "heading" and not (is_note or node.type == "heading") then
			return nil, "a heading can only go under a heading or a note"
		end
		local level = src.kind == "heading" and (is_note and 1 or (node.level or 0) + 1) or nil
		if level and level > 6 then
			return nil, "too deep: a heading below level 6"
		end
		if src.kind == "heading" then
			-- last among the target's sub-sections
			local last = node:is_root() and #lines or node.end_line
			last = trim_end(lines, math.max(1, header_end), last)
			return { at = last + 1, indent = 0, level = level, node = node, lnum = lnum, blank_before = true }
		end
		-- the end of the target's own lines, before its first sub-section
		local own_last = node:get_direct_end_line()
		local own_first = is_note and (header_end + 1) or node.start_line
		own_last = trim_end(lines, own_first, math.max(own_first, own_last))
		if is_note and own_last < header_end + 1 then
			own_last = header_end -- right below the header
		end
		local default = node.type == "label" and indent_of(lines[node.start_line]) or 0
		return { at = own_last + 1, indent = own_indent(doc, node, default), node = node, lnum = lnum }
	end

	-- under a line: after its nested lines, one step deeper
	if src.kind == "heading" then
		return nil, "a heading can only go under a heading or a note"
	end
	if blank(lines[lnum]) then
		return nil, "no line to put it under"
	end
	return { at = block_end(doc, lnum) + 1, indent = indent_of(lines[lnum]) + 2, lnum = lnum }
end

--- The moved lines as they will read at `dst`.
function M.reshape(lines, src, dst)
	local out = {}
	local base = indent_of(lines[1])
	local shift = dst.indent - base
	local level_shift = 0
	if src.kind == "heading" and dst.level then
		level_shift = dst.level - #lines[1]:match("^(#+)")
	end
	for _, line in ipairs(lines) do
		if blank(line) then
			out[#out + 1] = ""
		elseif line:match("^#+%s") then
			local hashes, rest = line:match("^(#+)(.*)$")
			out[#out + 1] = string.rep("#", math.max(1, math.min(6, #hashes + level_shift))) .. rest
		elseif shift > 0 then
			out[#out + 1] = string.rep(" ", shift) .. line
		elseif shift < 0 then
			local lead = line:match("^%s*")
			out[#out + 1] = lead:sub(1, math.max(0, #lead + shift)) .. line:sub(#lead + 1)
		else
			out[#out + 1] = line
		end
	end
	return out
end

local function same_file(a, b)
	return vim.fn.fnamemodify(a, ":p") == vim.fn.fnamemodify(b, ":p")
end

--- Move `src` of `src_file` to `dst` in `dst_file`. Returns the line the
--- moved text starts at in dst_file, or nil and an error.
function M.move(src_file, src, dst_file, dst)
	local same = same_file(src_file, dst_file)
	if same and dst.lnum >= src.first and dst.lnum <= src.last then
		return nil, "it can't go inside itself"
	end
	local src_lines = workspace.get_lines(src_file)
	local moved = M.reshape(vim.list_slice(src_lines, src.first, src.last), src, dst)
	local dst_lines = same and src_lines or workspace.get_lines(dst_file)
	-- a moved heading section keeps a blank line around it
	if dst.blank_before and not blank(dst_lines[dst.at - 1]) and dst.at > 1 then
		table.insert(moved, 1, "")
	end
	if dst.blank_before and dst_lines[dst.at] and not blank(dst_lines[dst.at]) then
		moved[#moved + 1] = ""
	end

	-- the source goes; a blank line it would leave doubled goes too (not
	-- one the moved lines now sit next to)
	local rm_first, rm_last = src.first, src.last
	if blank(src_lines[rm_first - 1]) and blank(src_lines[rm_last + 1]) and rm_last + 1 <= #src_lines then
		if not (same and dst.at == rm_last + 1) then
			rm_last = rm_last + 1
		end
	end
	local removed = rm_last - rm_first + 1

	local at = dst.at
	local ok, err
	if same and at > src.last then
		ok, err = workspace.insert_lines(dst_file, at, moved)
		if ok then
			workspace.delete_lines(src_file, rm_first, rm_last)
			at = at - removed
		end
	else
		if same then
			workspace.delete_lines(src_file, rm_first, rm_last)
		end
		ok, err = workspace.insert_lines(dst_file, at, moved)
		if ok and not same then
			workspace.delete_lines(src_file, rm_first, rm_last)
		end
	end
	if not ok then
		return nil, err
	end
	if moved[1] == "" then
		at = at + 1
	end
	return at
end

-- =============================================================================
-- Links that follow
-- =============================================================================

-- The components naming the place `dst` (Move.target) of `doc`: the target
-- section's path, or the line's (its section's path and the line itself).
local function place_components(doc, dst)
	local L = link_mod()
	local name = doc:name() or vim.fn.fnamemodify(doc.filepath or "", ":t:r")
	if dst.node then
		if dst.node:is_root() or dst.node.type == "article" then
			return { name }
		end
		return L.node_components(doc, dst.node)
	end
	local node = doc:node_at(dst.lnum)
	local comps = node and not node:is_root() and L.node_components(doc, node) or { name }
	local line = doc.lines[dst.lnum]
	comps[#comps + 1] = L.item_component(line) or ("%" .. L.extract_line_identifier(line))
	return comps
end

-- The first place `def` finds, from line `lnum` of `doc`: { file, lnum, doc } or nil
local function first(def, doc, lnum)
	local ok, results = pcall(link_mod().resolve, "[" .. def .. "]", { doc = doc, lnum = lnum })
	return ok and results and results[1] or nil
end

-- Whether a resolved place (a note, a section or a line) holds line `lnum` of `file`
local function holds(r, file, lnum)
	if not r or not same_file(r.file, file) then
		return false
	end
	local doc = r.doc or workspace.document(r.file)
	local header_end = (doc.header and doc.header.last_lnum) or 0
	if r.lnum <= math.max(1, header_end) then
		return true -- the note
	end
	local node = doc:node_starting_at(r.lnum)
	local last = node and node.end_line or block_end(doc, r.lnum)
	return lnum >= r.lnum and lnum <= last
end

-- The nearest less-indented line above `lnum` with a link (a "./" link's parent)
local function parent_lnum(lines, lnum)
	local want = indent_of(lines[lnum])
	for l = lnum - 1, 1, -1 do
		local text = lines[l]
		if text:match("%S") and indent_of(text) < want then
			if #link_mod().links_on(text) > 0 then
				return l
			end
			want = indent_of(text)
			if want == 0 then
				return nil
			end
		end
	end
end

--- The lines whose links have to change so that moving `src` of
--- `src_file` to `dst` in `dst_file` breaks none: { { file, lnum, line,
--- old }... } (old: the line now), in file and line order. Nothing is
--- written; the edits keep every line where it is, so they can be made
--- before Move.move.
function M.link_edits(src_file, src, dst_file, dst)
	local L = link_mod()
	local dst_doc = workspace.document(dst_file)
	local src_doc = workspace.document(src_file)
	if not dst_doc or not src_doc then
		return {}
	end
	local across = not same_file(src_file, dst_file)
	-- a line of the moved block is somewhere else afterwards
	local function inside(file, lnum)
		return same_file(file, src_file) and lnum >= src.first and lnum <= src.last
	end
	-- dst.at is where the block will start (before the move's shifts):
	-- enough to tell which section holds it
	local landing = dst.node and (dst.node:is_root() and 1 or dst.node.start_line) or dst.lnum

	local edits, order = {}, {}
	local function sub(file, lnum, col, old, new)
		local key = vim.fn.fnamemodify(file, ":p") .. ":" .. lnum
		local e = edits[key]
		if not e then
			local line = workspace.get_lines(file)[lnum]
			e = { file = file, lnum = lnum, line = line, old = line, subs = {} }
			edits[key], order[#order + 1] = e, key
		end
		for _, x in ipairs(e.subs) do
			if x.col == (col or 1) then
				return -- one rewrite per link
			end
		end
		e.subs[#e.subs + 1] = { col = col or 1, old = old, new = new }
	end

	-- 1. links into what moves
	local ok, refs = pcall(require("zortex.core.link_index").references, src_file, src.first, src.last)
	for _, ref in ipairs(ok and refs or {}) do
		local ref_doc = workspace.document(ref.file)
		local def = ref.definition
		if L.is_parent_relative(def) then
			def = L.absolute(def, ref_doc.lines, ref.lnum) or def
		end
		local comps, scope = L.split(def)
		local i
		for k = 1, #comps do
			local prefix = (scope == "local" and "/" or scope == "home" and "~/" or "") .. table.concat(comps, "/", 1, k)
			local r = first(prefix, ref_doc, ref.lnum)
			if r and inside(r.file, r.lnum) then
				i = k
				break
			end
		end
		if i then
			local still
			if i == 1 then
				-- "/#Notes": the note the link is in, after the move
				still = scope == "local" and same_file(inside(ref.file, ref.lnum) and dst_file or ref.file, dst_file)
			else
				local prefix = (scope == "local" and "/" or scope == "home" and "~/" or "") .. table.concat(comps, "/", 1, i - 1)
				still = holds(first(prefix, ref_doc, ref.lnum), dst_file, landing)
					and not (scope == "local" and across and inside(ref.file, ref.lnum))
			end
			if not still then
				local new = vim.list_extend(vim.deepcopy(place_components(dst_doc, dst)), vim.list_slice(comps, i))
				sub(ref.file, ref.lnum, ref.def_col or ref.col, ref.definition, L.build_link(new):sub(2, -2))
			end
		end
	end

	-- 2. links on the moved lines that depend on where they are
	local src_name = src_doc:name() or vim.fn.fnamemodify(src_file, ":t:r")
	for lnum = src.first, src.last do
		local line = src_doc.lines[lnum]
		if line:find("[", 1, true) and not src_doc:in_code(lnum) then
			for _, span in ipairs(L.links_on(line)) do
				local def = span.definition
				local col = (span.def_s or span.s + 1) + 1
				if L.is_parent_relative(def) then
					local p = parent_lnum(src_doc.lines, lnum)
					if p and p < src.first then
						local abs = L.absolute(def, src_doc.lines, lnum)
						if abs then
							sub(src_file, lnum, col, def, abs)
						end
					end
				elseif across and def:sub(1, 1) == "/" then
					local r = first(def, src_doc, lnum)
					if not (r and inside(r.file, r.lnum)) then
						sub(src_file, lnum, col, def, L.component_text(src_name) .. def)
					end
				end
			end
		end
	end

	-- right to left, so each column still points at its link
	local out = {}
	for _, key in ipairs(order) do
		local e = edits[key]
		table.sort(e.subs, function(x, y)
			return x.col > y.col
		end)
		for _, x in ipairs(e.subs) do
			local at = e.line:find(x.old, x.col, true)
			if at then
				e.line = e.line:sub(1, at - 1) .. x.new .. e.line:sub(at + #x.old)
			end
		end
		e.subs = nil
		if e.line ~= e.old then
			out[#out + 1] = e
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

return M
