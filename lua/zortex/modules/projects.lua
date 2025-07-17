-- modules/projects.lua - Project management with progress tracking
local M = {}

local parser = require("zortex.core.parser")
local buffer = require("zortex.core.buffer")
local fs = require("zortex.core.filesystem")
local tasks = require("zortex.modules.tasks")
local areas = require("zortex.modules.areas")
local xp_projects = require("zortex.xp.projects")
local xp_notifs = require("zortex.xp.notifications")
local attributes = require("zortex.core.attributes")

-- =============================================================================
-- Project Tree Structure
-- =============================================================================

local state = {
	projects = {}, -- Flat list of all projects
	tree = nil, -- Root of project tree
	file_info = {}, -- Article name, tags, etc.
}

-- Create a project node
local function create_project(heading, line_num)
	return {
		name = heading.text,
		level = heading.level,
		line_num = line_num,
		attributes = parser.parse_attributes(heading.text, attributes.project),
		parent = nil,
		children = {},
		tasks = {},
		content = {},
		area_links = {},
	}
end

-- =============================================================================
-- Loading Projects
-- =============================================================================

function M.load()
	local path = fs.get_projects_file()
	if not path or not fs.file_exists(path) then
		return false
	end

	-- Reset state
	state.projects = {}
	state.tree = nil
	state.file_info = {}

	local lines = fs.read_lines(path)
	if not lines then
		return false
	end

	-- Extract file info
	if #lines > 0 then
		state.file_info.article = parser.extract_article_name(lines[1])
		state.file_info.tags = parser.extract_tags_from_lines(lines)
	end

	-- Build project tree
	local project_stack = {}
	local current_project = nil

	for i, line in ipairs(lines) do
		local heading = parser.parse_heading(line)

		if heading then
			-- Create new project
			local project = create_project(heading, i)
			table.insert(state.projects, project)

			-- Get area links for this project
			if i < #lines then
				project.area_links = areas.extract_area_links(lines[i + 1])
			end

			-- Find parent based on heading level
			while #project_stack > 0 and project_stack[#project_stack].level >= heading.level do
				table.remove(project_stack)
			end

			-- Set parent-child relationships
			if #project_stack > 0 then
				local parent = project_stack[#project_stack]
				project.parent = parent
				table.insert(parent.children, project)
			else
				-- Top-level project
				if not state.tree then
					state.tree = { children = {} }
				end
				table.insert(state.tree.children, project)
			end

			-- Update stack
			table.insert(project_stack, project)
			current_project = project
		elseif current_project then
			-- Add content to current project
			table.insert(current_project.content, {
				text = line,
				line_num = i,
			})
		end
	end

	return true
end

-- =============================================================================
-- Progress Tracking
-- =============================================================================

function M.update_progress(bufnr)
	bufnr = bufnr or 0
	local lines = buffer.get_lines(bufnr)
	local modified = false

	-- First ensure all tasks have IDs
	if tasks.ensure_task_ids(bufnr) then
		modified = true
		lines = buffer.get_lines(bufnr)
	end

	-- Track XP changes for notification
	local total_xp_changes = {}
	local projects_completed = {}

	-- Process each project
	local headings = buffer.get_all_headings(bufnr)

	for i, heading_info in ipairs(headings) do
		local lnum = heading_info.lnum
		local level = heading_info.level
		local project_name = heading_info.text

		-- Find section bounds
		local end_idx = #lines + 1
		for j = i + 1, #headings do
			if headings[j].level <= level then
				end_idx = headings[j].lnum
				break
			end
		end

		-- Get area links
		local area_links = {}
		if lnum < #lines then
			area_links = areas.extract_area_links(lines[lnum + 1])
		end

		-- Process tasks in this project
		local project_tasks, xp_changes = tasks.process_project_tasks(lines, project_name, lnum, end_idx, area_links)

		-- Aggregate XP changes
		for _, change in ipairs(xp_changes) do
			table.insert(total_xp_changes, change)
		end

		-- Update project heading with progress
		local completed_count = 0
		local total_count = #project_tasks

		for _, task in ipairs(project_tasks) do
			if task.completed then
				completed_count = completed_count + 1
			end
		end

		local old_line = lines[lnum]
		local new_line =
			parser.update_attribute(old_line, "progress", string.format("%d/%d", completed_count, total_count))

		-- Check for project completion
		local was_done = parser.extract_attribute(old_line, "done") ~= nil
		local is_done = total_count > 0 and completed_count == total_count

		if is_done and not was_done then
			new_line = parser.update_attribute(new_line, "done", os.date("%Y-%m-%d"))

			-- Calculate total project XP
			local total_project_xp = 0
			for _, task in ipairs(project_tasks) do
				total_project_xp = total_project_xp + task.xp_awarded
			end

			-- Mark project as completed
			if #area_links > 0 then
				xp_projects.complete_project(project_name, total_project_xp, area_links)
			end

			table.insert(projects_completed, {
				name = project_name,
				xp = total_project_xp,
			})
		elseif not is_done and was_done then
			new_line = parser.remove_attribute(new_line, "done")
		end

		if new_line ~= old_line then
			lines[lnum] = new_line
			modified = true
		end
	end

	-- Save changes
	if modified then
		buffer.set_lines(bufnr, 0, -1, lines)
	end

	-- Show notification if XP changed
	if #total_xp_changes > 0 then
		xp_notifs.notify_progress_update(total_xp_changes, projects_completed)
	end

	return modified
end

-- =============================================================================
-- Query Functions
-- =============================================================================

function M.get_all_projects()
	return state.projects
end

function M.get_project_tree()
	return state.tree
end

function M.get_project_path(project)
	local parts = {}
	local p = project
	while p do
		-- Strip attributes from name for display
		local clean_name = parser.parse_attributes(p.name)
		table.insert(parts, 1, clean_name)
		p = p.parent
	end
	return table.concat(parts, " › ")
end

function M.find_project(name)
	local name_lower = name:lower()
	for _, project in ipairs(state.projects) do
		local clean_name = parser.parse_attributes(project.name)
		if clean_name:lower() == name_lower then
			return project
		end
	end
	return nil
end

function M.get_project_at_line(line_num)
	local best_project = nil
	for _, project in ipairs(state.projects) do
		if project.line_num <= line_num then
			if not best_project or project.line_num > best_project.line_num then
				best_project = project
			end
		end
	end
	return best_project
end

-- =============================================================================
-- Project Statistics
-- =============================================================================

function M.get_project_stats(project)
	-- Get tasks from task store
	local project_tasks = require("zortex.models.task").get_project_tasks(project.name)

	local stats = {
		total_tasks = #project_tasks,
		completed_tasks = 0,
		total_xp = 0,
		completion_rate = 0,
		has_children = #project.children > 0,
		child_count = #project.children,
	}

	for _, task in ipairs(project_tasks) do
		if task.completed then
			stats.completed_tasks = stats.completed_tasks + 1
			stats.total_xp = stats.total_xp + task.xp_awarded
		end
	end

	if stats.total_tasks > 0 then
		stats.completion_rate = stats.completed_tasks / stats.total_tasks
	end

	return stats
end

function M.get_all_stats()
	local total_stats = {
		project_count = #state.projects,
		total_tasks = 0,
		completed_tasks = 0,
		total_xp = 0,
		projects_by_level = {},
	}

	for _, project in ipairs(state.projects) do
		local stats = M.get_project_stats(project)
		total_stats.total_tasks = total_stats.total_tasks + stats.total_tasks
		total_stats.completed_tasks = total_stats.completed_tasks + stats.completed_tasks
		total_stats.total_xp = total_stats.total_xp + stats.total_xp

		-- Count by level
		local level = project.level
		total_stats.projects_by_level[level] = (total_stats.projects_by_level[level] or 0) + 1
	end

	return total_stats
end

return M

