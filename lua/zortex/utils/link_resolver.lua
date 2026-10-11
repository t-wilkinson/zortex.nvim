-- utils/link_resolver.lua - Resolve zortex links to locations (single resolver)
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
--   Label, list item, highlight, %query, a + b, a & b: line searches likewise
--
-- Results come back in note order (top-level files first, then line order), so
-- results[1] is the canonical target. Every consumer (following links,
-- completion, projects, OKR, calendar) uses this module, so a link means the
-- same thing everywhere. Archived notes are skipped unless a component is
-- @Archive or opts.include_archived is set.
local M = {}

local parser = require("zortex.utils.parser")
local buffer = require("zortex.utils.buffer")
local constants = require("zortex.constants")

local function Document()
	return require("zortex.core.document")
end

local function notes()
	return require("zortex.core.notes")
end

-- @class SearchResult
-- @field file string Full path to file
-- @field lnum number Line number (1-indexed)
-- @field col number Column number (1-indexed)
-- @field text string Line text
-- @field component table Component that matched
-- @field lines string[] Lines of the file
-- @field doc Document Snapshot the result came from

-- =============================================================================
-- Pattern Creation
-- =============================================================================

function M.create_search_pattern(component)
	local text = parser.escape_pattern(component.text)

	if component.type == "tag" then
		return "^@" .. text .. "$"
	elseif component.type == "heading" then
		return "^#+%s*" .. text .. ".*$"
	elseif component.type == "label" then
		return "^" .. text .. ".*:"
	elseif component.type == "listitem" then
		return "^%s*- " .. text .. "$"
	elseif component.type == "highlight" then
		-- Match *, **, or *** wrapping
		return "%*%*?%*?" .. text .. "%*%*?%*?"
	elseif component.type == "query" then
		-- Plain substring search
		return text
	elseif component.type == "and_query" then
		-- Return a table of patterns to search for simultaneously (ALL must match)
		local patterns = {}
		for _, tag in ipairs(component.tags) do
			local escaped = parser.escape_pattern(tag)
			table.insert(patterns, escaped)
		end
		return patterns
	elseif component.type == "or_query" then
		-- Return a table of patterns (ANY must match)
		local patterns = {}
		for _, tag in ipairs(component.tags) do
			local escaped = parser.escape_pattern(tag)
			table.insert(patterns, escaped)
		end
		return patterns
	elseif component.type == "article" then
		-- This is handled differently - by finding article files
		return nil
	end
end

-- =============================================================================
-- Line Matching
-- =============================================================================

local QUERY_TYPES = { query = true, and_query = true, or_query = true }

