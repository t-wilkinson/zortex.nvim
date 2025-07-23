-- utils/resolver.lua - Search functionality for Zortex with normalized section handling
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")
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
	elseif component.type == "listitem" or component.type == "query" then
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
	local case_sensitive = component.type == "query" and component.text:match("[A-Z]")

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
				local search_pattern = case_sensitive and pattern or pattern:lower()

				if search_line:find(search_pattern) then
					table.insert(results, {
						file = file_path,
						lnum = lnum,
						col = search_line:find(search_pattern),
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
	local case_sensitive = component.type == "query" and component.text:match("[A-Z]")
	local current_file = vim.fn.expand("%:p")

	start_line = start_line or 1
	end_line = end_line or #lines

	for lnum = start_line, end_line do
		local line = lines[lnum]
		local search_line = case_sensitive and line or line:lower()
		local search_pattern = case_sensitive and pattern or pattern:lower()

		if search_line:find(search_pattern) then
			table.insert(results, {
				file = current_file,
				lnum = lnum,
				col = search_line:find(search_pattern),
				text = line,
				component = component,
				lines = lines,
			})
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
-- Quickfix Integration
-- =============================================================================

function M.populate_quickfix(results)
	local qf_list = {}

	for _, result in ipairs(results) do
		local text = string.format("[%s: %s] %s", result.component.type, result.component.text, result.text:sub(1, 80))

		table.insert(qf_list, {
			filename = result.file,
			lnum = result.lnum,
			col = result.col,
			text = text,
			valid = 1,
		})
	end

	vim.fn.setqflist(qf_list, "r")
	if #qf_list > 0 then
		vim.cmd("copen")
	end
end

return M
