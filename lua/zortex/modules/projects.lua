-- modules/projects.lua - Project structure parser for Zortex
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")

-- =============================================================================
-- Data Structure
-- =============================================================================

-- Project structure:
-- {
--   name = "Project Name",
--   level = 2,  -- heading level
--   line_num = 42,
--   attributes = { ... },  -- parsed attributes
--   parent = <parent_project>,
--   children = { <child_projects> },
--   tasks = { <tasks> },
--   content = { <other_content> }
-- }

-- =============================================================================
-- State
-- =============================================================================

local state = {
	projects = {}, -- Flat list of all projects
	tree = nil, -- Root of project tree
	file_info = {}, -- Article name, tags, etc.
}

-- =============================================================================
-- Helper Functions
-- =============================================================================

-- Strip attribute from a heading/project name.
local function strip_attributes(text)
	if not text then
		return ""
	end
	-- Remove @word(...) first, then standalone @word
	text = text:gsub("@%w+%b()", "")
	text = text:gsub("@%w+", "")
	return parser.trim(text)
end

-- Recursively build the full heading path for a project
function M.get_project_path(project)
	local parts = {}
	local p = project
	while p do
		table.insert(parts, 1, strip_attributes(p.name)) -- prepend so order is root ➜ leaf
		p = p.parent
	end
	return table.concat(parts, " ‣ ") -- →·◦
end

-- =============================================================================
-- Project Tree Building
-- =============================================================================

local function create_project(heading, line_num)
	return {
		name = heading.text,
		level = heading.level,
		line_num = line_num,
		attributes = parser.parse_project_attributes(heading.raw),
		parent = nil,
		children = {},
		tasks = {},
		content = {},
	}
end

local function parse_task_line(line, line_num)
	local is_task, is_completed = parser.is_task_line(line)
	if not is_task then
		return nil
	end

	local task_text = parser.get_task_text(line)
	if not task_text then
		return nil
	end

	return {
		raw_text = line,
		display_text = task_text,
		completed = is_completed,
		status = parser.parse_task_status(line),
		attributes = parser.parse_task_attributes(task_text),
		line_num = line_num,
	}
end

-- =============================================================================
-- Loading and Parsing
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

	-- Extract file info (article name, tags)
	if #lines > 0 then
		state.file_info.article = parser.extract_article_name(lines[1])
		state.file_info.tags = parser.extract_tags_from_lines(lines)
	end

	-- Build project tree
	local project_stack = {} -- Stack to track parent projects
	local current_project = nil

	for i, line in ipairs(lines) do
		local heading = parser.parse_heading(line)

		if heading then
			-- Create new project
			local project = create_project(heading, i)
			table.insert(state.projects, project)

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
			-- Parse content under current project
			local task = parse_task_line(line, i)
			if task then
				table.insert(current_project.tasks, task)
			elseif line:match("%S") then -- Non-empty line
				table.insert(current_project.content, {
					text = line,
					line_num = i,
					type = parser.detect_section_type(line),
				})
			end
		end
	end

	return true
end

-- =============================================================================
-- Query Functions
-- =============================================================================

-- Get all projects (flat list)
function M.get_all_projects()
	return state.projects
end

-- Get project tree
function M.get_project_tree()
	return state.tree
end

-- Get projects at a specific level
function M.get_projects_at_level(level)
	local projects = {}
	for _, project in ipairs(state.projects) do
		if project.level == level then
			table.insert(projects, project)
		end
	end
	return projects
end

-- Get all tasks across all projects
function M.get_all_tasks()
	local tasks = {}
	for _, project in ipairs(state.projects) do
		for _, task in ipairs(project.tasks) do
			-- Add project reference to task
			local task_with_project = vim.tbl_extend("force", task, {
				project = project.name,
				project_level = project.level,
			})
			table.insert(tasks, task_with_project)
		end
	end
	return tasks
end

-- Get incomplete tasks
function M.get_incomplete_tasks()
	local tasks = {}
	for _, project in ipairs(state.projects) do
		for _, task in ipairs(project.tasks) do
			if not task.completed then
				local task_with_project = vim.tbl_extend("force", task, {
					project = project.name,
					project_level = project.level,
				})
				table.insert(tasks, task_with_project)
			end
		end
	end
	return tasks
end

-- Find project by name
function M.find_project(name)
	local name_lower = name:lower()
	for _, project in ipairs(state.projects) do
		if project.name:lower() == name_lower then
			return project
		end
	end
	return nil
end

-- Get project at line number
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

-- Get file info
function M.get_file_info()
	return state.file_info
end

-- =============================================================================
-- Project Statistics
-- =============================================================================

function M.get_project_stats(project)
	local stats = {
		total_tasks = #project.tasks,
		completed_tasks = 0,
		completion_rate = 0,
		has_children = #project.children > 0,
		child_count = #project.children,
	}

	-- Count completed tasks
	for _, task in ipairs(project.tasks) do
		if task.completed then
			stats.completed_tasks = stats.completed_tasks + 1
		end
	end

	-- Calculate completion rate
	if stats.total_tasks > 0 then
		stats.completion_rate = stats.completed_tasks / stats.total_tasks
	end

	return stats
end

-- Get stats for all projects
function M.get_all_stats()
	local total_stats = {
		project_count = #state.projects,
		total_tasks = 0,
		completed_tasks = 0,
		projects_by_level = {},
	}

	for _, project in ipairs(state.projects) do
		local stats = M.get_project_stats(project)
		total_stats.total_tasks = total_stats.total_tasks + stats.total_tasks
		total_stats.completed_tasks = total_stats.completed_tasks + stats.completed_tasks

		-- Count by level
		local level = project.level
		total_stats.projects_by_level[level] = (total_stats.projects_by_level[level] or 0) + 1
	end

	return total_stats
end

-- =============================================================================
-- Integration Helpers
-- =============================================================================

-- Check if a project is referenced in OKRs
function M.is_project_in_okr(project_name)
	local okr_file = fs.get_okr_file()
	if not okr_file or not fs.file_exists(okr_file) then
		return false
	end

	local lines = fs.read_lines(okr_file)
	if not lines then
		return false
	end

	for _, line in ipairs(lines) do
		if parser.is_project_linked(line, project_name) then
			return true
		end
	end

	return false
end

-- Get projects with specific attributes
function M.find_projects_with_attribute(attr_name, attr_value)
	local matches = {}
	for _, project in ipairs(state.projects) do
		if attr_value then
			-- Match specific value
			if project.attributes[attr_name] == attr_value then
				table.insert(matches, project)
			end
		else
			-- Just check if attribute exists
			if project.attributes[attr_name] ~= nil then
				table.insert(matches, project)
			end
		end
	end
	return matches
end

return M
