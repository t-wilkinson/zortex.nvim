-- services/archive_service.lua - Archive service for completed projects and tasks
local M = {}

local EventBus = require("zortex.core.event_bus")
local DocumentManager = require("zortex.core.document_manager")
local buffer_sync = require("zortex.core.buffer_sync")
local constants = require("zortex.constants")
local fs = require("zortex.utils.filesystem")

-- Archive a single project
function M.archive_project(project_name, opts)
	opts = opts or {}

	local projects_file = fs.get_file_path(constants.FILES.PROJECTS)
	local archive_file = fs.get_file_path(constants.FILES.PROJECTS_ARCHIVE)

	-- Get project from active projects
	local projects_doc = DocumentManager.get_file(constants.FILES.PROJECTS)
	if not projects_doc then
		return false, "Projects file not found"
	end

	local project_service = require("zortex.services.project_service")
	local projects = project_service.get_projects_from_document(projects_doc)
	local project = projects[project_name]

	if not project then
		return false, "Project not found"
	end

	-- Get buffer content for the project
	local bufnr = vim.fn.bufnr(projects_file)
	if bufnr < 0 then
		-- Open file to get content
		vim.cmd("edit " .. projects_file)
		bufnr = vim.api.nconfig.get("t_current_buf")()
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, project.start_line - 1, project.end_line, false)

	-- Add archive timestamp
	local archive_header = string.format("# [ARCHIVED %s] %s", os.date("%Y-%m-%d"), project_name)
	lines[1] = archive_header

	-- Append to archive file
	local archive_content = table.concat(lines, "\n")
	local file = io.open(archive_file, "a")
	if file then
		file:write("\n\n" .. archive_content)
		file:close()
	else
		return false, "Could not open archive file"
	end

	-- Remove from projects file
	buffer_sync.update_text(bufnr, project.start_line, project.end_line, {})

	EventBus.emit("project:archived", {
		project_name = project_name,
		archived_at = os.time(),
	})

	return true
end

-- Archive all completed projects
function M.archive_completed_projects(opts)
	opts = opts or {}

	local project_service = require("zortex.services.project")
	local projects = project_service.get_all_projects()
	local archived = {}

	for name, project in pairs(projects) do
		if project.attributes and project.attributes.done then
			local ok, err = M.archive_project(name, opts)
			if ok then
				table.insert(archived, name)
			else
				vim.notify("Failed to archive " .. name .. ": " .. err, vim.log.levels.WARN)
			end
		end
	end

	if #archived > 0 then
		vim.notify(string.format("Archived %d completed projects", #archived), vim.log.levels.INFO)
	end

	return archived
end

-- List all archived projects
function M.list_archives()
	local doc = DocumentManager.get_file(constants.FILES.PROJECTS_ARCHIVE)

	if not doc then
		return {}
	end

	local project_service = require("zortex.services.project")
	return project_service.get_projects_from_document(doc)
end

-- Search in archives
function M.search_archives(query, opts)
	opts = opts or {}

	local archives = M.list_archives()
	local results = {}

	for name, project in pairs(archives) do
		if name:lower():find(query:lower()) then
			table.insert(results, {
				name = name,
				project = project,
				match_type = "name",
			})
		end
	end

	return results
end

-- Restore project from archive
function M.restore_project(project_name, opts)
	-- Implementation would reverse the archive process
	-- For now, just emit event
	EventBus.emit("project:restore_requested", {
		project_name = project_name,
	})

	return false, "Not implemented"
end

return M
