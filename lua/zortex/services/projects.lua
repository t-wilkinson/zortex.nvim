-- services/projects/init.lua - Project management service using Doc
local M = {}

local Workspace = require("zortex.core.workspace")
local attributes = require("zortex.utils.attributes")
local parser = require("zortex.utils.parser")
local link_resolver = require("zortex.utils.link_resolver")

function M.find_project(section)
	if not section then
		return nil
	end

	-- Walk up section tree to find project (heading)
	local current = section
	while current do
		if current.type == "heading" then
			break
		end
		current = current.parent
	end

	return current
end

function M.get_project(section, doc)
	if not section or section.type ~= "heading" then
		return nil
	end

	local project = {
		name = section.text,
		section = section,
		start_line = section.start_line,
		end_line = section.end_line,
		level = section.level,
		total_tasks = 0,
		completed_tasks = 0,
		link = section:build_link(doc),
		attributes = {},
	}

	-- Parse attributes
	if section.raw_text then
		project.attributes, project.name = attributes.parse_project_attributes(section.raw_text)
	end

	-- Calculate number of completed/total tasks
	local lines = project.section:get_lines(doc.bufnr)
	for _, line in ipairs(lines) do
		local is_task, is_completed = parser.is_task_line(line)
		if is_task then
			project.total_tasks = project.total_tasks + 1
		end

		if is_completed then
			project.completed_tasks = project.completed_tasks + 1
		end
	end

	return project
end

-- Get all projects from document
function M.get_projects_from_document(doc)
	if not doc or not doc.sections then
		return {}
	end

	local projects = {}

	local function extract_projects(section)
		local project = M.to_project(section, doc)
		if not project then
			return nil
		end

		projects[project.name] = project

		-- Process children
		for _, child in ipairs(section.children) do
			extract_projects(child)
		end
	end

	extract_projects(doc.sections)

	return projects
end

-- Get all projects
function M.get_all_projects()
	return M.get_projects_from_document(Workspace.projects())
end

-- Get project by link
function M.get_project_by_link(link_str)
	-- Parse link
	local link_def = parser.parse_link_definition(link_str)
	if not link_def or #link_def.components == 0 then
		return nil
	end

	-- Determine which file to check based on first component
	if link_def.components[1].type == "article" then
		local article_name = link_def.components[1].text
		-- Map article names to files if needed
		-- For now assume Projects article maps to projects file
		if article_name ~= "Projects" then
			return nil
		end
	end

	-- Get document
	local doc = Workspace.projects()

	-- Find section using link
	local section = link_resolver.find_section_by_link(doc, link_def)

	if section and section.type == "heading" then
		local projects = M.get_projects_from_document(doc)
		return projects[section.text]
	end

	return nil
end

return M
