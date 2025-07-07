-- features/archive.lua - Project archiving system for Zortex
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")
local xp = require("zortex.features.xp")
local progress = require("zortex.features.progress")
local constants = require("zortex.constants")

-- =============================================================================
-- Project Completion Check
-- =============================================================================

-- Check if all immediate tasks in a project are completed
local function are_all_tasks_completed(lines, start_idx, end_idx)
	for i = start_idx, end_idx - 1 do
		local line = lines[i]
		local is_task, is_completed = parser.is_task_line(line)
		if is_task and not is_completed then
			return false
		end
	end
	return true
end

-- =============================================================================
-- XP Calculation
-- =============================================================================

-- Calculate XP for a project and all its subprojects
local function calculate_project_xp(lines, start_idx, end_idx, project_heading)
	local total_xp = 0
	local immediate_task_xp = 0
	local subproject_xp = 0

	-- Get the project level and attributes
	local project_line = lines[start_idx]
	local project_level = parser.get_heading_level(project_line)

	-- Parse project attributes
	local project_attrs = parser.parse_project_attributes(project_line)

	-- Check for OKR connection
	local okr_connection = nil -- This would be determined by checking OKR links

	-- Count total tasks for completion percentage calculation
	local total_tasks = 0
	local completed_tasks = 0

	-- First pass: count all immediate tasks
	for i = start_idx + 1, end_idx - 1 do
		local line = lines[i]
		local level = parser.get_heading_level(line)

		-- Only count immediate tasks
		if level == 0 then
			local is_task, is_completed = parser.is_task_line(line)
			if is_task then
				total_tasks = total_tasks + 1
				if is_completed then
					completed_tasks = completed_tasks + 1
				end
			end
		end
	end

	-- Second pass: calculate XP
	local i = start_idx + 1
	while i < end_idx do
		local line = lines[i]

		-- Check if this is a subproject
		local level = parser.get_heading_level(line)

		if level > project_level then
			-- This is a subproject - calculate its XP recursively
			local sub_start, sub_end = buffer.find_section_bounds(lines, i)
			local sub_heading = parser.parse_heading(line)
			if sub_heading then
				local sub_xp = calculate_project_xp(lines, sub_start, sub_end, sub_heading.text)
				subproject_xp = subproject_xp + sub_xp
			end
			i = sub_end
		else
			-- Check if this is a task
			local is_task, is_completed = parser.is_task_line(line)
			if is_task and is_completed then
				-- Create task data for XP calculation
				local task_data = xp.create_task_data(line, project_heading, false)

				-- Create project data with completion info
				local project_data = {
					attrs = project_attrs,
					okr_connection = okr_connection,
					total_tasks = total_tasks,
					completed_tasks = completed_tasks,
				}

				-- Use the new calculation that includes project completion percentage
				immediate_task_xp = immediate_task_xp + xp.calculate_task_xp_in_project(task_data, project_data)
			end
			i = i + 1
		end
	end

	-- If this is a leaf project (no subprojects), the XP is already included in task XP
	-- If it has subprojects, sum task XP and subproject XP
	if subproject_xp > 0 then
		total_xp = immediate_task_xp + subproject_xp
	else
		total_xp = immediate_task_xp
	end

	return total_xp
end

-- Add XP attribute to a heading line
local function add_xp_attribute(heading_line, xp_value)
	-- Remove existing @xp attribute if present
	local cleaned_line = heading_line:gsub(constants.PATTERNS.XP, "")
	return cleaned_line .. string.format(" @xp(%d)", xp_value)
end

-- =============================================================================
-- Archive Tree Management
-- =============================================================================

-- Parse heading path from a project and its ancestors
local function get_heading_path(lines, project_idx)
	local path = {}
	local project_line = lines[project_idx]
	local project_level = parser.get_heading_level(project_line)

	-- Work backwards to find parent headings
	local current_level = project_level
	for i = project_idx, 1, -1 do
		local line = lines[i]
		local level = parser.get_heading_level(line)

		if level > 0 and level < current_level then
			local heading = parser.parse_heading(line)
			if heading then
				local heading_text = heading.text:gsub(constants.PATTERNS.XP, "")
				table.insert(path, 1, heading_text)
				current_level = level
			end
		end
	end

	-- Add the project itself
	local project_heading = parser.parse_heading(project_line)
	if project_heading then
		local project_text = project_heading.text:gsub(constants.PATTERNS.XP, "")
		table.insert(path, project_text)
	end

	return path
