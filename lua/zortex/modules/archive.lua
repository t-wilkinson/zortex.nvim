-- modules/archive.lua - Project archiving system for Zortex
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")
local progress = require("zortex.modules.progress")
local attributes = require("zortex.core.attributes")
local task_tracker = require("zortex.modules.task_tracker")

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

-- Calculate XP for a project (only the project's own completion bonus)
local function calculate_project_completion_xp(project_heading)
	return 0
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
				local heading_text = attributes.strip_project_attributes(heading.text)
				table.insert(path, 1, heading_text)
				current_level = level
			end
		end
	end

	-- Add the project itself
	local project_heading = parser.parse_heading(project_line)
	if project_heading then
		local project_text = attributes.strip_project_attributes(project_heading.text)
		table.insert(path, project_text)
	end

	return path
end

-- Find the best insertion point for a heading path in the archive
local function find_insertion_point(archive_lines, heading_path)
	local best_match_idx = nil
	local best_match_depth = 0
	local common_path = {}

	-- Find the first heading in the file (skip metadata)
	local first_heading_idx = nil
	for i = 1, #archive_lines do
		if parser.get_heading_level(archive_lines[i]) > 0 then
			first_heading_idx = i
			break
		end
	end

	-- If no headings found, insert after all metadata
	if not first_heading_idx then
		return #archive_lines + 1, {}
	end

	-- Start searching from first heading
	local i = first_heading_idx
	while i <= #archive_lines do
		local line = archive_lines[i]
		local level = parser.get_heading_level(line)

		if level > 0 then
			local heading = parser.parse_heading(line)
			if heading then
				local heading_text = attributes.strip_project_attributes(heading.text)

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

	-- No common path found, insert before first heading
	return first_heading_idx, {}
end

-- Clean up task tracker after archiving
local function cleanup_archived_tasks(project_name, lines, start_idx, end_idx)
	-- Get all task IDs from this project section
	local task_ids = {}

	-- Recursively collect task IDs including from subprojects
	local function collect_task_ids(start, end_pos, current_level)
		for i = start, end_pos - 1 do
			local line = lines[i]
			local heading_level = parser.get_heading_level(line)

			if heading_level > 0 then
				if heading_level <= current_level then
					-- Exit this section
					return i
				else
					-- Recurse into subsection
					local sub_end = end_pos
					for j = i + 1, end_pos - 1 do
						local sub_level = parser.get_heading_level(lines[j])
						if sub_level > 0 and sub_level <= heading_level then
							sub_end = j
							break
						end
					end
					i = collect_task_ids(i + 1, sub_end, heading_level) - 1
				end
			else
				local is_task = parser.is_task_line(line)
				if is_task then
					local id = attributes.extract_task_id(line)
					if id then
						table.insert(task_ids, id)
					end
				end
			end
		end
		return end_pos
	end

	collect_task_ids(start_idx + 1, end_idx, parser.get_heading_level(lines[start_idx]))

	-- Remove tasks from tracker
	task_tracker.load_state()
	for _, id in ipairs(task_ids) do
		task_tracker.remove_task(id)
	end
	task_tracker.save_state()
end

-- =============================================================================
-- Archive Operations
-- =============================================================================

-- Merge a project tree into the archive with proper XP attribution
local function merge_into_archive(project_lines, heading_path, project_completion_xp)
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

		-- Add project completion XP to the main project heading only
		if i == #heading_path and project_completion_xp > 0 then
			heading_line = attributes.update_xp_attribute(heading_line, project_completion_xp)
		end

		table.insert(lines_to_insert, heading_line)
	end

	-- Load task tracker to get XP data
	task_tracker.load_state()

	-- Adjust heading levels and process tasks
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
			-- Check if it's a task
			local is_task = parser.is_task_line(line)
			if is_task then
				local id = attributes.extract_task_id(line)
				local task_line = line

				-- Remove @id attribute
				task_line = attributes.remove_attribute(task_line, "id")

				-- Add @xp attribute if task had XP
				if id then
					local task = task_tracker.get_task(id)
					if task and task.xp_awarded and task.xp_awarded > 0 then
						task_line = attributes.update_xp_attribute(task_line, task.xp_awarded)
					end
				end

				table.insert(lines_to_insert, task_line)
			else
				-- Other content
				table.insert(lines_to_insert, line)
			end
		end
	end

	-- Insert the lines
	for i = #lines_to_insert, 1, -1 do
		table.insert(archive_lines, insert_idx, lines_to_insert[i])
	end

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
	vim.notify("Project has incomplete tasks. Still archiving...", vim.log.levels.WARN)

	-- Get project heading and path
	local project_heading = parser.parse_heading(lines[project_idx])
	local heading_path = get_heading_path(lines, project_idx)

	-- Calculate total XP for the project
	local project_xp = calculate_project_completion_xp(project_heading)

	-- Get project name for cleanup
	local project_name = attributes.strip_project_attributes(project_heading.text)

	-- Extract project lines
	local project_lines = {}
	for i = start_idx + 1, end_idx - 1 do
		table.insert(project_lines, lines[i])
	end

	-- Merge into archive
	merge_into_archive(project_lines, heading_path, project_xp)

	-- Clean up task tracker data
	cleanup_archived_tasks(project_name, lines, start_idx, end_idx)

	-- Remove project from current buffer
	buffer.delete_lines(bufnr, start_idx, end_idx)

	-- Update OKR progress since a project was completed
	progress.update_okr_progress()

	vim.notify(string.format("Archived project '%s' with %d XP", project_heading.text, project_xp), vim.log.levels.INFO)
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
