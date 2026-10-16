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

return M
