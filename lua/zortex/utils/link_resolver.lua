-- utils/resolver.lua - Search functionality for Zortex with normalized section handling
local M = {}

local parser = require("zortex.utils.parser")
local fs = require("zortex.utils.filesystem")
local buffer = require("zortex.utils.buffer")
local constants = require("zortex.constants")

-- =============================================================================
-- Search Result Type
-- =============================================================================

-- @class SearchResult
-- @field file string Full path to file
-- @field lnum number Line number (1-indexed)
-- @field col number Column number (1-indexed)
-- @field text string Line text
-- @field component table Component that matched

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
-- Article Search
-- =============================================================================

function M.find_article_files(article_name)
	local files = fs.get_all_note_files()
	local matches = {}
	local search_name = article_name:lower()

	for _, file_path in ipairs(files) do
		local lines = fs.read_lines(file_path)
		if lines then
			-- Check all article names/aliases at the start of the file
			for i, line in ipairs(lines) do
				local title = line:match(constants.PATTERNS.ARTICLE_TITLE)
				if title then
					-- Found an article name/alias
					if parser.trim(title):lower() == search_name then
						table.insert(matches, file_path)
						break
					end
				else
					-- Stop when we hit a non-article-title line
					break
				end

				-- Safety limit
				if i > 10 then
					break
				end
			end
		end
	end

	return matches
end

-- =============================================================================
-- Section Boundaries (Using Normalized Parser)
-- =============================================================================

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

-- =============================================================================
-- Component Search
-- =============================================================================

function M.search_component_in_files(component, file_paths, section_bounds)
	local pattern = M.create_search_pattern(component)
	if not pattern then
		return {}
	end

	local results = {}
	local case_sensitive = (component.type == "query" or component.type == "and_query" or component.type == "or_query")
		and component.text:match("[A-Z]")
	local is_multi_pattern = type(pattern) == "table"
	local is_or_query = component.type == "or_query"

	for _, file_path in ipairs(file_paths) do
		local lines = fs.read_lines(file_path)
		if lines then
			-- Determine search bounds
			local start_line = 1
			local end_line = #lines

			if section_bounds and section_bounds[file_path] then
				start_line = section_bounds[file_path].start_line or 1
				end_line = section_bounds[file_path].end_line or #lines
			end

			-- Search within bounds
			for lnum = start_line, end_line do
				local line = lines[lnum]
				local search_line = case_sensitive and line or line:lower()

				local is_match = false
				local match_col = 1

				if is_multi_pattern then
					if is_or_query then
						-- OR: match if ANY pattern found
						for _, pat in ipairs(pattern) do
							local search_pat = case_sensitive and pat or pat:lower()
							local col = search_line:find(search_pat)
							if col then
								is_match = true
								match_col = col
								break
							end
						end
					else
						-- AND: match if ALL patterns found
						is_match = true
						for _, pat in ipairs(pattern) do
							local search_pat = case_sensitive and pat or pat:lower()
							local col = search_line:find(search_pat)
							if not col then
								is_match = false
								break
							elseif match_col == 1 then
								match_col = col
							end
						end
					end
				else
					local search_pattern = case_sensitive and pattern or pattern:lower()
					local col = search_line:find(search_pattern)
					if col then
						is_match = true
						match_col = col
					end
				end

				if is_match then
					table.insert(results, {
						file = file_path,
						lnum = lnum,
						col = match_col,
						text = line,
						component = component,
						lines = lines,
					})
				end
			end
		end
	end

	return results
end