end

-- Find the best insertion point for a heading path in the archive
local function find_insertion_point(archive_lines, heading_path)
	local best_match_idx = 2 -- After @XP tag and blank line
	local best_match_depth = 0
	local common_path = {}

	-- Start from line 3 (after @XP tag and blank line)
	local i = 3
	while i <= #archive_lines do
		local line = archive_lines[i]
		local level = parser.get_heading_level(line)

		if level > 0 then
			local heading = parser.parse_heading(line)
			if heading then
				local heading_text = heading.text:gsub(constants.PATTERNS.XP, "")

				-- Check if this matches our path at the appropriate level
				if level <= #heading_path and heading_text == heading_path[level] then
					-- This is a match at this level
					if level > best_match_depth then
						best_match_depth = level
						best_match_idx = i
						common_path = {}
						for k = 1, level do
							common_path[k] = heading_path[k]
						end
					end
				end
			end
		end
		i = i + 1
	end

	-- If we found a common path, find where to insert within that section
	if best_match_depth > 0 then
		local section_level = best_match_depth
		i = best_match_idx + 1

		while i <= #archive_lines do
			local line = archive_lines[i]
			local level = parser.get_heading_level(line)

			-- If we hit a heading at the same level or higher, insert before it
			if level > 0 and level <= section_level then
				return i, common_path
			end
			i = i + 1
		end

		-- Insert at the end of the file
		return #archive_lines + 1, common_path
	end

	-- No common path found, insert at the beginning (after @XP tag)
	return 3, {}
end

-- Update XP values up the tree to the root @XP tag
local function update_xp_bubble(lines)
	-- First pass: calculate XP for all headings from bottom to top
	local xp_values = {}

	for i = #lines, 1, -1 do
		local line = lines[i]
		local level = parser.get_heading_level(line)

		if level > 0 then
			-- Extract existing XP if any
			local existing_xp = tonumber(line:match(constants.PATTERNS.XP)) or 0
			xp_values[i] = existing_xp

			-- Find child headings and sum their XP
			local child_xp = 0
			for j = i + 1, #lines do
				local child_line = lines[j]
				local child_level = parser.get_heading_level(child_line)

				-- If we hit a heading at same or higher level, stop
				if child_level > 0 and child_level <= level then
					break
				end

				-- If this is a direct child heading
				if child_level == level + 1 then
					child_xp = child_xp + (xp_values[j] or 0)
				end
			end

			-- Update the line with new XP value
			if child_xp > 0 or existing_xp > 0 then
				lines[i] = add_xp_attribute(line:gsub(constants.PATTERNS.XP, ""), math.max(child_xp, existing_xp))
			end
		end
	end

	-- Update the root @XP tag
	local total_xp = 0
	for i = 3, #lines do -- Start after @XP tag
		local line = lines[i]
		if line:match("^# ") then -- Top-level headings
			local heading_xp = tonumber(line:match(constants.PATTERNS.XP)) or 0
			total_xp = total_xp + heading_xp
		end
	end

	lines[1] = string.format("@XP(%d)", total_xp)
end

-- =============================================================================
-- Archive Operations
-- =============================================================================

