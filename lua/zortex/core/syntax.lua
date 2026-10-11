-- core/syntax.lua - The Zortex grammar: one parser for lines and inline spans
--
-- Every module that needs to know what a line *is* asks this module: the
-- document tree, highlighting, folding, tasks, the calendar, OKR, link
-- extraction and completion. It is plain Lua (no vim.* APIs) and returns
-- plain tables, so the same parser can run outside Neovim and its output can
-- be serialized as-is (see zortex.query and tests/fixtures/ast).
--
--   local syntax = require("zortex.core.syntax")
--   local ast = syntax.parse(lines, { inline = true })
--   ast.header                 { names, tags, tag_lines, name_lnum, last_lnum }
--   ast.lines[lnum]            line descriptor (below)
--   ast.sections               structural lines in order { lnum, type, level, text, names? }
--   ast.blocks                 multi-line blocks { kind = "code"|"math"|"table", start, finish, lang? }
--
-- Line descriptor:
--   kind         blank | article | tag | heading | bold_heading | label | item
--                | text | fence | code | math_fence | math | table | quote
--                | footnote
--   indent       leading whitespace width (bytes)
--   section      true for structural lines (article in the header, heading,
--                bold_heading, label); level = structural level
--                (constants.SECTION_HIERARCHY), text = display text with
--                attributes stripped
--   heading      number of "#" (headings)
--   item         list-item details (items, and labels written as "- Label:"):
--                  marker        "-", "+", "*", "1.", "A.", or "14:00"
--                  marker_type   "bullet" | "ordered" | "time"
--                  marker_col    0-based column of the marker
--                  time          { from = "14:00", to = "16:00"? } (time items)
--                  key, key_col  "KR1" in "- KR1: [ ] text", "Label" in "- Label: text"
--                  mark, mark_col checkbox character and column ("[x]" -> "x")
--   key, key_col plain lines written as "Label: text"
--   content_col  0-based column where inline content starts
--   content_end  0-based exclusive end of inline content (bold headings)
--   lang         code fences
--   inline       inline spans (when parsed with { inline = true })
--
-- Inline span (all columns 0-based, end exclusive):
--   { type, s, e, ... }
--   link         definition                      [Projects/#1 Programming]
--   live_link    definition                      ![Article]
--   tag_search   content, terms, query_type      @[cars & parts]
--   markdown     text, url                       [text](https://...)
--   footnote_ref id                              [^1]
--   url          url                             https://...
--   filepath     path                            ./image.png, ~/notes
--   attribute    key, value?                     @size(lg), @p1, @home
--   code         inner_s, inner_e                `code`
--   math         inner_s, inner_e, display       $x^2$, $$x$$
--   bold/italic  inner_s, inner_e, children      **text**, *text*
--   time         value                           14:00
local M = {}

local constants = require("zortex.constants")

M.VERSION = 1

local HIERARCHY = constants.SECTION_HIERARCHY
local T = constants.SECTION_TYPE

-- =============================================================================
-- Small helpers
-- =============================================================================

local function trim(s)
	return (s:match("^%s*(.-)%s*$")) or ""
end
M.trim = trim

--- Strip inline attributes (`@key(value)` and bare `@word`) from text:
--- "1.4 - zortex @p1 @size(lg)" -> "1.4 - zortex". Only tokens that start a
--- word are removed, so "me@example.com" is left alone.
function M.strip_attributes(text)
	if not text then
		return ""
	end
	local s = " " .. text
	s = s:gsub("%s@[%w_]+%b()", "")
	s = s:gsub("%s@[%w_%-]+", "")
	return trim((s:gsub("%s+", " ")))
end

--- Split "a + b" (OR) or "a & b" (AND) into terms. Spaces around the operator
--- are required so "c++" or "r&d" are not split.
---@return "single"|"or"|"and", string[]
function M.split_query(content)
	local query_type, sep = "single", nil
	if content:find(" %+ ") then
		query_type, sep = "or", "+"
	elseif content:find(" & ") then
		query_type, sep = "and", "&"
	end
	if not sep then
		return query_type, { trim(content) }
	end
	local terms = {}
	for term in content:gmatch("([^" .. sep .. "]+)") do
		local t = trim(term)
		if t ~= "" then
			terms[#terms + 1] = t
		end
	end
	return query_type, terms
end

-- =============================================================================
-- Header
-- =============================================================================

--- The header block at the top of a note: article names (`@@Name`) and tags
--- (`@Tag`, `@key(value)`). Blank lines are skipped; the header ends at the
--- first other line.
---@return { names: string[], tags: string[], tag_lines: string[], name_lnum: integer?, last_lnum: integer }
function M.parse_header(lines, max_lines)
	local header = { names = {}, tags = {}, tag_lines = {}, name_lnum = nil, last_lnum = 0 }
	if not lines then
		return header
	end
	for lnum = 1, math.min(#lines, max_lines or 50) do
		local line = lines[lnum]
		local name = line:match("^@@(.+)")
		if name then
			header.names[#header.names + 1] = trim(name)
			header.name_lnum = header.name_lnum or lnum
			header.last_lnum = lnum
		elseif line:match(constants.PATTERNS.TAG_LINE) then
			header.tags[#header.tags + 1] = trim(line:sub(2))
			header.tag_lines[#header.tag_lines + 1] = line
			header.last_lnum = lnum
		elseif line:match("%S") then
			break
		end
	end
	return header
end

-- =============================================================================
-- List items
-- =============================================================================

-- "Key: rest" at the start of `text` -> key, key length incl. ": ".
-- Keys look like labels: start with a word character, no ". " inside.
local function match_key(text)
	local key, sep = text:match("^(%w[^:]-)(:%s+)")
	if key and not key:find("%.%s") and #key <= 60 then
		return key, #key + #sep
	end
	return nil
end

-- Checkbox "[x] text" at the start of `text` -> mark, consumed length.
-- A checkbox needs text after it ("- [ ]" alone is not a task yet).
local function match_checkbox(text)
	local mark, sep = text:match("^%[(.)%](%s+)%S")
	if mark then
		return mark, 3 + #sep
	end
	return nil
end

--- List-item details for a line, or nil. See the module header.
function M.item(line)
	local indent = line:match("^%s*")
	local pos = #indent + 1 -- 1-based start of the marker
	local rest = line:sub(pos)
	local item

	local bullet, sp = rest:match("^([-+*])(%s+)")
	if bullet and not (bullet == "*" and rest:sub(2, 2) == "*") then
		item = { marker = bullet, marker_type = "bullet", consumed = 1 + #sp }
	elseif rest:match("^%-%[") or rest == "-" then
		item = { marker = "-", marker_type = "bullet", consumed = 1 }
	else
		local from, to, sp2 = rest:match("^(%d%d?:%d%d)%s*%-%s*(%d%d?:%d%d)(%s+)")
		if from then
			local consumed = #rest:match("^%d%d?:%d%d%s*%-%s*%d%d?:%d%d") + #sp2
			item = {
				marker = rest:sub(1, consumed - #sp2),
				marker_type = "time",
				time = { from = from, to = to },
				consumed = consumed,
			}
		else
			local at, sp3 = rest:match("^(%d%d?:%d%d)(%s+)")
			if at then
				item = { marker = at, marker_type = "time", time = { at = at }, consumed = #at + #sp3 }
			else
				local num, sp4 = rest:match("^(%d+%.)(%s+)")
				if not num then
					num, sp4 = rest:match("^(%a%.)(%s+)")
				end
				if num then
					item = { marker = num, marker_type = "ordered", consumed = #num + #sp4 }
				end
			end
		end
	end
	if not item then
		return nil
	end

	item.marker_col = pos - 1
	local col = pos - 1 + item.consumed -- 0-based column after the marker
	item.consumed = nil

	if item.marker_type == "bullet" then
		local text = line:sub(col + 1)
		local mark, n = match_checkbox(text)
		if mark then
			item.mark, item.mark_col = mark, col
			col = col + n
		else
			local key, kn = match_key(text)
			if key then
				item.key, item.key_col = key, col
				local after = col + kn
				local mark2, n2 = match_checkbox(line:sub(after + 1))
				if mark2 then
					item.mark, item.mark_col = mark2, after
					col = after + n2
				end
			end
		end
	end
	item.content_col = col
	return item
end

-- =============================================================================
-- Single lines
-- =============================================================================

local function is_label(line)
	local text = line:match("^([^:]+):$")
	return text ~= nil and not text:find("%.%s")
end

local function count(s, ch)
	local n = 0
	for _ in s:gmatch(ch) do
		n = n + 1
	end
	return n
end

local function section_level(stype, heading, indent)
	return HIERARCHY.get_priority(stype, heading, indent)
end

-- Display text of a section line (attributes stripped)
local function section_text(line, kind)
	if kind == T.HEADING then
		return M.strip_attributes(line:match("^#+%s+(.+)") or line:gsub("^#+%s*", ""))
	elseif kind == T.BOLD_HEADING then
		return M.strip_attributes(line:match("^%*%*([^*]+)%*%*") or line)
	elseif kind == T.LABEL then
		return M.strip_attributes(line:match("^%s*(.-):$") or line)
	end
	return trim(line)
end
M.section_text = section_text

--- Classify one line on its own (no header or code-block context).
--- Lines inside the header or a fenced block are classified by M.parse.
function M.classify(line)
	local indent = #line:match("^%s*")
	if not line:find("%S") then
		return { kind = "blank", indent = indent, content_col = indent }
	end

	local hashes = line:match("^(#+)%s+%S")
	if hashes then
		local n = #hashes
		return {
			kind = T.HEADING,
			section = true,
			heading = n,
			level = section_level(T.HEADING, n),
			text = section_text(line, T.HEADING),
			indent = 0,
			content_col = #line:match("^#+%s+"),
		}
	end

	if line:match("^@@") then
		return { kind = T.ARTICLE, indent = 0, content_col = 2, text = trim(line:sub(3)) }
	end
	if line:match(constants.PATTERNS.TAG_LINE) then
		return { kind = T.TAG, indent = 0, content_col = 1 }
	end

	if line:match(constants.PATTERNS.BOLD_HEADING) then
		local close = line:find("**", 3, true)
		return {
			kind = T.BOLD_HEADING,
			section = true,
			level = section_level(T.BOLD_HEADING),
			text = section_text(line, T.BOLD_HEADING),
			indent = 0,
			content_col = 2,
			content_end = close and (close - 1) or #line,
		}
	end

	local fid = line:match("^%[%^([%w_.%-]+)%]:")
	if fid then
		return { kind = "footnote", id = fid, indent = 0, content_col = #line:match("^%[%^[%w_.%-]+%]:%s*") }
	end

	local item = M.item(line)
	if is_label(line) and not (item and item.mark) then
		return {
			kind = T.LABEL,
			section = true,
			level = section_level(T.LABEL, nil, indent),
			-- "- Label:" displays (and links) as "Label"
			text = section_text(item and line:sub(item.content_col + 1) or line, T.LABEL),
			indent = indent,
			item = item,
			content_col = item and item.content_col or indent,
		}
	end

	if line:match("^%s*|") then
		if count(line, "|") > 1 then
			local separator = line:match("^%s*|[|%-:%s]*|%s*$") ~= nil and line:find("-", 1, true) ~= nil
			return { kind = "table", separator = separator, indent = indent, content_col = indent }
		end
		return { kind = "quote", indent = indent, content_col = indent + 1 }
	end
	if line:match("^%s*>%s") then
		return { kind = "quote", indent = indent, content_col = #line:match("^%s*>%s*") }
	end

	if item then
		return { kind = "item", indent = indent, item = item, content_col = item.content_col }
	end

	local desc = { kind = "text", indent = indent, content_col = indent }
	local key, kn = match_key(line:sub(indent + 1))
	if key and not line:find("%.%s.-:") then
		desc.key, desc.key_col = key, indent
		desc.key_len = kn
	end
	return desc
end

-- =============================================================================
-- Documents
-- =============================================================================

local function fence_of(line)
	local indent, fence, info = line:match("^([ \t]*)(```+)(.*)$")
	if not fence then
		indent, fence, info = line:match("^([ \t]*)(~~~+)(.*)$")
	end
	if fence then
		return indent, fence, info
	end
end

--- Parse a whole note. opts.inline = true also fills `inline` on every line
--- (highlighting and export need it; the document tree does not).
function M.parse(lines, opts)
	opts = opts or {}
	local header = M.parse_header(lines)
	local out = { version = M.VERSION, header = header, lines = {}, sections = {}, blocks = {} }

	if header.name_lnum then
		out.sections[1] = {
			lnum = header.name_lnum,
			type = T.ARTICLE,
			level = 0,
			text = header.names[1],
			names = header.names,
		}
	end

	local code, math_block, table_block -- open blocks
	for lnum, line in ipairs(lines) do
		local d

		if code then
			local _, fence, info = fence_of(line)
			if fence and fence:sub(1, 1) == code.char and #fence >= code.len and not info:find("%S") then
				d = { kind = "fence", indent = #line:match("^%s*"), close = true }
				code.block.finish = lnum
				code = nil
			else
				d = { kind = "code", indent = #line:match("^%s*") }
			end
		elseif math_block then
			if line:match("^%s*%$%$%s*$") then
				d = { kind = "math_fence", indent = #line:match("^%s*"), close = true }
				math_block.finish = lnum
				math_block = nil
			else
				d = { kind = "math", indent = #line:match("^%s*") }
			end
		elseif lnum <= header.last_lnum then
			if line:match("^@@") then
				d = { kind = T.ARTICLE, indent = 0, content_col = 2, text = trim(line:sub(3)) }
				if lnum == header.name_lnum then
					d.section, d.level, d.names = true, 0, header.names
				end
			elseif line:find("%S") then
				d = { kind = T.TAG, indent = 0, content_col = 1 }
			else
				d = { kind = "blank", indent = 0, content_col = 0 }
			end
		else
			local indent, fence, info = fence_of(line)
			if fence then
				local block = { kind = "code", start = lnum, finish = #lines, lang = trim(info):match("^(%S*)") }
				out.blocks[#out.blocks + 1] = block
				code = { char = fence:sub(1, 1), len = #fence, block = block }
				d = { kind = "fence", indent = #indent, lang = block.lang }
			elseif line:match("^%s*%$%$%s*$") then
				math_block = { kind = "math", start = lnum, finish = #lines }
				out.blocks[#out.blocks + 1] = math_block
				d = { kind = "math_fence", indent = #line:match("^%s*") }
			else
				d = M.classify(line)
				if d.kind == T.ARTICLE then
					-- "@@Name" outside the header is not an article
					d.text = nil
				elseif d.section then
					out.sections[#out.sections + 1] = { lnum = lnum, type = d.kind, level = d.level, text = d.text }
				end
			end
		end

		-- Consecutive table rows form one block
		if d.kind == "table" then
			if not table_block then
				table_block = { kind = "table", start = lnum, finish = lnum }
				out.blocks[#out.blocks + 1] = table_block
			end
			table_block.finish = lnum
		else
			table_block = nil
		end

		if opts.inline and d.content_col then
			d.inline = M.inline(line, d.content_col, d.content_end)
		end
		out.lines[lnum] = d
	end

	return out
end

-- =============================================================================
-- Inline spans
-- =============================================================================

local function word_start(line, i)
	if i == 1 then
		return true
	end
	return line:sub(i - 1, i - 1):match("[%s%(%[{\"']") ~= nil
end

local function boundary_after(line, j)
	return j > #line or not line:sub(j, j):match("[%w]")
end

-- Each scanner tries to read a span starting at byte i (1-based) and returns
-- the span (0-based columns) or nil.
local scanners = {}

scanners["`"] = function(line, i)
	local ticks = line:match("^`+", i)
	local close = line:find(ticks, i + #ticks, true)
	if close and close > i + #ticks then
		return {
			type = "code",
			s = i - 1,
			e = close + #ticks - 1,
			inner_s = i - 1 + #ticks,
			inner_e = close - 1,
		}
	end
end

scanners["$"] = function(line, i)
	if line:sub(i + 1, i + 1) == "$" then
		local close = line:find("$$", i + 2, true)
		if close and close > i + 2 then
			return { type = "math", display = true, s = i - 1, e = close + 1, inner_s = i + 1, inner_e = close - 1 }
		end
		return nil
	end
	if i > 1 and line:sub(i - 1, i - 1):match("%w") then
		return nil
	end
	local first = line:sub(i + 1, i + 1)
	if first == "" or first:match("[%s%$]") then
		return nil
	end
	local close = line:find("$", i + 1, true)
	while close do
		if not line:sub(close - 1, close - 1):match("%s") and boundary_after(line, close + 1) then
			return { type = "math", display = false, s = i - 1, e = close, inner_s = i, inner_e = close - 1 }
		end
		close = line:find("$", close + 1, true)
	end
end

scanners["!"] = function(line, i)
	if line:sub(i + 1, i + 1) ~= "[" then
		return nil
	end
	local content = line:match("^!%[([^%]]+)%]", i)
	if content then
		return { type = "live_link", s = i - 1, e = i + #content + 2, definition = content }
	end
end

scanners["@"] = function(line, i)
	if line:sub(i + 1, i + 1) == "[" then
		local content = line:match("^@%[([^%]]+)%]", i)
		if content then
			local query_type, terms = M.split_query(content)
			return {
				type = "tag_search",
				s = i - 1,
				e = i + #content + 2,
				content = content,
				terms = terms,
				query_type = query_type,
			}
		end
		return nil
	end
	if not word_start(line, i) then
		return nil
	end
	local key = line:match("^@([%w_][%w_%-]*)", i)
	if not key then
		return nil
	end
	local j = i + 1 + #key
	local value = line:match("^%(([^)]*)%)", j)
	if value then
		return { type = "attribute", s = i - 1, e = j + #value + 1, key = key, value = value }
	end
	return { type = "attribute", s = i - 1, e = j - 1, key = key }
end

scanners["["] = function(line, i)
	local fid = line:match("^%[%^([%w_.%-]+)%]", i)
	if fid then
		return { type = "footnote_ref", s = i - 1, e = i + #fid + 2, id = fid }
	end
	local text, url = line:match("^%[([^%]]*)%]%(([^%)]+)%)", i)
	if text then
		return { type = "markdown", s = i - 1, e = i + #text + #url + 3, text = text, url = url }
	end
	local content = line:match("^%[([^%]]+)%]", i)
	if content and content:sub(1, 1) ~= "^" and not content:match("^[ xX%-%.]$") then
		return { type = "link", s = i - 1, e = i + #content + 1, definition = content }
	end
end

scanners["h"] = function(line, i)
	local url = line:match("^https?://[^%s%]%)};]+", i)
	if url then
		return { type = "url", s = i - 1, e = i - 1 + #url, url = url }
	end
end

local function emphasis(line, i, marker, kind)
	local n = #marker
	local inner_start = i + n
	local first = line:sub(inner_start, inner_start)
	if first == "" or first:match("[%s%*]") then
		return nil
	end
	local close = line:find(marker, inner_start, true)
	while close do
		local before = line:sub(close - 1, close - 1)
		local after = line:sub(close + n, close + n)
		if close > inner_start and not before:match("%s") and after ~= "*" then
			return {
				type = kind,
				s = i - 1,
				e = close + n - 1,
				inner_s = inner_start - 1,
				inner_e = close - 1,
			}
		end
		close = line:find(marker, close + 1, true)
	end
end

scanners["*"] = function(line, i)
	if line:sub(i + 1, i + 1) == "*" then
		return emphasis(line, i, "**", "bold")
	end
	if i > 1 and line:sub(i - 1, i - 1):match("%w") then
		return nil
	end
	return emphasis(line, i, "*", "italic")
end

local function filepath(line, i)
	if not word_start(line, i) then
		return nil
	end
	local path = line:match("^~/[^%s%]%)]+", i)
		or line:match("^%.%.?/[^%s%]%)]+", i)
		or line:match("^/[%w_~%.%-][^%s%]%)]*", i)
	if path then
		return { type = "filepath", s = i - 1, e = i - 1 + #path, path = path }
	end
end
scanners["~"] = filepath
scanners["."] = filepath
scanners["/"] = filepath

local function time_span(line, i)
	if i > 1 and line:sub(i - 1, i - 1):match("[%w:]") then
		return nil
	end
	local t = line:match("^%d%d?:%d%d", i)
	if t and boundary_after(line, i + #t) and line:sub(i + #t, i + #t) ~= ":" then
		return { type = "time", s = i - 1, e = i - 1 + #t, value = t }
	end
end
for d = 0, 9 do
	scanners[tostring(d)] = time_span
end

--- Inline spans of `line` from 0-based column `from` (default 0) up to
--- 0-based exclusive column `to` (default end of line). Spans never overlap;
--- bold and italic spans carry their own `children`.
function M.inline(line, from, to)
	local spans = {}
	local i = (from or 0) + 1
	local limit = to or #line
	local scan_line = limit < #line and line:sub(1, limit) or line
	while i <= limit do
		local ch = scan_line:sub(i, i)
		local scanner = scanners[ch]
		local span = scanner and scanner(scan_line, i)
		if span then
			if span.type == "bold" or span.type == "italic" then
				span.children = M.inline(scan_line, span.inner_s, span.inner_e)
			end
			spans[#spans + 1] = span
			i = span.e + 1
		else
			i = i + 1
		end
	end
	return spans
end

-- =============================================================================
-- Links
-- =============================================================================

local LINK_TYPES = {
	link = true,
	live_link = true,
	tag_search = true,
	markdown = true,
	footnote_ref = true,
	url = true,
	filepath = true,
	attribute = true,
}

local function walk_spans(spans, fn)
	for _, span in ipairs(spans) do
		fn(span)
		if span.children then
			walk_spans(span.children, fn)
		end
	end
end
M.walk_spans = walk_spans

--- The link-like span covering 0-based column `col`, or nil.
function M.span_at(line, col, spans)
	local found
	walk_spans(spans or M.inline(line), function(span)
		if LINK_TYPES[span.type] and col >= span.s and col < span.e then
			found = span
		end
	end)
	return found
end

--- Every link span (link, live_link) in a line, in order.
function M.links(line, spans)
	local out = {}
	walk_spans(spans or M.inline(line), function(span)
		if span.type == "link" or span.type == "live_link" then
			out[#out + 1] = span
		end
	end)
	return out
end

return M