function M.search_in_buffer(component, start_line, end_line)
	local pattern = M.create_search_pattern(component)
	if not pattern then
		return {}
	end

	local results = {}
	local lines = buffer.get_lines()
	local case_sensitive = (component.type == "query" or component.type == "and_query" or component.type == "or_query")
		and component.text:match("[A-Z]")
	local current_file = vim.fn.expand("%:p")
	local is_multi_pattern = type(pattern) == "table"
	local is_or_query = component.type == "or_query"

	start_line = start_line or 1
	end_line = end_line or #lines

	for lnum = start_line, end_line do
		local line = lines[lnum]
		local search_line = case_sensitive and line or line:lower()

		local is_match = false
		local match_col = 1

		if is_multi_pattern then
			if is_or_query then
				-- OR: match if ANY pattern found
				for _, pat in ipairs(pattern) do
					local search_pat = case_sensitive and pat or pat:lower()
					local col = search_line:find(search_pat)
					if col then
						is_match = true
						match_col = col
						break
					end
				end
			else
				-- AND: match if ALL patterns found
				is_match = true
				for _, pat in ipairs(pattern) do
					local search_pat = case_sensitive and pat or pat:lower()
					local col = search_line:find(search_pat)
					if not col then
						is_match = false
						break
					elseif match_col == 1 then
						match_col = col
					end
				end
			end
		else
			local search_pattern = case_sensitive and pattern or pattern:lower()
			local col = search_line:find(search_pattern)
			if col then
				is_match = true
				match_col = col
			end
		end

		if is_match then
			table.insert(results, {
				file = current_file,
				lnum = lnum,
				col = match_col,
				text = line,
				component = component,
				lines = lines,
			})
		end
	end

	return results
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
-- Link Processing
-- =============================================================================

function M.process_link(parsed_link)
	local results = {}
	local file_set = nil
	local section_bounds = {}

	-- Handle local scope
	if parsed_link.scope == "local" then
		local current_bounds = { start_line = 1, end_line = nil }

		for i, component in ipairs(parsed_link.components) do
			local component_results = M.search_in_buffer(component, current_bounds.start_line, current_bounds.end_line)

			if i == #parsed_link.components then
				-- Last component - return all matches
				for _, r in ipairs(component_results) do
					table.insert(results, r)
				end
			else
				-- Not last component - narrow search scope
				if #component_results == 0 then
					vim.notify("No matches found for: " .. component.original, vim.log.levels.INFO)
					return {}
				end

				-- Use first match to determine new bounds
				local first_match = component_results[1]
				current_bounds.start_line = first_match.lnum
				current_bounds.end_line = M.get_section_end(first_match.lines, first_match.lnum, component)
			end
		end

		return results
	else
		-- Global scope
		file_set = fs.get_all_note_files()
	end

	-- Process components sequentially
	for i, component in ipairs(parsed_link.components) do
		if component.type == "article" then
			-- Narrow file set to matching articles
			file_set = M.find_article_files(component.text)
			if #file_set == 0 then
				vim.notify("No article found: " .. component.text, vim.log.levels.INFO)
				return {}
			end

			-- Reset section bounds
			section_bounds = {}

			-- If this is the last component and we found exactly one file
			if i == #parsed_link.components and #file_set == 1 then
				table.insert(results, {
					file = file_set[1],
					lnum = 1,
					col = 1,
					text = "Article: " .. component.text,
					component = component,
				})
			end
		else
			-- Search for component in current file set
			local component_results = M.search_component_in_files(component, file_set, section_bounds)

			if i == #parsed_link.components then
				-- Last component - these are our final results
				for _, r in ipairs(component_results) do
					table.insert(results, r)
				end
			else
				-- Not last component - update section bounds
				if #component_results == 0 then
					vim.notify("No matches found for: " .. component.original, vim.log.levels.INFO)
					return {}
				end

				-- Create new section bounds based on matches
				local new_file_set = {}
				local new_section_bounds = {}
				local seen_files = {}

				for _, match in ipairs(component_results) do
					if not seen_files[match.file] then
						seen_files[match.file] = true
						table.insert(new_file_set, match.file)

						-- Calculate section bounds for this match
						local section_end = M.get_section_end(match.lines, match.lnum, component)
						new_section_bounds[match.file] = {
							start_line = match.lnum,
							end_line = section_end,
						}
					end
				end

				file_set = new_file_set
				section_bounds = new_section_bounds
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
-- Section Finding in Document
-- =============================================================================