-- Merge a project tree into the archive
local function merge_into_archive(project_lines, heading_path, project_xp)
	local archive_lines = fs.read_archive()
	if not archive_lines then
		vim.notify("Failed to read archive file", vim.log.levels.ERROR)
		return
	end

	-- Find where to insert
	local insert_idx, common_path = find_insertion_point(archive_lines, heading_path)

	-- Prepare the lines to insert
	local lines_to_insert = {}

	-- Add any missing path components
	for i = #common_path + 1, #heading_path do
		local heading_level = i
		local heading_text = heading_path[i]
		local heading_line = string.rep("#", heading_level) .. " " .. heading_text

		-- Add XP attribute if this is the project being archived
		if i == #heading_path then
			heading_line = add_xp_attribute(heading_line, project_xp)
		end

		table.insert(lines_to_insert, heading_line)
	end

	-- Adjust heading levels in project_lines and add them
	local base_level = #heading_path
	for _, line in ipairs(project_lines) do
		local level = parser.get_heading_level(line)

		if level > 0 then
			-- This is a heading - adjust its level
			local heading = parser.parse_heading(line)
			if heading then
				local new_level = base_level + level - 1
				local new_line = string.rep("#", new_level) .. " " .. heading.text
				table.insert(lines_to_insert, new_line)
			end
		else
			-- Not a heading, add as-is
			table.insert(lines_to_insert, line)
		end
	end

	-- Insert the lines
	for i = #lines_to_insert, 1, -1 do
		table.insert(archive_lines, insert_idx, lines_to_insert[i])
	end

	-- Update XP values throughout the tree
	update_xp_bubble(archive_lines)

	-- Write back to file
	fs.write_archive(archive_lines)
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Archive the current project
function M.archive_current_project()
	local bufnr = 0
	local current_line = vim.fn.line(".")
	local lines = buffer.get_lines(bufnr)

	-- Find the project heading
	local project_idx = nil

	-- Check if current line is a heading
	local current_heading = parser.parse_heading(lines[current_line])
	if current_heading then
		project_idx = current_line
	else
		-- Search backwards for a heading
		for i = current_line - 1, 1, -1 do
			if parser.parse_heading(lines[i]) then
				project_idx = i
				break
			end
		end
	end

	if not project_idx then
		vim.notify("No project found at or above current line", vim.log.levels.WARN)
		return
	end

	-- Get project bounds
	local start_idx, end_idx = buffer.find_section_bounds(lines, project_idx)

	-- Check if all immediate tasks are completed
	if not are_all_tasks_completed(lines, start_idx + 1, end_idx) then
		vim.notify("Project has incomplete tasks and cannot be archived", vim.log.levels.WARN)
		return
	end

	-- Get project heading and path
	local project_heading = parser.parse_heading(lines[project_idx])
	local heading_path = get_heading_path(lines, project_idx)

	-- Calculate total XP for the project
	local total_xp = calculate_project_xp(lines, start_idx, end_idx, project_heading.text)

	-- Extract project lines
	local project_lines = {}
	for i = start_idx + 1, end_idx - 1 do
		table.insert(project_lines, lines[i])
	end

	-- Merge into archive
	merge_into_archive(project_lines, heading_path, total_xp)

	-- Remove project from current buffer
	buffer.delete_lines(bufnr, start_idx, end_idx - 1)

	-- Update OKR progress since a project was completed
	progress.update_okr_progress()

	vim.notify(string.format("Archived project '%s' with %d XP", project_heading.text, total_xp), vim.log.levels.INFO)
end

-- Archive all completed projects in the current buffer
function M.archive_all_completed_projects()
	local bufnr = 0
	local lines = buffer.get_lines(bufnr)
	local archived_count = 0
	local total_xp_archived = 0

	-- Work backwards so line numbers don't shift as we delete
	local i = #lines
	while i >= 1 do
		local heading = parser.parse_heading(lines[i])
		if heading then
			local start_idx, end_idx = buffer.find_section_bounds(lines, i)

			-- Check if this is a top-level completed project
			if are_all_tasks_completed(lines, start_idx + 1, end_idx) then
				-- Calculate XP
				local project_xp = calculate_project_xp(lines, start_idx, end_idx, heading.text)
				total_xp_archived = total_xp_archived + project_xp

				-- Get heading path
				local heading_path = get_heading_path(lines, i)

				-- Extract project lines
				local project_lines = {}
				for j = start_idx + 1, end_idx - 1 do
					table.insert(project_lines, lines[j])
				end

				-- Merge into archive
				merge_into_archive(project_lines, heading_path, project_xp)

				-- Remove from current buffer
				buffer.delete_lines(bufnr, start_idx, end_idx - 1)

				archived_count = archived_count + 1

				-- Update lines array after deletion
				lines = buffer.get_lines(bufnr)
				i = start_idx - 1
			else
				i = i - 1
			end
		else
			i = i - 1
		end
	end

	if archived_count > 0 then
		-- Update OKR progress since projects were completed
		progress.update_okr_progress()

		vim.notify(
			string.format("Archived %d projects with total %d XP", archived_count, total_xp_archived),
			vim.log.levels.INFO
		)
	else
		vim.notify("No completed projects found to archive", vim.log.levels.INFO)
	end
end

return M
