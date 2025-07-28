-- features/archive.lua - Intelligent section archiving and restoration
local M = {}

local parser = require("zortex.utils.parser")
local fs = require("zortex.utils.filesystem")
local constants = require("zortex.constants")
local Config = require("zortex.config")

-- =============================================================================
-- Archive Path Generation
-- =============================================================================

-- Generate archive file path from original file path
local function get_archive_path(filepath)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local filename = vim.fn.fnamemodify(filepath, ":t:r") -- filename without extension
	local ext = vim.fn.fnamemodify(filepath, ":e")

	-- Ensure z directory exists
	local archive_dir = fs.joinpath(dir, "z")
	vim.fn.mkdir(archive_dir, "p")

	return fs.joinpath(archive_dir, "archive." .. filename .. "." .. ext)
end

-- =============================================================================
-- Section Extraction
-- =============================================================================

-- Extract section content including all subsections
local function extract_section_content(lines, start_line, section_type, heading_level)
	local end_line = parser.find_section_end(lines, start_line, section_type, heading_level)

	local content = {}
	for i = start_line, end_line do
		table.insert(content, lines[i])
	end

	return content, start_line, end_line
end

-- Find the section containing the current line
local function find_containing_section(lines, target_line)
	local path = parser.build_section_path(lines, target_line)

	if #path == 0 then
		-- No sections found, search upward for the first section
		local code_tracker = parser.CodeBlockTracker:new()

		for lnum = target_line, 1, -1 do
			local line = lines[lnum]
			local in_code_block = code_tracker:update(line)
			local section_type = parser.detect_section_type(line, in_code_block)

			if section_type ~= constants.SECTION_TYPE.TEXT and section_type ~= constants.SECTION_TYPE.TAG then
				local heading_level = nil
				if section_type == constants.SECTION_TYPE.HEADING then
					heading_level = parser.get_heading_level(line)
				end

				return {
					line = lnum,
					type = section_type,
					level = heading_level,
					text = line,
				}
			end
		end

		return nil
	end

	-- Return the deepest section in the path
	local section = path[#path]
	return {
		line = section.lnum,
		type = section.type,
		level = section.level,
		text = lines[section.lnum],
	}
end

-- =============================================================================
-- Archive File Management
-- =============================================================================

-- Get or create archive file with proper headers
local function ensure_archive_file(archive_path, original_lines)
	if vim.fn.filereadable(archive_path) == 0 then
		-- Create new archive file with tags from original
		local header_lines = {}

		-- Copy all article names and tags from original
		for _, line in ipairs(original_lines) do
			if line:match("^@@") or line:match("^@%w") then
				table.insert(header_lines, line)
			else
				-- Stop at first non-tag line
				break
			end
		end

		-- Add empty line after headers
		if #header_lines > 0 then
			table.insert(header_lines, "")
		end

		fs.write_lines(archive_path, header_lines)
	end

	return fs.read_lines(archive_path) or {}
end

-- =============================================================================
-- Section Path Building
-- =============================================================================

-- Build the full section path from root to target section
local function build_full_section_path(lines, section_line)
	local path = parser.build_section_path(lines, section_line)
	local sections = {}

	-- Convert path to section content
	for _, section in ipairs(path) do
		table.insert(sections, {
			line = lines[section.lnum],
			type = section.type,
			level = section.level,
			priority = section.priority,
		})
	end

	return sections
end

-- =============================================================================
-- Section Merging
-- =============================================================================

-- Find insertion point for a section in the archive
local function find_merge_point(archive_lines, section_path, path_index)
	if path_index > #section_path then
		return nil
	end

	local target_section = section_path[path_index]
	local target_priority = target_section.priority

	-- Track code blocks
	local code_tracker = parser.CodeBlockTracker:new()

	-- Skip header lines (@@, @)
	local start_line = 1
	for i, line in ipairs(archive_lines) do
		if not (line:match("^@@") or line:match("^@%w") or line == "") then
			start_line = i
			break
		end
	end

	-- Search for matching section
	for lnum = start_line, #archive_lines do
		local line = archive_lines[lnum]
		local in_code_block = code_tracker:update(line)

		if line == target_section.line then
			-- Found exact match, continue with next level
			if path_index < #section_path then
				-- Find where to insert within this section
				local section_end =
					parser.find_section_end(archive_lines, lnum, target_section.type, target_section.level)

				-- Look for insertion point for next level
				local next_section = section_path[path_index + 1]
				local next_priority = next_section.priority

				-- Find appropriate position within section
				for i = lnum + 1, section_end do
					local inner_line = archive_lines[i]
					local inner_in_code = code_tracker:update(inner_line)
					local inner_type = parser.detect_section_type(inner_line, inner_in_code)

					if inner_type ~= constants.SECTION_TYPE.TEXT and inner_type ~= constants.SECTION_TYPE.TAG then
						local inner_level = nil
						if inner_type == constants.SECTION_TYPE.HEADING then
							inner_level = parser.get_heading_level(inner_line)
						end

						local inner_priority = constants.SECTION_HIERARCHY.get_priority(inner_type, inner_level)

						-- Insert before sections of equal or higher priority
						if inner_priority <= next_priority then
							return i, path_index + 1
						end
					end
				end

				-- No suitable position found, append at end of section
				return section_end + 1, path_index + 1
			else
				-- This is the last section in path, we're done
				return nil
			end
		end
	end

	-- Section not found, insert at top level
	if path_index == 1 then
		-- Insert after headers
		return start_line, path_index
	end

	return nil
end

-- Merge section content into archive
local function merge_into_archive(archive_lines, section_path, content)
	local insert_line, start_path_index = find_merge_point(archive_lines, section_path, 1)

	if not insert_line then
		-- Path fully exists, just append content at the end
		table.insert(archive_lines, "")
		for _, line in ipairs(content) do
			table.insert(archive_lines, line)
		end
	else
		-- Need to insert missing path sections and content
		local lines_to_insert = {}

		-- Add any missing sections from the path
		for i = start_path_index, #section_path do
			table.insert(lines_to_insert, section_path[i].line)
		end

		-- Add the actual content (skip the first line if it's already in path)
		local content_start = 1
		if #section_path > 0 and content[1] == section_path[#section_path].line then
			content_start = 2
		end

		for i = content_start, #content do
			table.insert(lines_to_insert, content[i])
		end

		-- Insert all lines
		for i = #lines_to_insert, 1, -1 do
			table.insert(archive_lines, insert_line, lines_to_insert[i])
		end
	end

	return archive_lines
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Archive the section at current cursor position
function M.archive_current_section()
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	local filepath = vim.api.nvim_buf_get_name(bufnr)

	if not filepath:match(Config.extension .. "$") then
		vim.notify("Not a Zortex file", vim.log.levels.ERROR)
		return
	end

	-- Get current buffer content
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- Find the section to archive
	local section = find_containing_section(lines, cursor_line)
	if not section then
		vim.notify("No section found at cursor position", vim.log.levels.WARN)
		return
	end

	-- Extract section content
	local content, start_line, end_line = extract_section_content(lines, section.line, section.type, section.level)

	-- Build full section path
	local section_path = build_full_section_path(lines, section.line)

	-- Get archive file path and content
	local archive_path = get_archive_path(filepath)
	local archive_lines = ensure_archive_file(archive_path, lines)

	-- Merge into archive
	archive_lines = merge_into_archive(archive_lines, section_path, content)

	-- Write archive file
	fs.write_lines(archive_path, archive_lines)

	-- Remove section from original file
	vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, {})

	-- Build link components for the archived section
	local link_components = {}
	local article_name = nil

	-- Get article name
	for _, line in ipairs(lines) do
		local name = parser.extract_article_name(line)
		if name then
			article_name = name
			break
		end
	end

	if article_name then
		table.insert(link_components, article_name)
	end

	-- Add path components
	for _, section in ipairs(section_path) do
		local component = ""
		if section.type == constants.SECTION_TYPE.HEADING then
			component = "#" .. section.text:match("^#+%s*(.+)"):gsub("^%s+", ""):gsub("%s+$", "")
		elseif section.type == constants.SECTION_TYPE.LABEL then
			component = ":" .. section.text:match("^([^:]+):"):gsub("^%s+", ""):gsub("%s+$", "")
		elseif section.type == constants.SECTION_TYPE.BOLD_HEADING then
			local text = section.text:match("%*%*([^*]+)%*%*") or section.text:match("__([^_]+)__")
			if text then
				component = "*" .. text:gsub("^%s+", ""):gsub("%s+$", "")
			end
		end

		if component ~= "" then
			table.insert(link_components, "/" .. component)
		end
	end

	local link = "[" .. table.concat(link_components) .. "]"

	vim.notify(string.format("Archived section to %s\nLink: %s", archive_path, link), vim.log.levels.INFO)
end

-- Revert an archived section back to original file
function M.revert_archive(archive_file, section_line)
	-- This would be called from the archive file
	-- Implementation would:
	-- 1. Find the section at current position in archive
	-- 2. Extract it and all subsections
	-- 3. Determine original file from archive filename
	-- 4. Append to original file
	-- 5. Remove from archive

	-- TODO: Implement revert functionality
	vim.notify("Revert functionality not yet implemented", vim.log.levels.WARN)
end

return M
