-- core/link.lua - Zortex links: grammar, resolution and building
--
-- A link is a "/"-separated list of components, resolved left to right. Each
-- component narrows the set of candidate (file, line range) pairs:
--
--   Article   [Projects/...]   files whose header declares the alias (any @@ name),
--                              then files tagged with it: [P/...] reaches the
--                              Projects article first, then every @P note, so
--                              [P/Flipping/#Subaru] works for standalone projects
--   Tag       [@P/...]         files whose header carries the tag; when no file
--                              declares it, a line search for "@P" instead
--   Heading   [.../#1.4 - z]   case-insensitive prefix match on heading lines at
--                              ANY depth inside the current range; the first
--                              match per file becomes the new range (its section)
--   Label, list item, highlight, %query: line searches likewise
--   Follow    [R/#Rust/>Book]  the links on the lines in range whose text (or
--                              whose line's text) starts with "Book"; must be
--                              the last component. Following it opens what
--                              those links point to (features/links)
--
-- Tag searches, @[scope/tags], resolve here too (tag_search below): the
-- components before the last "/" are a link giving where to look (none: the
-- current note; "*": every note), the last one the tags: words are all of
-- them, commas separate alternatives ("rust async, rl": both rust and async,
-- or rl; "@" optional). A line matches when it, or a
-- section heading above it, carries the tags as bare @words.
--
-- Results come back in note order (top-level files first, then line order), so
-- results[1] is the canonical target. Every consumer (following links,
-- completion, projects, OKR, calendar, the link index) uses this module, so a
-- link means the same thing everywhere. Archived notes are skipped unless a
-- component is @Archive or opts.include_archived is set.
--
-- Links written as relative paths ([./z/scan.pdf]) name files, not notes
-- (relative_path below); resolving them is up to the caller. A "./" followed
-- by a typed component ([./-Improve website], [./#Notes]) is relative to the
-- parent line's link instead (absolute below): written under
-- "09:00 [P/#1.4 - zortex]" it means [P/#1.4 - zortex/-Improve website].
--
-- The Go port is app/links; tests/gen_links.lua keeps the two in agreement.
-- Following a link in a buffer (quickfix, footnotes, @[tag] searches) is
-- features/links.
local M = {}

local syntax = require("zortex.core.syntax")
local constants = require("zortex.constants")

local function Document()
	return require("zortex.core.document")
end

local function notes()
	return require("zortex.core.notes")
end

local function escape_pattern(text)
	return text and (text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")) or ""
end
M.escape_pattern = escape_pattern

-- =============================================================================
-- Grammar
-- =============================================================================

--- One component ("#1.4 - zortex", "@P", "%sparkplug", ...) as
--- { type, text, original, attributes }.
function M.parse_component(component)
	if not component or component == "" then
		return nil
	end

	local first_char = component:sub(1, 1)

	local attributes = {}

	-- Check if component has attributes (contains @key(...))
	local attr_pattern = "@(%w+)%s*%(([^)]*)%)"
	for key, value in component:gmatch(attr_pattern) do
		attributes[key] = value
	end

	if first_char == "@" then
		return { type = "tag", text = component:sub(2), original = component, attributes = attributes }
	elseif first_char == "#" then
		local text = component:sub(2)
		if text:sub(1, 1) == " " then
			text = text:sub(2)
		end
		-- Remove attributes from the heading text
		text = text:gsub(attr_pattern, ""):gsub("%s+", " "):gsub("%s*$", "")
		return { type = "heading", text = text, original = component, attributes = attributes }
	elseif first_char == ":" then
		local text = component:sub(2)
		-- Remove attributes from the label text
		text = text:gsub(attr_pattern, ""):gsub("%s+", " "):gsub("%s*$", "")
		return { type = "label", text = text, original = component, attributes = attributes }
	elseif first_char == "-" then
		return { type = "listitem", text = component:sub(2), original = component, attributes = attributes }
	elseif first_char == "*" then
		return { type = "highlight", text = component:sub(2), original = component, attributes = attributes }
	elseif first_char == "%" then
		return { type = "query", text = component:sub(2), original = component, attributes = attributes }
	elseif first_char == ">" then
		return { type = "follow", text = syntax.trim(component:sub(2)), original = component, attributes = attributes }
	else
		-- Article - remove attributes from the text
		local text = component:gsub(attr_pattern, ""):gsub("%s+", " "):gsub("%s*$", "")
		return { type = "article", text = text, original = component, attributes = attributes }
	end
end

--- Split a link definition into raw component strings, ignoring "/" inside
--- parentheses (attribute values). Strips outer brackets.
---@return string[] components, "global"|"local"|"home" scope
function M.split(definition)
	definition = syntax.trim(definition or "")
	if definition:sub(1, 1) == "[" and definition:sub(-1) == "]" then
		definition = definition:sub(2, -2)
	end
	local scope = "global"
	if definition:sub(1, 1) == "/" then
		scope = "local"
		definition = definition:sub(2)
	elseif definition:sub(1, 2) == "~/" then
		-- the notes folder, from a note outside it (a repository's docs)
		scope = "home"
		definition = definition:sub(3)
	end

	local components, current, depth = {}, "", 0
	for i = 1, #definition do
		local char = definition:sub(i, i)
		if char == "(" then
			depth = depth + 1
			current = current .. char
		elseif char == ")" then
			depth = depth - 1
			current = current .. char
		elseif char == "/" and depth == 0 then
			if current ~= "" then
				table.insert(components, syntax.trim(current))
			end
			current = ""
		else
			current = current .. char
		end
	end
	if current ~= "" then
		table.insert(components, syntax.trim(current))
	end
	return components, scope
end

local KINDS = { ["@"] = "note", ["#"] = "heading", [":"] = "label", ["*"] = "bold", ["-"] = "item", ["%"] = false, [">"] = false }

--- What a link names, by its last component: "note" (an article or a tag),
--- "heading", "label", "bold", "item", or nil (a query, a follow). The link
--- is coloured by it (ZortexLink<Kind>) and needs no resolving.
---@param definition string "P/#1.4", "[A/:Fitness]"
---@return string?
function M.kind(definition)
	local components = M.split(definition)
	local last = components[#components]
	if not last or last == "" then
		return nil
	end
	local kind = KINDS[last:sub(1, 1)]
	if kind == nil then
		return "note"
	end
	return kind or nil
end

--- A link definition ("[P/#1.4]", "/:Notes") as { scope = "global"|"local", components }.
function M.parse(definition)
	if not definition or definition == "" then
		return nil
	end

	local components, scope = M.split(definition)
	local result = { scope = scope, components = {} }
	definition = table.concat(components, "/")

	-- Parse each component
	for _, component in ipairs(components) do
		if component ~= "" then
			local comp_info = M.parse_component(component)
			if comp_info then
				table.insert(result.components, comp_info)
			end
		end
	end

	-- If no components but we have a definition, it's an article link
	if #result.components == 0 and definition ~= "" then
		table.insert(result.components, {
			type = "article",
			text = definition,
			original = definition,
		})
	end

	return result
end

-- =============================================================================
-- Links on a line
-- =============================================================================

-- Link info for a syntax span (features/links, link_index, OKR)
local function link_info(line, span)
	local full = line:sub(span.s + 1, span.e)
	local info = { full_match_text = full, col = span.s + 1 }
	local t = span.type
	if t == "footnote_ref" then
		info.type, info.ref_id, info.display_text = "footnote", span.id, full
	elseif t == "markdown" then
		info.type, info.display_text, info.url = "markdown", span.text, span.url
	elseif t == "live_link" or t == "link" then
		info.type, info.display_text, info.definition = t, span.definition, span.definition
	elseif t == "tag_search" then
		info.type, info.display_text = "tag_search", span.content
	elseif t == "url" then
		info.type, info.url, info.display_text = "website", span.url, span.url
	elseif t == "filepath" then
		info.type, info.path, info.display_text = "filepath", span.path, span.path
	elseif t == "attribute" and (span.key == "a" or span.key == "area") and span.value then
		-- @a(4.1) / @area(...) link to the area
		local area = require("zortex.utils.attributes").attribute_parsers.area(span.value)[1]
		if not area then
			return nil
		end
		info.type, info.display_text, info.definition = "link", area.definition, area.definition
	else
		return nil
	end
	return info
end

--- The link (any kind) under 0-based byte column `col`, or nil:
--- { type, display_text, definition?, url?, ref_id?, path?, full_match_text, col }
function M.at(line, col)
	local span = syntax.span_at(line, col)
	return span and link_info(line, span) or nil
end

--- `line` from byte `from` (0-based) on, with markdown links replaced by
--- their text: "[The Rust Book](https://…) @rust" -> "The Rust Book @rust".
--- List items match a "-" component by this text.
function M.link_text(line, from)
	from = from or 0
	if not line:find("](", from + 1, true) then
		return line:sub(from + 1)
	end
	local spans = {}
	syntax.walk_spans(syntax.inline(line), function(span)
		if span.type == "markdown" and span.s >= from then
			spans[#spans + 1] = span
		end
	end)
	table.sort(spans, function(a, b)
		return a.s < b.s
	end)
	local out, pos = {}, from
	for _, span in ipairs(spans) do
		if span.s >= pos then
			out[#out + 1] = line:sub(pos + 1, span.s)
			out[#out + 1] = span.text
			pos = span.e
		end
	end
	out[#out + 1] = line:sub(pos + 1)
	return table.concat(out)
end

-- Spans a > component can follow
local FOLLOWABLE = { link = true, live_link = true, markdown = true, url = true, filepath = true }

--- The links on a line that a > component can follow, in order:
--- { info (as at()), text (what > matches: markdown text, link definition,
--- URL or path) }
function M.follow_targets(line)
	local out = {}
	syntax.walk_spans(syntax.inline(line), function(span)
		if FOLLOWABLE[span.type] then
			local info = link_info(line, span)
			if info then
				local text = span.text or span.definition or span.url or span.path or ""
				out[#out + 1] = { info = info, text = text, col = span.s + 1 }
			end
		end
	end)
	return out
end

-- A line's text for > matching: a list item's text, or the trimmed line,
-- without attributes
local function line_text(line)
	local it = syntax.item(line)
	local body = it and line:sub(it.content_col + 1) or line
	return syntax.trim(syntax.strip_attributes(body))
end

-- =============================================================================
-- Line matching
-- =============================================================================

-- Lua pattern(s) a line-search component matches (nil for articles)
local function search_pattern(component)
	local text = escape_pattern(component.text)

	if component.type == "tag" then
		return "^@" .. text .. "$"
	elseif component.type == "heading" then
		return "^#+%s*" .. text .. ".*$"
	elseif component.type == "label" then
		-- "Label:", or a longer label written "*A longer label:*"
		return "^%*?" .. text .. ".*:"
	elseif component.type == "listitem" then
		return "^%s*- " .. text .. "$"
	elseif component.type == "highlight" then
		-- *text*, **text**, ***text***, or a bold heading **text:**
		return "%*%*?%*?" .. text .. ":?%*%*?%*?"
	elseif component.type == "query" then
		-- Plain substring search
		return text
	elseif component.type == "article" then
		-- This is handled differently - by finding article files
		return nil
	end
end

-- Lowercased lines, per lines table (document snapshots never change, so a
-- note searched by many links is lowercased once)
local lowered = setmetatable({}, { __mode = "k" })

local function lower_line(lines, lnum)
	local cache = lowered[lines]
	if not cache then
		cache = {}
		lowered[lines] = cache
	end
	local line = cache[lnum]
	if not line then
		line = lines[lnum]:lower()
		cache[lnum] = line
	end
	return line
end

-- Line numbers of the lines starting with `char`, per lines table: heading
-- and tag components only ever match those
local ANCHOR = { heading = "#", tag = "@" }
local anchored = setmetatable({}, { __mode = "k" })

local function lines_starting_with(lines, char)
	local by_char = anchored[lines]
	if not by_char then
		by_char = {}
		anchored[lines] = by_char
	end
	local list = by_char[char]
	if not list then
		list = {}
		local byte = char:byte()
		for lnum, line in ipairs(lines) do
			if line:byte(1) == byte then
				list[#list + 1] = lnum
			end
		end
		by_char[char] = list
	end
	return list
end

--- Find lines in [start_line, end_line] matching a component. Matching is
--- case-insensitive, except for % queries that contain an uppercase letter.
---@return { lnum: integer, col: integer }[]
function M.search_lines(lines, component, start_line, end_line)
	if component.type == "follow" then
		-- Every link whose own text, or whose line's text, starts with the
		-- component text (case-insensitive); "" matches every link
		local out = {}
		local want = component.text:lower()
		local function starts(s)
			return s:lower():sub(1, #want) == want
		end
		for lnum = start_line or 1, math.min(end_line or #lines, #lines) do
			local line = lines[lnum]
			local targets = line:find("[%[/:]") and M.follow_targets(line) or {}
			if targets[1] then
				local whole = starts(line_text(line))
				for _, t in ipairs(targets) do
					if whole or starts(t.text) then
						out[#out + 1] = { lnum = lnum, col = t.col, target = t.info }
					end
				end
			end
		end
		return out
	end
	local pattern = search_pattern(component)
	if not pattern then
		return {}
	end

	local case_sensitive = component.type == "query" and component.text:match("[A-Z]") ~= nil
	if not case_sensitive then
		pattern = pattern:lower()
	end

	local out = {}
	if component.type == "listitem" then
		-- A list item whose key ("- KR1: …") or text ("- [ ] Call the bank")
		-- starts with the component text (case-insensitive); a markdown
		-- link counts as its text ("- [The Rust Book](…)")
		local want = vim.trim(component.text):lower()
		-- "-aB3x9": a task's @id too (exactly), so a link survives renames
		local id = vim.trim(component.text)
		local id_attr = id:match("^[%w_%-]+$") and ("@id(" .. id .. ")") or nil
		for lnum = start_line or 1, math.min(end_line or #lines, #lines) do
			local line = lines[lnum]
			local it = line:find("%S") and syntax.item(line)
			if it then
				local key = it.key and it.key:lower()
				local body = syntax.strip_attributes(M.link_text(line, it.content_col)):lower()
				if
					key == want
					or body:sub(1, #want) == want
					or (key and key:sub(1, #want) == want)
					or (id_attr and line:find(id_attr, 1, true))
				then
					out[#out + 1] = { lnum = lnum, col = (it.marker_col or 0) + 1 }
				end
			end
		end
		return out
	end
	local first, last = start_line or 1, math.min(end_line or #lines, #lines)
	local function try(lnum)
		local line = case_sensitive and lines[lnum] or lower_line(lines, lnum)
		local col = line:find(pattern)
		if col then
			out[#out + 1] = { lnum = lnum, col = col }
		end
	end
	local anchor = ANCHOR[component.type]
	if anchor then
		for _, lnum in ipairs(lines_starting_with(lines, anchor)) do
			if lnum > last then
				break
			elseif lnum >= first then
				try(lnum)
			end
		end
	else
		for lnum = first, last do
			try(lnum)
		end
	end
	return out
end

-- =============================================================================
-- Section Boundaries
-- =============================================================================

local SINGLE_LINE = { listitem = true, query = true, tag = true, follow = true }

-- Range a match narrows to: the section that starts at the matched line (a
-- single line for list items, queries, tags and plain highlights).
function M.section_end(doc, lnum, component)
	if SINGLE_LINE[component.type] then
		return lnum
	end
	local node = doc:node_starting_at(lnum)
	if component.type == "highlight" and not (node and node.type == "bold_heading") then
		return lnum
	end
	if node then
		return node.end_line
	end
	return component.type == "article" and #doc.lines or lnum
end

-- =============================================================================
-- Resolution
-- =============================================================================

---@class SearchResult
---@field file string full path
---@field lnum integer 1-based line
---@field col integer 1-based column
---@field text string line text ("Article: Name" for article targets)
---@field component table the component that matched
---@field lines string[] lines of the file
---@field doc Document snapshot the result came from
---@field target table? for a > component, the link to follow (as at())
---@field whole boolean? the result is a whole note (article and tag components)
---@field end_line integer? last line of the range the result covers (line searches)

local function make_result(doc, lnum, col, component, text)
	return {
		file = doc.filepath,
		lnum = lnum,
		col = col or 1,
		text = text or doc.lines[lnum] or "",
		component = component,
		lines = doc.lines,
		doc = doc,
	}
end

-- Lowercased alias/tag -> { [path] = true } for a notes snapshot, so an
-- article component doesn't compare its name against every header
local function header_sets(idx)
	if not idx.header_sets then
		local names, tags = {}, {}
		local function add(set, key, path)
			key = key:lower()
			set[key] = set[key] or {}
			set[key][path] = true
		end
		for path, h in pairs(idx.headers) do
			for _, n in ipairs(h.names or {}) do
				add(names, n, path)
			end
			for _, t in ipairs(h.tags or {}) do
				add(tags, t, path)
			end
		end
		idx.header_sets = { names = names, tags = tags }
	end
	return idx.header_sets
end

local function mentions_archive(parsed)
	for _, c in ipairs(parsed.components) do
		if c.type == "tag" and c.text:lower() == constants.ARCHIVE_TAG:lower() then
			return true
		end
	end
	return false
end

--- Resolve a link to every matching location. A parent-relative link
--- ([./-Item]) needs the note (doc or bufnr) and the line it is written on
--- (lnum).
---@param link string|table  "[P/#1.4 - zortex]", "P/#1.4", or parse() output
---@param opts { bufnr?: integer, doc?: table, lnum?: integer, include_archived?: boolean }?
---@return SearchResult[] results, string? err
function M.resolve(link, opts)
	opts = opts or {}
	if type(link) == "string" then
		local content = syntax.trim(link):match("^@%[(.*)%]$")
		if content then
			return M.tag_search(content, opts)
		end
		local def = syntax.trim(link):match("^%[(.*)%]$") or syntax.trim(link)
		if M.is_parent_relative(def) then
			local doc = opts.doc or (opts.bufnr and Document().from_buffer(opts.bufnr))
			local abs, err = M.absolute(def, doc and doc.lines, opts.lnum or 0)
			if not abs then
				return {}, err
			end
			link = "[" .. abs .. "]"
		end
	end
	local parsed = type(link) == "table" and link or M.parse(link)
	if not parsed or not parsed.components or #parsed.components == 0 then
		return {}, "Invalid link"
	end

	local is_local = parsed.scope == "local"
	local idx
	local cands -- { path, doc?, start_line?, end_line? }
	-- Where global links look: the notes folder, or for a note outside it
	-- the folder it lives in (notes.root_of); "~/" is the notes folder
	local root = opts.root
	if parsed.scope == "home" then
		root = nil
	elseif root == nil then
		local from = opts.doc and opts.doc.filepath
		if not from and opts.bufnr then
			from = vim.api.nvim_buf_get_name(opts.bufnr == 0 and vim.api.nvim_get_current_buf() or opts.bufnr)
		end
		root = from and from ~= "" and notes().root_of(from) or nil
	end

	if is_local then
		local doc = opts.doc or Document().from_buffer(opts.bufnr or 0)
		if not doc then
			return {}, "No buffer to resolve a local link in"
		end
		cands = { { path = doc.filepath, doc = doc } }
	else
		local include_archived = opts.include_archived
		if include_archived == nil then
			include_archived = mentions_archive(parsed)
		end
		idx = notes().index({ include_archived = include_archived, root = root })
		cands = {}
		-- An article first ([P/...], the usual case): only the notes with that
		-- name or tag can match, so skip the rest now (the article step below
		-- keeps exactly these)
		local first = parsed.components[1]
		local sets = first.type == "article" and header_sets(idx)
		local named = sets and sets.names[first.text:lower()]
		local tagged = sets and sets.tags[first.text:lower()]
		for _, path in ipairs(idx.files) do
			if not sets or not idx.headers[path] or (named and named[path]) or (tagged and tagged[path]) then
				cands[#cands + 1] = { path = path }
			end
		end
	end

	local function load(c)
		c.doc = c.doc or Document().get(c.path)
		return c.doc
	end
	local function header(c)
		return (idx and idx.headers[c.path]) or (load(c) and c.doc.header)
	end

	local results = {}
	for i, comp in ipairs(parsed.components) do
		local last = i == #parsed.components
		if comp.type == "follow" and not last then
			return {}, "Nothing can come after " .. comp.original
		end

		-- Article and header-tag components select whole files. An article
		-- name ranks files that declare it as an alias before files that are
		-- only tagged with it.
		local select_file, rank
		if not is_local and comp.type == "article" then
			local sets = idx and header_sets(idx)
			local key = comp.text:lower()
			select_file = function(h, path)
				if sets and idx.headers[path] == h then
					return (sets.names[key] and sets.names[key][path]) or (sets.tags[key] and sets.tags[key][path]) or false
				end
				return syntax.list_has(h.names, comp.text) or syntax.list_has(h.tags, comp.text)
			end
			rank = function(h)
				return syntax.list_has(h.names, comp.text) and 1 or 2
			end
		elseif not is_local and comp.type == "tag" then
			local function has_tag(h)
				return syntax.list_has(h.tags, comp.text)
			end
			for _, c in ipairs(cands) do
				local h = header(c)
				if h and has_tag(h) then
					select_file = has_tag
					break
				end
			end
		end

		if select_file then
			local kept = {}
			for _, c in ipairs(cands) do
				local h = header(c)
				if h and select_file(h, c.path) then
					kept[#kept + 1] = { path = c.path, doc = c.doc }
				end
			end
			if #kept == 0 then
				return {}, (comp.type == "article" and "No article found: " or "No notes tagged @") .. comp.text
			end
			if rank then
				-- Stable partition: alias matches first, tag matches after
				local first, second = {}, {}
				for _, c in ipairs(kept) do
					table.insert(rank(header(c)) == 1 and first or second, c)
				end
				kept = vim.list_extend(first, second)
			end
			cands = kept
			if last then
				for _, c in ipairs(cands) do
					local doc = load(c)
					if doc then
						local lnum = doc.header.name_lnum or 1
						local text = comp.type == "article" and ("Article: " .. comp.text) or nil
						local r = make_result(doc, lnum, 1, comp, text)
						r.whole = true
						results[#results + 1] = r
					end
				end
			end
		else
			local next_cands = {}
			for _, c in ipairs(cands) do
				local doc = load(c)
				if doc then
					local matches = M.search_lines(doc.lines, comp, c.start_line, c.end_line)
					if last then
						for _, m in ipairs(matches) do
							local r = make_result(doc, m.lnum, m.col, comp)
							r.target = m.target -- > components: the link to follow
							r.end_line = M.section_end(doc, m.lnum, comp)
							results[#results + 1] = r
						end
					elseif matches[1] then
						local lnum = matches[1].lnum
						next_cands[#next_cands + 1] = {
							path = c.path,
							doc = doc,
							start_line = lnum,
							end_line = M.section_end(doc, lnum, comp),
						}
					end
				end
			end
			if not last then
				if #next_cands == 0 then
					return {}, "No matches found for: " .. comp.original
				end
				cands = next_cands
			end
		end
	end

	if #results == 0 then
		return {}, "No matches found for: " .. parsed.components[#parsed.components].original
	end
	return results
end

-- =============================================================================
-- Tag searches: @[scope/tags]
-- =============================================================================

--- "R/#Rust/rl, ai" -> { scope = { "R", "#Rust" } | nil, is_local, all,
--- groups = { { "rl" }, { "ai" } } } (any group, all of its tags)
function M.parse_tag_search(content)
	local parts, scope = M.split(content)
	local query = table.remove(parts) or ""
	local groups = {}
	-- "a b, c": (a and b) or c
	for group in (query .. ","):gmatch("([^,]*),") do
		local terms = {}
		for term in group:gmatch("%S+") do
			term = (term:gsub("^@", "")):lower()
			if term ~= "" then
				terms[#terms + 1] = term
			end
		end
		if #terms > 0 then
			groups[#groups + 1] = terms
		end
	end
	local all = #parts == 1 and parts[1] == "*"
	return {
		scope = (#parts > 0 and not all) and parts or nil,
		is_local = scope == "local",
		home = scope == "home",
		all = all,
		groups = groups,
	}
end

-- Bare @words on a line ({ [tag] = 1-based col }), from its inline spans
local function line_tags(doc, lnum)
	local out = {}
	syntax.walk_spans(doc:inline(lnum), function(span)
		if span.type == "attribute" and span.value == nil then
			local key = span.key:lower()
			out[key] = out[key] or span.s + 1
		end
	end)
	return out
end

local NOT_CONTENT = { blank = true, article = true, tag = true }

local RESOURCE_SPANS = { link = true, live_link = true, markdown = true, url = true, filepath = true }

--- Is the heading at lnum a resource: nothing but one link (and
--- attributes), as in "### [The Rust Book](https://...) @rust"? Its section
--- is notes about it: they don't take its tags, or those above it.
function M.is_resource_heading(doc, lnum)
	local d = doc:info(lnum)
	if not d or d.kind ~= "heading" or not d.content_col then
		return false
	end
	local line = doc.lines[lnum]
	local pos, links = d.content_col, 0
	for _, span in ipairs(doc:inline(lnum)) do
		if line:sub(pos + 1, span.s):match("%S") then
			return false
		end
		if RESOURCE_SPANS[span.type] then
			links = links + 1
		elseif span.type ~= "attribute" then
			return false
		end
		pos = span.e
	end
	return links == 1 and not line:sub(pos + 1, d.content_end or #line):match("%S")
end

local function indent_width(line)
	return #(line:match("^%s*") or "")
end

local function holds_link(doc, lnum)
	local found = false
	syntax.walk_spans(doc:inline(lnum), function(span)
		found = found or RESOURCE_SPANS[span.type] == true
	end)
	return found
end

--- Is lnum a note about a resource: nested (by indent, labels too) under a
--- list item that holds a link? Notes match tag searches by their own tags
--- only, like the lines of a resource heading's section.
function M.is_resource_note(doc, lnum)
	local ind = indent_width(doc.lines[lnum] or "")
	for l = lnum - 1, 1, -1 do
		if ind == 0 then
			return false
		end
		local line = doc.lines[l]
		if line:match("%S") and not doc:in_code(l) then
			local li = indent_width(line)
			if li < ind then
				local d = doc:info(l)
				if d and d.item and d.kind == "item" and holds_link(doc, l) then
					return true
				end
				ind = li
			end
		end
	end
	return false
end

-- `is:` words in a tag search say what kind of line may match (a colon
-- can't be part of a tag, so they never clash with one): @[rust is:heading]
M.IS_KINDS = { "heading", "label", "item", "task", "open", "done", "resource" }

local function is_kind(doc, lnum, info, kind)
	local item = info.kind == "item" and info.item or nil
	if kind == "heading" then
		return info.kind == "heading" or info.kind == "bold_heading"
	elseif kind == "label" then
		return info.kind == "label"
	elseif kind == "item" then
		return item ~= nil
	elseif kind == "task" then
		return item ~= nil and item.mark ~= nil
	elseif kind == "open" then
		return item ~= nil and item.mark == " "
	elseif kind == "done" then
		return item ~= nil and (item.mark == "x" or item.mark == "X")
	elseif kind == "resource" then
		return M.is_resource_heading(doc, lnum) or (item ~= nil and holds_link(doc, lnum))
	end
	return false
end

--- Lines tagged as a tag search asks, in the notes or sections its scope
--- resolves to (see the module header). Same results shape as resolve().
--- `is:kind` words narrow a group to lines of that kind (M.IS_KINDS).
---@param content string what is inside @[...]
---@param opts { bufnr?: integer, doc?: table }?
---@return SearchResult[] results, string? err
function M.tag_search(content, opts)
	opts = opts or {}
	local q = M.parse_tag_search(content)
	local component = { type = "tag_search", text = content, original = "@[" .. content .. "]" }
	if #q.groups == 0 then
		return {}, "No tags in " .. component.original
	end
	for _, group in ipairs(q.groups) do
		for _, term in ipairs(group) do
			local kind = term:match("^is:(.*)$")
			if kind and not vim.tbl_contains(M.IS_KINDS, kind) then
				return {}, "Unknown is:" .. kind .. " (is: " .. table.concat(M.IS_KINDS, ", ") .. ")"
			end
		end
	end

	-- Ranges to look in: { doc, s, e }
	local ranges = {}
	if q.all then
		for _, path in ipairs(notes().index().files) do
			local doc = Document().get(path)
			if doc then
				ranges[#ranges + 1] = { doc = doc, s = 1, e = #doc.lines }
			end
		end
	elseif q.scope then
		local prefix = q.is_local and "/" or (q.home and "~/" or "")
		local results, err = M.resolve(prefix .. table.concat(q.scope, "/"), opts)
		if #results == 0 then
			return {}, err
		end
		for _, r in ipairs(results) do
			local e = r.whole and #r.doc.lines or r.end_line or r.lnum
			ranges[#ranges + 1] = { doc = r.doc, s = r.whole and 1 or r.lnum, e = e }
		end
	else
		local doc = opts.doc or Document().from_buffer(opts.bufnr or 0)
		if not doc then
			return {}, "No buffer to resolve a local link in"
		end
		ranges[1] = { doc = doc, s = 1, e = #doc.lines }
	end

	local results, seen = {}, {}
	for _, range in ipairs(ranges) do
		local doc = range.doc
		local inherited = {} -- section start line -> tags of it and its ancestors
		local function section_tags(node)
			if node:is_root() or node.type == "article" then
				return {}
			end
			if not inherited[node.start_line] then
				local tags = {}
				-- a resource heading's section (its notes) starts afresh
				if not M.is_resource_heading(doc, node.start_line) then
					tags = vim.deepcopy(section_tags(node.parent))
					for tag in pairs(line_tags(doc, node.start_line)) do
						tags[tag] = true
					end
				end
				inherited[node.start_line] = tags
			end
			return inherited[node.start_line]
		end
		for lnum = range.s, math.min(range.e, #doc.lines) do
			local info = doc:info(lnum)
			local key = tostring(doc.filepath) .. ":" .. lnum
			if info and not NOT_CONTENT[info.kind] and not doc:in_code(lnum) and not seen[key] then
				local own = line_tags(doc, lnum)
				local node = doc:node_at(lnum)
				-- a resource heading itself takes the tags above it
				local above
				if node.start_line == lnum and M.is_resource_heading(doc, lnum) then
					above = section_tags(node.parent)
				elseif M.is_resource_note(doc, lnum) then
					above = {}
				else
					above = section_tags(node)
				end
				local match = false
				for _, group in ipairs(q.groups) do
					match = true
					for _, tag in ipairs(group) do
						local kind = tag:match("^is:(.*)$")
						if kind then
							if not is_kind(doc, lnum, info, kind) then
								match = false
								break
							end
						elseif not (own[tag] or above[tag]) then
							match = false
							break
						end
					end
					if match then
						break
					end
				end
				if match then
					seen[key] = true
					-- the column of the first queried tag on the line itself
					local col
					for _, group in ipairs(q.groups) do
						for _, tag in ipairs(group) do
							if own[tag] and (not col or own[tag] < col) then
								col = own[tag]
							end
						end
					end
					results[#results + 1] = make_result(doc, lnum, col or 1, component)
				end
			end
		end
	end
	if #results == 0 then
		return {}, "No matches found for: " .. component.original
	end
	return results
end

--- Canonical target of a link (the first result).
---@return SearchResult? result, string? err
function M.resolve_first(link, opts)
	local results, err = M.resolve(link, opts)
	return results[1], err
end

--- Is this "./" followed by a typed component ([./-Item], [./#Heading],
--- [./:Label], [./*Bold], [./>Link])? Such a link continues its parent line's
--- link (absolute); other "./" links are file paths.
---@param definition string
function M.is_parent_relative(definition)
	return syntax.trim(definition or ""):match("^%./[#:%-%*>]") ~= nil
end

M.NO_PARENT_LINK = "No link on a parent line for ./"

local function indent_of(line)
	return #line:match("^[ \t]*")
end

--- The link a parent-relative link stands for: the first link of the
--- nearest parent line (less indented, above it) that has one, followed by
--- the components after "./". Parents may be relative themselves. Other
--- links come back unchanged. `lines` are the note's lines, `lnum` the line
--- the link is written on. app/links (Absolute) is the same.
---@param definition string without brackets
---@param lines string[]
---@param lnum integer
---@return string? definition, string? err
function M.absolute(definition, lines, lnum)
	local def = syntax.trim(definition or "")
	if not M.is_parent_relative(def) then
		return def
	end
	local parent, err = M.parent_link(lines, lnum)
	if not parent then
		return nil, err
	end
	return parent .. "/" .. def:sub(3)
end

--- The absolute link a "./" link on line `lnum` continues: the first link
--- on the nearest less-indented line above that has one (made absolute when
--- it is relative itself). nil and NO_PARENT_LINK when there is none.
function M.parent_link(lines, lnum)
	local line = lines and lines[lnum]
	if not line then
		return nil, M.NO_PARENT_LINK
	end
	local want = indent_of(line)
	for l = lnum - 1, 1, -1 do
		local text = lines[l]
		if text:match("%S") and indent_of(text) < want then
			for _, span in ipairs(M.links_on(text)) do
				local parent = span.definition
				if M.is_parent_relative(parent) then
					return M.absolute(parent, lines, l)
				elseif not parent:match("^%.%.?/") and not parent:match("^~") then
					return parent
				end
			end
			want = indent_of(text)
			if want == 0 then
				break
			end
		end
	end
	return nil, M.NO_PARENT_LINK
end

--- Plain links ([...], not ![...]) on a line, in order.
function M.links_on(line)
	local out = {}
	for _, span in ipairs(syntax.links(line)) do
		if span.type == "link" then
			out[#out + 1] = span
		end
	end
	return out
end

--- A link written as a path relative to its note ([./z/scan.pdf],
--- [../folder]) names a file, not a note: the absolute path it names
--- (without any #fragment), or nil for every other link (parent-relative
--- links included).
---@param definition string
---@param from_file string the note the link is written in
---@return string?
function M.relative_path(definition, from_file)
	local def = syntax.trim(definition or "")
	if not def:match("^%.%.?/") or M.is_parent_relative(def) then
		return nil
	end
	def = def:gsub("#.*$", "")
	local dir = vim.fn.fnamemodify(from_file, ":p:h")
	return (vim.fn.simplify(dir .. "/" .. def):gsub("(.)/$", "%1"))
end

--- Canonical target of a link as a section node: the deepest section that
--- contains the matched line (the article node for article links).
---@return table? node, SearchResult? result, string? err
function M.resolve_node(link, opts)
	local result, err = M.resolve_first(link, opts)
	if not result then
		return nil, nil, err
	end
	return result.doc:node_at(result.lnum), result
end

-- =============================================================================
-- Link Building
-- =============================================================================

local SECTION_PREFIX = { heading = "#", label = ":", bold_heading = "*" }

--- Join components into a link: build_link({"Projects", "#1 Programming"})
--- -> "[Projects/#1 Programming]"
function M.build_link(components)
	return "[" .. table.concat(components, "/") .. "]"
end

--- Text usable inside a link component: the longest prefix without link
--- syntax ("[", "]", "/"), an "@" (it would read as an attribute) or a "|"
--- (it would split a table cell), with balanced parentheses, trimmed.
--- Everything else is kept: "&", "'", ",", "?", non-ASCII letters. Section
--- and item matches are prefix matches, so the shortened text still finds
--- the same section. A colon only means "label" at the start of a
--- component, so "6.3: Homelab" keeps it (and stays apart from "6.3:
--- Zortex" and "6.3"); trailing colons, commas and semicolons go.
function M.component_text(text)
	text = text or ""
	local prefix = text:match("^[^%[%]/@|]*")
	local _, opens = prefix:gsub("%(", "")
	local _, closes = prefix:gsub("%)", "")
	if opens ~= closes then
		prefix = prefix:match("^[^%(]*")
	end
	-- a colon inside stays ("6.3: Homelab"); one at the end ("Async book:"
	-- before a URL) is punctuation
	prefix = vim.trim((vim.trim(prefix):gsub("[:,;]+$", "")))
	if prefix == "" then
		-- Nothing usable at the start: keep the text minus link syntax
		prefix = vim.trim((text:gsub("[%[%]/|]", "")))
	end
	return prefix
end

--- Typed path components of a section node: primary article name, then
--- "#heading" / ":label" / "*bold" for every section on the way down.
function M.node_components(doc, node)
	local parts = {}
	for _, s in ipairs(node:get_full_path()) do
		if s.type == "article" then
			parts[#parts + 1] = (doc and doc:name()) or s.text
		elseif SECTION_PREFIX[s.type] then
			parts[#parts + 1] = SECTION_PREFIX[s.type] .. M.component_text(s.text)
		end
	end
	return parts
end

--- Component for the list item on line `lnum`: "-KR1" for keyed items
--- ("- KR1: [ ] …"), otherwise "-" + the item's text ("-Call the bank").
function M.item_component(line)
	local item = require("zortex.core.item").from_line(line)
	if not item then
		return nil
	end
	if item.key then
		return "-" .. M.component_text(item.key)
	end
	return "-" .. M.component_text(M.link_text(item.text))
end

--- Canonical link to a section node, e.g. "[Projects/#1 Programming/#1.4 - zortex]".
function M.link_for_node(doc, node)
	local parts = M.node_components(doc, node)
	if #parts == 0 then
		return nil
	end
	return M.build_link(parts)
end

-- =============================================================================
-- Links to search results
-- =============================================================================

--- Extract a short identifier from a line to use as a %text search component.
--- Prefers the display text of the first markdown or zortex link on the line.
--- Falls back to a trimmed/truncated version of the line.
---@param line string The raw line text
---@return string A short identifier suitable for use in a % search
function M.extract_line_identifier(line)
	if not line then
		return "?"
	end

	-- A task checkbox "[ ]" is not a link
	line = line:gsub("^%s*%-%s*%[.%]%s*", "")

	-- 1. Try markdown link: [display text](url)
	local md_text = line:match("%[([^%]]+)%]%(")
	if md_text and md_text ~= "" then
		return syntax.trim(md_text)
	end

	-- 2. Try zortex link: [content]  (but not footnotes [^...])
	local zortex_text = line:match("%[([^%]^][^%]]*)%]")
	if zortex_text and zortex_text ~= "" then
		return syntax.trim(zortex_text)
	end

	-- 3. Fallback: strip leading list markers and attributes
	local text = syntax.strip_attributes((line:gsub("^%s*%-%s*", "")))

	-- Truncate if very long (keep it usable as a search term)
	if #text > 80 then
		text = text:sub(1, 77) .. "..."
	end

	return text
end

--- A link's title for pickers: a markdown link's text, else the text of
--- its line before the line's first link ("- The Art of Electronics:
--- ./z/books/aoe.pdf" -> "The Art of Electronics"), else the line's text
--- after the link.
function M.follow_title(line, target)
	line = line or ""
	if target and target.type == "markdown" and target.display_text ~= "" then
		return target.display_text
	end
	local col = target and target.col or 1
	local first = M.follow_targets(line)[1]
	local before = line_text(line:sub(1, math.min(col, first and first.col or col) - 1)):gsub("[%s:;,%-|]+$", "")
	if before ~= "" then
		return before
	end
	local full = target and target.full_match_text or ""
	local after = line_text(line:sub(col + #full)):gsub("^[%s:;,%-|]+", "")
	return after
end

--- The text a > component uses for a link on `line`: a markdown link's
--- text, else the line's text before the link, else the whole line's text
--- (shortened like other components).
function M.follow_text(line, target)
	line = line or ""
	if target and target.type == "markdown" then
		return M.component_text(target.display_text)
	end
	local text = target and target.col and M.component_text(line_text(line:sub(1, target.col - 1))) or ""
	return text ~= "" and text or M.component_text(line_text(line))
end

--- Build a full zortex-style link string from a search result: the section
--- path to the matched line, plus the matched component when the line is not
--- itself a section header.
---@param result table A SearchResult with file, lnum, component, lines/doc
---@return string The zortex link, e.g. "[Resources/#Tools/@rust]"
function M.build_result_link(result)
	local parts, section_lnum
	if result.doc then
		local node = result.doc:node_at(result.lnum)
		parts = M.node_components(result.doc, node)
		section_lnum = not node:is_root() and node.start_line or nil
	elseif result.lines then
		local doc = require("zortex.core.document").from_lines(result.lines)
		local node = doc:node_at(result.lnum)
		parts = M.node_components(doc, node)
		section_lnum = not node:is_root() and node.start_line or nil
	else
		local comp = result.component
		return (comp and comp.original) and ("[" .. comp.original .. "]") or "[?]"
	end

	-- Append the matched component unless the match IS the innermost section.
	local comp = result.component
	if comp and section_lnum ~= result.lnum then
		if comp.type == "query" or comp.type == "tag_search" then
			table.insert(parts, "%" .. M.extract_line_identifier(result.text))
		elseif comp.type == "tag" then
			table.insert(parts, "@" .. comp.text)
		elseif comp.type == "heading" then
			table.insert(parts, "#" .. comp.text)
		elseif comp.type == "label" then
			table.insert(parts, ":" .. comp.text)
		elseif comp.type == "listitem" then
			table.insert(parts, "-" .. comp.text)
		elseif comp.type == "highlight" then
			table.insert(parts, "*" .. comp.text)
		elseif comp.type == "follow" then
			table.insert(parts, ">" .. M.follow_text(result.text, result.target))
		elseif comp.type == "article" and #parts == 0 then
			table.insert(parts, comp.text)
		end
	end

	if #parts == 0 then
		return "[?]"
	end
	return M.build_link(parts)
end

return M
