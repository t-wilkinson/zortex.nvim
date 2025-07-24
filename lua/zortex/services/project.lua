-- services/project_service.lua - Project management service using DocumentManager
local M = {}

local EventBus = require("zortex.core.event_bus")
local DocumentManager = require("zortex.core.document_manager")
local buffer_sync = require("zortex.core.buffer_sync")
local parser = require("zortex.utils.parser")
local attributes = require("zortex.utils.attributes")

-- Get all projects from document
function M.get_projects_from_document(doc)
	if not doc or not doc.sections then
		return {}
	end

	local projects = {}

	local function extract_projects(section)
		if section.type == "heading" then
			local project = {
				name = section.text,
				section = section,
				start_line = section.start_line,
				end_line = section.end_line,
				level = section.level,
				tasks = section:get_all_tasks(),
				subprojects = {},
				stats = {
					total_tasks = 0,
					completed_tasks = 0,
					progress = 0,
				},
			}

			-- Parse attributes
			if section.raw_text then
				project.attributes = attributes.parse_project_attributes(section.raw_text)
			end

			-- Calculate stats
			project.stats.total_tasks = #project.tasks
			for _, task in ipairs(project.tasks) do
				if task.completed then
					project.stats.completed_tasks = project.stats.completed_tasks + 1
				end
			end

			if project.stats.total_tasks > 0 then
				project.stats.progress = project.stats.completed_tasks / project.stats.total_tasks
			end

			projects[project.name] = project
		end

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
	local projects_file = config.get("zortex_notes_dir") .. "/projects.zortex"
	local doc = DocumentManager.get_file(projects_file)

	if not doc then
		return {}
	end

	return M.get_projects_from_document(doc)
end

-- Get project at line
function M.get_project_at_line(bufnr, line_num)
	local doc = DocumentManager.get_buffer(bufnr)
	if not doc then
		return nil
	end

	local section = doc:get_section_at_line(line_num)

	-- Walk up to find project (heading)
	while section do
		if section.type == "heading" then
			local projects = M.get_projects_from_document(doc)
			return projects[section.text]
		end
		section = section.parent
	end

	return nil
end

-- Update project progress
function M.update_project_progress(project)
	if not project.section or not project.section.start_line then
		return false
	end

	local bufnr = vim.fn.bufnr(config.get("zortex_notes_dir") .. "/projects.zortex")
	if bufnr < 0 then
		return false
	end

	-- Calculate progress
	local completed = project.stats.completed_tasks
	local total = project.stats.total_tasks

	-- Update attributes
	buffer_sync.update_attributes(bufnr, project.section.start_line, {
		progress = total > 0 and string.format("%d/%d", completed, total) or nil,
		done = (completed == total and total > 0) and os.date("%Y-%m-%d") or nil,
	})

	EventBus.emit("project:progress_updated", {
		project = project,
		completed = completed,
		total = total,
	})

	return true
end

-- Update all projects in document
function M.update_all_project_progress(bufnr)
	local doc = DocumentManager.get_buffer(bufnr)
	if not doc then
		return 0
	end

	local projects = M.get_projects_from_document(doc)
	local updated = 0

	for _, project in pairs(projects) do
		if M.update_project_progress(project) then
			updated = updated + 1
		end
	end

	return updated
end

-- Check if project is completed
function M.is_project_completed(project_name)
	-- Check active projects
	local projects = M.get_all_projects()
	local project = projects[project_name]

	if project then
		return project.attributes and project.attributes.done ~= nil
	end

	-- Check archive
	local archive_file = config.get("zortex_notes_dir") .. "/archive.zortex"
	local archive_doc = DocumentManager.get_file(archive_file)

	if archive_doc then
		local archived = M.get_projects_from_document(archive_doc)
		local archived_project = archived[project_name]
		if archived_project then
			return true
		end
	end

	return false
end

-- Get project statistics
function M.get_all_stats()
	local projects = M.get_all_projects()
	local stats = {
		project_count = vim.tbl_count(projects),
		active_projects = 0,
		completed_projects = 0,
		total_tasks = 0,
		completed_tasks = 0,
		projects_by_priority = {},
		projects_by_importance = {},
	}

	for _, project in pairs(projects) do
		stats.total_tasks = stats.total_tasks + project.stats.total_tasks
		stats.completed_tasks = stats.completed_tasks + project.stats.completed_tasks

		if project.attributes then
			if project.attributes.done then
				stats.completed_projects = stats.completed_projects + 1
			else
				stats.active_projects = stats.active_projects + 1
			end

			-- Count by priority
			local priority = project.attributes.p or "none"
			stats.projects_by_priority[priority] = (stats.projects_by_priority[priority] or 0) + 1

			-- Count by importance
			local importance = project.attributes.i or "none"
			stats.projects_by_importance[importance] = (stats.projects_by_importance[importance] or 0) + 1
		else
			stats.active_projects = stats.active_projects + 1
		end
	end

	-- Add archived count
	local archive_file = config.get("zortex_notes_dir") .. "/archive.zortex"
	local archive_doc = DocumentManager.get_file(archive_file)
	if archive_doc then
		local archived = M.get_projects_from_document(archive_doc)
		stats.archived_projects = vim.tbl_count(archived)
	else
		stats.archived_projects = 0
	end

	return stats
end

return M

