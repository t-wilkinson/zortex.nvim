-- modules/archive.lua - Project archiving system for Zortex
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")
local attributes = require("zortex.core.attributes")
local task_tracker = require("zortex.modules.task_tracker")
local xp = require("zortex.modules.xp")
local constants = require("zortex.constants")

-- =============================================================================
-- Path Building
-- =============================================================================

-- Build heading path from root to given line
local function build_heading_path(lines, target_idx)
	local path = {}
	local target_level = parser.get_heading_level(lines[target_idx])

	-- Work backwards to find parent headings
	local current_level = target_level
	for i = target_idx, 1, -1 do
		local line = lines[i]
		local level = parser.get_heading_level(line)

		if level > 0 and level < current_level then
			-- This is a parent heading
			local heading = parser.parse_heading(line)
			if heading then
				-- Strip attributes to get clean heading text
				local clean_text = attributes.strip_project_attributes(heading.text)
				table.insert(path, 1, clean_text)
				current_level = level

				-- Stop at level 1 (top-level heading)
				if level == 1 then
					break
				end
			end
		end
	end

	-- Add the target heading itself
	local target_heading = parser.parse_heading(lines[target_idx])
	if target_heading then
		local clean_text = attributes.strip_project_attributes(target_heading.text)
		table.insert(path, clean_text)
	end

	return path
end

-- =============================================================================
-- Archive Tree Navigation
-- =============================================================================

-- Find the best insertion point in archive for given path
local function find_archive_insertion_point(archive_lines, path)
	if #path == 0 then
		return 1, 0
	end

	local best_match_line = 1
	local best_match_depth = 0

	-- Track current position in path matching
	local current_depth = 0

	for i = 1, #archive_lines do
		local line = archive_lines[i]
		local level = parser.get_heading_level(line)

		if level > 0 then
			-- Check if this heading matches our path at the current depth
			if level <= #path then
				local heading = parser.parse_heading(line)
				if heading then
					local clean_text = attributes.strip_project_attributes(heading.text)

					-- Check if this matches our path at this level
					if level <= current_depth + 1 and clean_text == path[level] then
						-- We found a match
						if level > best_match_depth then
							best_match_depth = level
							best_match_line = i
							current_depth = level
						end
					elseif level <= current_depth then
						-- We've exited the matching section
						if current_depth == best_match_depth and current_depth > 0 then
							-- Return position after the last match's section
							return i, best_match_depth
						end
						-- Reset tracking for new section
						current_depth = 0
					end
				end
			end
		end
	end

	-- If we matched something, insert at end of file
	if best_match_depth > 0 then
		return #archive_lines + 1, best_match_depth
	end

	-- No matches, insert at beginning after any metadata
	local insert_line = 1
	for i = 1, #archive_lines do
		if parser.get_heading_level(archive_lines[i]) > 0 then
			return i, 0
		end
		-- Skip metadata lines (dates, tags, etc)
		if
			not archive_lines[i]:match("^%s*$")
			and not archive_lines[i]:match("^@")
			and not archive_lines[i]:match("^%d%d%d%d%-%d%d%-%d%d")
		then
			return i, 0
		end
	end

	return #archive_lines + 1, 0
end

-- =============================================================================
-- Task Archiving
-- =============================================================================

-- Archive tasks to .z/archive.task_state.json
local function archive_tasks_to_json(task_ids)
	if #task_ids == 0 then
		return
	end

	-- Load current archive state
	local archive_file = fs.get_file_path(constants.FILES.ARCHIVE_TASK_STATE)
	local archive_data = {}

	if archive_file and fs.file_exists(archive_file) then
		archive_data = fs.read_json(archive_file) or {}
	end

	-- Get current season
	local season_status = xp.get_season_status()
	local season_key = season_status.active and season_status.current_season.name or "no_season"

	-- Initialize season data if needed
	if not archive_data[season_key] then
		archive_data[season_key] = {
			tasks = {},
			archived_at = os.date("%Y-%m-%d %H:%M:%S"),
		}
	end

	-- Archive each task
	task_tracker.load_state()
	for _, id in ipairs(task_ids) do
		local task = task_tracker.get_task(id)
		if task then
			-- Store task data
			archive_data[season_key].tasks[id] = {
				id = id,
				project = task.project,
				completed = task.completed,
				created_at = task.created_at,
				completed_at = task.completed_at,
				archived_at = os.time(),
				attributes = task.attributes or {},
			}
		end
	end

	-- Save archive data
	if archive_file then
		fs.ensure_directory(archive_file)
		fs.write_json(archive_file, archive_data)
	end
end

-- Process tasks for archiving - remove @id
local function process_task_line_for_archive(line, task_id)
	if not task_id then
		return line
	end

	-- Get task data
	local task = task_tracker.get_task(task_id)
	if not task then
		return line
	end

	-- Remove @id attribute
	return attributes.Param.remove_attribute(line, "id")
end

-- Collect all task IDs from a section (including subsections)
local function collect_task_ids(lines, start_idx, end_idx)
	local task_ids = {}

	for i = start_idx, end_idx - 1 do
		local line = lines[i]
		-- Check both the line itself and the text part of headings
		local text_to_check = line
		local heading = parser.parse_heading(line)
		if heading then
			text_to_check = heading.text
		end

		local is_task = parser.is_task_line(text_to_check)
		if is_task then
			local id = attributes.extract_task_id(text_to_check)
			if id then
				table.insert(task_ids, id)
			end
		end
	end

	return task_ids
end

-- =============================================================================
-- Archive Merging
-- =============================================================================