--- Find lines in [start_line, end_line] matching a component. Matching is
--- case-insensitive, except for %/+/& queries that contain an uppercase letter.
---@return { lnum: integer, col: integer }[]
function M.search_lines(lines, component, start_line, end_line)
	local pattern = M.create_search_pattern(component)
	if not pattern then
		return {}
	end

	local case_sensitive = QUERY_TYPES[component.type] and component.text:match("[A-Z]") ~= nil
	local patterns = type(pattern) == "table" and pattern or { pattern }
	if not case_sensitive then
		for i, pat in ipairs(patterns) do
			patterns[i] = pat:lower()
		end
	end
	local require_all = component.type ~= "or_query"

	local out = {}
	for lnum = start_line or 1, math.min(end_line or #lines, #lines) do
		local line = case_sensitive and lines[lnum] or lines[lnum]:lower()
		local is_match, match_col = require_all, nil
		for _, pat in ipairs(patterns) do
			local col = line:find(pat)
			if require_all then
				if not col then
					is_match = false
					break
				end
				match_col = match_col or col
			elseif col then
				is_match, match_col = true, col
				break
			end
		end
		if is_match then
			out[#out + 1] = { lnum = lnum, col = match_col or 1 }
		end
	end
	return out
end

-- =============================================================================
-- Section Boundaries
-- =============================================================================

-- Lines-only variant (used by completion, which works on raw lines)
function M.get_section_end(lines, start_lnum, component)
	-- Map component type to section type
	local section_type = constants.SECTION_TYPE.TEXT
	local heading_level = nil

	if component.type == "article" then
		section_type = constants.SECTION_TYPE.ARTICLE
	elseif component.type == "heading" then
		section_type = constants.SECTION_TYPE.HEADING
		-- Extract heading level from the line
		heading_level = parser.get_heading_level(lines[start_lnum])
	elseif component.type == "tag" then
		section_type = constants.SECTION_TYPE.TAG
	elseif component.type == "label" then
		section_type = constants.SECTION_TYPE.LABEL
	elseif component.type == "highlight" then
		-- Bold headings in search context
		if parser.is_bold_heading(lines[start_lnum]) then
			section_type = constants.SECTION_TYPE.BOLD_HEADING
		else
			-- Just a highlighted text, single line
			return start_lnum
		end
	elseif
		component.type == "listitem"
		or component.type == "query"
		or component.type == "and_query"
		or component.type == "or_query"
	then
		-- These don't create sections, just single line matches
		return start_lnum
	end

	-- Use the unified parser function
	return parser.find_section_end(lines, start_lnum, section_type, heading_level)
end

local SINGLE_LINE = { listitem = true, query = true, and_query = true, or_query = true, tag = true }

-- Range a match narrows to: the section that starts at the matched line.
function M.section_end(doc, lnum, component)
	if SINGLE_LINE[component.type] then
		return lnum
	end
	if component.type == "highlight" and not parser.is_bold_heading(doc.lines[lnum] or "") then
		return lnum
	end
	local node = doc:node_starting_at(lnum)
	if node then
		return node.end_line
	end
	return M.get_section_end(doc.lines, lnum, component)
end

-- =============================================================================
-- Resolution
-- =============================================================================

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

local function mentions_archive(parsed)
	for _, c in ipairs(parsed.components) do
		if c.type == "tag" and c.text:lower() == constants.ARCHIVE_TAG:lower() then
			return true
		end
	end
	return false
end

--- Resolve a link to every matching location.
---@param link string|table  "[P/#1.4 - zortex]", "P/#1.4", or parse_link_definition() output
---@param opts { bufnr?: integer, doc?: table, include_archived?: boolean }?
---@return SearchResult[] results, string? err
function M.resolve(link, opts)
	opts = opts or {}
	local parsed = type(link) == "table" and link or parser.parse_link_definition(link)
	if not parsed or not parsed.components or #parsed.components == 0 then
		return {}, "Invalid link"
	end

	local is_local = parsed.scope == "local"
	local idx
	local cands -- { path, doc?, start_line?, end_line? }

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
		idx = notes().index({ include_archived = include_archived })
		cands = {}
		for _, path in ipairs(idx.files) do
			cands[#cands + 1] = { path = path }
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

		-- Article and header-tag components select whole files. An article
		-- name ranks files that declare it as an alias before files that are
		-- only tagged with it.
		local select_file, rank
		if not is_local and comp.type == "article" then
			select_file = function(h)
				return parser.list_has(h.names, comp.text) or parser.list_has(h.tags, comp.text)
			end
			rank = function(h)
				return parser.list_has(h.names, comp.text) and 1 or 2
			end
		elseif not is_local and comp.type == "tag" then
			local function has_tag(h)
				return parser.list_has(h.tags, comp.text)
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
				if h and select_file(h) then
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
						results[#results + 1] = make_result(doc, lnum, 1, comp, text)
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
							results[#results + 1] = make_result(doc, m.lnum, m.col, comp)
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

--- Canonical target of a link (the first result).
---@return SearchResult? result, string? err
function M.resolve_first(link, opts)
	local results, err = M.resolve(link, opts)
	return results[1], err
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

--- UI wrapper: resolve and notify when nothing matched.
function M.process_link(parsed)
	local results, err = M.resolve(parsed)
	if #results == 0 and err then
		vim.notify(err, vim.log.levels.INFO)
	end
	return results
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

--- Typed path components of a section node: primary article name, then
--- "#heading" / ":label" / "*bold" for every section on the way down.
function M.node_components(doc, node)
	local parts = {}
	for _, s in ipairs(node:get_full_path()) do
		if s.type == "article" then
			parts[#parts + 1] = (doc and doc:name()) or s.text
		elseif SECTION_PREFIX[s.type] then
			-- "/" separates components; section matches are prefix matches, so
			-- the text up to the first "/" still finds the same section.
			local text = s.text:find("/", 1, true) and vim.trim(s.text:match("^[^/]*")) or s.text
			parts[#parts + 1] = SECTION_PREFIX[s.type] .. text
		end
	end
	return parts
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
-- Tag Search (@[...] links)
-- =============================================================================

--- Search the current buffer for lines containing @tag patterns.
--- Used by @[tag1 + tag2] style links.
---@param link_info table The parsed tag_search link info from extract_link_at
---@param source_lnum number Line number of the link itself (to self-filter)
---@return table[] SearchResult list
function M.search_tag_query(link_info, source_lnum)
	local lines = buffer.get_lines()
	local current_file = vim.fn.expand("%:p")
	local results = {}

	-- Build @tag patterns for each term
	-- Each term should match as an @tag on the line (e.g. term "rust" matches "@rust")
	local tag_patterns = {}
	for _, term in ipairs(link_info.terms) do
		-- Match @term as a whole word: preceded by start-of-string or whitespace,
		-- followed by end-of-string or whitespace/punctuation
		table.insert(tag_patterns, (parser.escape_pattern(term:lower())))
	end

	local is_and = link_info.query_type == "and"
	-- "single" behaves like AND with one term

	for lnum = 1, #lines do
		-- Skip the source line (self-filter)
		if lnum ~= source_lnum then
			local line = lines[lnum]
			local line_lower = line:lower()

			-- Extract all @tags from the line
			local line_tags = {}
			for tag in line_lower:gmatch("@([%w_%-]+)") do
				line_tags[tag] = true
			end

			local is_match = false
			local match_col = 1

			if is_and or link_info.query_type == "single" then
				-- AND / single: all terms must appear as @tags
				is_match = true
				for _, pat in ipairs(tag_patterns) do
					if not line_tags[pat] then
						is_match = false
						break
					end
				end
			else
				-- OR: any term as @tag
				for _, pat in ipairs(tag_patterns) do
					if line_tags[pat] then
						is_match = true
						-- Find column position for the first matching tag
						local col = line_lower:find("@" .. pat)
						if col then
							match_col = col
						end
						break
					end
				end
			end

			if is_match then
				-- For AND, find column of first matching tag
				if (is_and or link_info.query_type == "single") and match_col == 1 then
					local col = line_lower:find("@" .. tag_patterns[1])
					if col then
						match_col = col
					end
				end

				table.insert(results, {
					file = current_file,
					lnum = lnum,
					col = match_col,
					text = line,
					lines = lines,
					component = {
						type = "tag_search",
						text = link_info.display_text,
						original = link_info.full_match_text,
					},
				})
			end
		end
	end

	return results
end

-- =============================================================================
-- Footnote Search
-- =============================================================================

function M.search_footnote(ref_id)
	local pattern = constants.PATTERNS.FOOTNOTE_DEF:gsub("%(%.%-%)", "(" .. parser.escape_pattern(ref_id) .. ")")
	local lines = buffer.get_lines()

	for lnum, line in ipairs(lines) do
		if line:find(pattern) then
			return { lnum = lnum, col = 1 }
		end
	end

	return nil
end

-- =============================================================================
-- Breadcrumb Link Generation
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
		return parser.trim(md_text)
	end

	-- 2. Try zortex link: [content]  (but not footnotes [^...])
	local zortex_text = line:match("%[([^%]^][^%]]*)%]")
	if zortex_text and zortex_text ~= "" then
		return parser.trim(zortex_text)
	end

	-- 3. Fallback: strip leading list markers and attributes
	local text = parser.strip_attributes((line:gsub("^%s*[%-*]%s*", "")))

	-- Truncate if very long (keep it usable as a search term)
	if #text > 80 then
		text = text:sub(1, 77) .. "..."
	end

	return text
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
		parts = {}
		local path = parser.build_section_path(result.lines, result.lnum)
		for _, section in ipairs(path) do
			if section.type == constants.SECTION_TYPE.ARTICLE then
				parts[#parts + 1] = section.text
			elseif SECTION_PREFIX[section.type] then
				parts[#parts + 1] = SECTION_PREFIX[section.type] .. section.text
			end
		end
		section_lnum = #path > 0 and path[#path].lnum or nil
	else
		local comp = result.component
		return (comp and comp.original) and ("[" .. comp.original .. "]") or "[?]"
	end

	-- Append the matched component unless the match IS the innermost section.
	local comp = result.component
	if comp and section_lnum ~= result.lnum then
		if QUERY_TYPES[comp.type] or comp.type == "tag_search" then
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
		elseif comp.type == "article" and #parts == 0 then
			table.insert(parts, comp.text)
		end
	end

	if #parts == 0 then
		return "[?]"
	end
	return M.build_link(parts)
end

-- =============================================================================
-- Quickfix Integration
-- =============================================================================

--- Custom quickfix text function that shows only the link text,
--- hiding filename, line number, and column.
function M.quickfix_text_func(info)
	local items = vim.fn.getqflist({ id = info.id, items = 1 }).items
	local lines = {}
	for i = info.start_idx, info.end_idx do
		local item = items[i]
		if item then
			table.insert(lines, item.text or "")
		else
			table.insert(lines, "")
		end
	end
	return lines
end

--- Jump from the quickfix window to the entry under the cursor,
--- opening in the target window (or previous window as fallback).
function M.quickfix_jump()
	local qf_list = vim.fn.getqflist()
	local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
	local entry = qf_list[cursor_lnum]

	if not entry or entry.bufnr == 0 then
		vim.notify("No valid quickfix entry under cursor", vim.log.levels.INFO)
		return
	end

	-- Determine target window: use zortex target window if available,
	-- otherwise fall back to the previous window
	local target_win
	local ok, buf_module = pcall(require, "zortex.utils.buffer")
	if ok and buf_module.get_target_window then
		target_win = buf_module.get_target_window()
	end

	-- Fallback: use the previous window (the one before quickfix was focused)
	if not target_win or not vim.api.nvim_win_is_valid(target_win) then
		local qf_win = vim.api.nvim_get_current_win()
		vim.cmd("wincmd p")
		target_win = vim.api.nvim_get_current_win()
		-- If we're still in the quickfix window (no previous window), find any non-qf window
		if target_win == qf_win then
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				if win ~= qf_win then
					target_win = win
					break
				end
			end
		end
	end

	-- Load the buffer and jump
	local bufnr = entry.bufnr
	vim.api.nvim_win_set_buf(target_win, bufnr)
	vim.api.nvim_win_set_cursor(target_win, { entry.lnum, math.max(0, entry.col - 1) })
	vim.api.nvim_set_current_win(target_win)
	vim.cmd("normal! zz")
end

function M.populate_quickfix(results)
	local qf_list = {}

	for _, result in ipairs(results) do
		local link = M.build_result_link(result)

		table.insert(qf_list, {
			filename = result.file,
			lnum = result.lnum,
			col = result.col,
			text = link,
			valid = 1,
		})
	end

	vim.fn.setqflist(qf_list, "r")
	if #qf_list > 0 then
		-- Set custom display: show only the link text, no file/lnum/col
		vim.o.quickfixtextfunc = "v:lua.require'zortex.utils.link_resolver'.quickfix_text_func"

		vim.cmd("copen")

		-- Map <CR> in the quickfix buffer to jump via target window
		vim.api.nvim_buf_set_keymap(0, "n", "<CR>", "", {
			noremap = true,
			silent = true,
			callback = M.quickfix_jump,
		})
	end
end

return M