-- Find section in a document using parsed link components
function M.find_section_by_link(doc, link_def)
	if not doc or not doc.sections or not link_def or not link_def.components then
		return nil
	end

	local start_idx = 1
	local current_section_list = doc.sections.children -- Start search with root's children

	-- Handle the article component of the link
	if link_def.components[start_idx] and link_def.components[start_idx].type == "article" then
		local article_name = link_def.components[start_idx].text
		local article_matches = false
		if doc.article_names then
			for _, name in ipairs(doc.article_names) do
				if name:lower() == article_name:lower() then
					article_matches = true
					break
				end
			end
		end
		if not article_matches then
			return nil -- This document does not match the article in the link
		end
		start_idx = 2 -- Move to the next component
	end

	-- If the link was only an article name (e.g., "[Projects]"), and it matched,
	-- return the root section of the document.
	if start_idx > #link_def.components then
		return doc.sections
	end

	local found_section = nil
	-- Sequentially find each component in the link
	for i = start_idx, #link_def.components do
		local component = link_def.components[i]
		require("zortex.core.logger").info("find_section_by_link", "", { component = component, link_def = link_def })
		local found_in_level = false
		for _, child in ipairs(current_section_list) do
			local is_match = (component.type == "heading" and child.type == "heading" and child.text == component.text)
				or (component.type == "label" and child.type == "label" and child.text == component.text)

			if is_match then
				found_section = child
				current_section_list = child.children -- Set the list for the next iteration
				found_in_level = true
				break
			end
		end
		if not found_in_level then
			return nil -- A component in the path was not found
		end
	end

	return found_section
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

	-- 3. Fallback: strip leading list markers and trim
	local text = line:gsub("^%s*[%-*]%s*", "")
	text = parser.trim(text)

	-- Truncate if very long (keep it usable as a search term)
	if #text > 80 then
		text = text:sub(1, 77) .. "..."
	end

	return text
end

--- Build a full zortex-style link string from a search result.
--- Uses build_section_path to reconstruct the article/heading/label breadcrumb,
--- then appends the matched component as the final path segment.
---@param result table A SearchResult with file, lnum, component, lines
---@return string The zortex link, e.g. "[Resources/#Tools/+@rust]"
function M.build_result_link(result)
	if not result.lines then
		-- Fallback: no lines available (e.g. article-only match)
		local comp = result.component
		if comp and comp.original then
			return "[" .. comp.original .. "]"
		end
		return "[?]"
	end

	local section_path = parser.build_section_path(result.lines, result.lnum)
	local parts = {}

	for _, section in ipairs(section_path) do
		if section.type == constants.SECTION_TYPE.ARTICLE then
			table.insert(parts, section.text)
		elseif section.type == constants.SECTION_TYPE.HEADING then
			table.insert(parts, "#" .. section.text)
		elseif section.type == constants.SECTION_TYPE.LABEL then
			table.insert(parts, ":" .. section.text)
		elseif section.type == constants.SECTION_TYPE.BOLD_HEADING then
			table.insert(parts, "*" .. section.text)
		end
	end

	-- Append the matched component as the final segment, but only if it
	-- isn't already represented by the last section in the path.
	-- (e.g. if the match IS a heading, build_section_path already includes it)
	local comp = result.component
	if comp then
		local already_in_path = false
		if #section_path > 0 then
			local last = section_path[#section_path]
			if last.lnum == result.lnum then
				-- The matched line is the same as the last section header
				already_in_path = true
			end
		end

		if not already_in_path then
			-- For search-type components (queries), generate a %text identifier
			-- from the matched line rather than echoing the search terms back.
			if
				comp.type == "and_query"
				or comp.type == "or_query"
				or comp.type == "query"
				or comp.type == "tag_search"
			then
				local line_id = M.extract_line_identifier(result.text)
				table.insert(parts, "%" .. line_id)
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
			elseif comp.type == "article" then
				-- Article is always the first path segment, already handled
				if #parts == 0 then
					table.insert(parts, comp.text)
				end
			end
		end
	end

	if #parts == 0 then
		return "[?]"
	end

	return "[" .. table.concat(parts, "/") .. "]"
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