-- Merge project content into archive
local function merge_project_into_archive(project_lines, path, archive_lines, insert_pos, match_depth)
	local lines_to_insert = {}

	-- Calculate how many path components we need to add
	local components_to_add = #path - match_depth

	-- Add missing path components as headings
	for i = match_depth + 1, #path do
		local heading_level = i
		local heading_text = path[i]
		local heading_line = string.rep("#", heading_level) .. " " .. heading_text
		table.insert(lines_to_insert, heading_line)
	end

	-- Process project content
	-- Base level is the level of the project heading in the archive
	local base_level = #path

	for _, line in ipairs(project_lines) do
		local level = parser.get_heading_level(line)

		if level > 0 then
			-- It's a heading. Re-level it and process its text for tasks.
			local new_level = base_level + level - 1
			local heading = parser.parse_heading(line)
			if heading then
				local text_part = heading.text
				-- Check if the text of the heading is ALSO a task
				if parser.is_task_line(text_part) then
					local task_id = attributes.extract_task_id(text_part)
					text_part = process_task_line_for_archive(text_part, task_id)
				end
				local new_line = string.rep("#", new_level) .. " " .. text_part
				table.insert(lines_to_insert, new_line)
			else
				-- Keep malformed headings as-is to prevent data loss.
				table.insert(lines_to_insert, line)
			end
		else
			-- It's not a heading, process as a potential task or plain text.
			local is_task = parser.is_task_line(line)
			if is_task then
				local task_id = attributes.extract_task_id(line)
				local processed_line = process_task_line_for_archive(line, task_id)
				table.insert(lines_to_insert, processed_line)
			else
				-- Keep other lines as-is
				table.insert(lines_to_insert, line)
			end
		end
	end

	-- Insert lines into archive
	for i = #lines_to_insert, 1, -1 do
		table.insert(archive_lines, insert_pos, lines_to_insert[i])
	end

	return archive_lines
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Archive the current project
function M.archive_current_project()
	local bufnr = 0
	local current_line = vim.fn.line(".")
	local lines = buffer.get_lines(bufnr)

	-- Find project heading
	local project_idx = nil
	if parser.get_heading_level(lines[current_line]) > 0 then
		project_idx = current_line
	else
		-- Search backwards for heading
		for i = current_line - 1, 1, -1 do
			if parser.get_heading_level(lines[i]) > 0 then
				project_idx = i
				break
			end
		end
	end

	if not project_idx then
		vim.notify("No project found at cursor position", vim.log.levels.WARN)
		return
	end

	-- Get project bounds
	local start_idx, end_idx = buffer.find_section_bounds(lines, project_idx)

	-- Build path to project
	local path = build_heading_path(lines, project_idx)
	local project_name = path[#path] or "Unknown Project"

	-- Collect all task IDs before archiving
	local task_ids = collect_task_ids(lines, start_idx, end_idx)

	-- Extract project content (excluding the heading line)
	local project_lines = {}
	for i = start_idx + 1, end_idx - 1 do
		table.insert(project_lines, lines[i])
	end

	-- Read archive file
	local archive_lines = fs.read_archive()
	if not archive_lines then
		vim.notify("Failed to read archive file", vim.log.levels.ERROR)
		return
	end

	-- Find insertion point
	local insert_pos, match_depth = find_archive_insertion_point(archive_lines, path)

	-- Merge into archive
	archive_lines = merge_project_into_archive(project_lines, path, archive_lines, insert_pos, match_depth)

	-- Write back archive
	fs.write_archive(archive_lines)

	-- Archive task data to JSON
	archive_tasks_to_json(task_ids)

	-- Remove tasks from active tracker
	task_tracker.load_state()
	for _, id in ipairs(task_ids) do
		task_tracker.remove_task(id)
	end
	task_tracker.save_state()

	-- Remove project from current buffer
	buffer.delete_lines(bufnr, start_idx, end_idx)

	vim.notify(string.format("Archived project '%s' with %d tasks", project_name, #task_ids), vim.log.levels.INFO)
end

-- Archive all completed projects
function M.archive_all_completed_projects()
	local bufnr = 0
	local lines = buffer.get_lines(bufnr)
	local archived_count = 0
	local total_tasks_archived = 0

	-- Work backwards to avoid line number shifts
	local i = #lines
	while i >= 1 do
		local heading = parser.parse_heading(lines[i])
		if heading then
			-- Check if project is marked as done
			if attributes.was_done(lines[i]) then
				local start_idx, end_idx = buffer.find_section_bounds(lines, i)

				-- Build path
				local path = build_heading_path(lines, i)
				local project_name = path[#path] or "Unknown Project"

				-- Collect task IDs
				local task_ids = collect_task_ids(lines, start_idx, end_idx)
				total_tasks_archived = total_tasks_archived + #task_ids

				-- Extract project content
				local project_lines = {}
				for j = start_idx + 1, end_idx - 1 do
					table.insert(project_lines, lines[j])
				end

				-- Read archive
				local archive_lines = fs.read_archive()
				if archive_lines then
					-- Find insertion point and merge
					local insert_pos, match_depth = find_archive_insertion_point(archive_lines, path)
					archive_lines =
						merge_project_into_archive(project_lines, path, archive_lines, insert_pos, match_depth)
					fs.write_archive(archive_lines)

					-- Archive task data
					archive_tasks_to_json(task_ids)

					-- Remove tasks from tracker
					task_tracker.load_state()
					for _, id in ipairs(task_ids) do
						task_tracker.remove_task(id)
					end
					task_tracker.save_state()

					-- Remove from buffer
					buffer.delete_lines(bufnr, start_idx, end_idx)

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
		else
			i = i - 1
		end
	end

	if archived_count > 0 then
		vim.notify(
			string.format("Archived %d projects with %d total tasks", archived_count, total_tasks_archived),
			vim.log.levels.INFO
		)
	else
		vim.notify("No completed projects found to archive", vim.log.levels.INFO)
	end
end

return M
