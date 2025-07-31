-- services/projects/progress.lua - Handles project progress updates
local M = {}

local Events = require("zortex.core.event_bus")
local Doc = require("zortex.core.document_manager")
local buffer_sync = require("zortex.core.buffer_sync")
local parser = require("zortex.utils.parser")
local Logger = require("zortex.core.logger")
local link_resolver = require("zortex.utils.link_resolver")

-- Batch update queue
local update_queue = {} -- project_key -> { bufnr, project_link, completed_delta, total_delta }
local update_timer = nil

-- Queue a project update
function M.queue_project_update(bufnr, project_link, completed_delta, total_delta)
	if not bufnr or not project_link then
		Logger.warn("project_progress", "Missing bufnr or project_link", {
			bufnr = bufnr,
			project_link = project_link,
		})
		return
	end

	if not update_queue[project_link] then
		update_queue[project_link] = {
			bufnr = bufnr,
			project_link = project_link,
			completed_delta = 0,
			total_delta = 0,
		}
	end

	update_queue[project_link].completed_delta = update_queue[project_link].completed_delta + completed_delta
	update_queue[project_link].total_delta = update_queue[project_link].total_delta + total_delta

	-- Schedule batch update
	if update_timer then
		vim.fn.timer_stop(update_timer)
	end

	update_timer = vim.fn.timer_start(100, function()
		vim.schedule(function()
			M.process_update_queue()
		end)
	end)
end

-- Process all queued updates
function M.process_update_queue()
	local stop_timer = Logger.start_timer("project_progress.process_queue")

	local queue_size = vim.tbl_count(update_queue)
	if queue_size == 0 then
		stop_timer()
		return
	end

	for key, update in pairs(update_queue) do
		local ok, err = pcall(M.update_single_project, update)
		if not ok then
			Logger.error("project_progress", "Failed to update project", {
				key = key,
				error = err,
			})
		end
	end

	-- Clear queue
	update_queue = {}
	update_timer = nil

	stop_timer({ project_count = queue_size })
end

-- Update a single project
function M.update_single_project(update)
	local doc = Doc.load_buffer(update.bufnr)
	if not doc then
		return false, "Document not found"
	end

	-- Parse link definition
	local link_def = parser.parse_link_definition(update.project_link)
	if not link_def or #link_def.components == 0 then
		return false, "Invalid project link"
	end

	-- Find the project section using link
	local project_section = link_resolver.find_section_by_link(doc, link_def)
	if not project_section then
		return false, "Project section not found"
	end

	-- Correctly calculate progress by using the (stale) document state
	-- as the baseline and applying the queued deltas. This avoids race conditions.
	local all_tasks = project_section:get_all_tasks()
	local total_before_update = #all_tasks
	local completed_before_update = 0
	for _, task in ipairs(all_tasks) do
		if task.completed then
			completed_before_update = completed_before_update + 1
		end
	end

	-- Apply the deltas to get the new, correct state
	local new_total = total_before_update + update.total_delta
	local new_completed = completed_before_update + update.completed_delta

	-- Clamp values for safety
	new_completed = math.max(0, math.min(new_total, new_completed))
	new_total = math.max(0, new_total)

	-- Update attributes
	local attributes = {}

	if new_total > 0 then
		attributes.progress = string.format("%d/%d", new_completed, new_total)

		-- Mark as done if all completed
		if new_completed >= new_total then
			attributes.done = os.date("%Y-%m-%d")
		else
			attributes.done = nil -- Remove done attribute
		end
	else
		attributes.progress = nil
		attributes.done = nil
	end

	-- Queue buffer update
	buffer_sync.update_attributes(update.bufnr, project_section.start_line, attributes)

	Logger.info("project_progress", "Updated project", {
		project = project_section.text,
		progress = attributes.progress,
		done = attributes.done,
	})

	-- Emit event
	Events.emit("project:progress_updated", {
		bufnr = update.bufnr,
		project_name = project_section.text,
		project_link = update.project_link,
		completed = new_completed,
		total = new_total,
	})

	return true
end

-- Initialize project progress tracking
function M.init()
	-- Listen for task completed events
	Events.on("task:completed", function(data)
		if data.xp_context and data.xp_context.project_link and data.xp_context.bufnr then
			M.queue_project_update(
				data.xp_context.bufnr,
				data.xp_context.project_link,
				1, -- completed_delta
				0 -- total_delta (task already exists)
			)
		end
	end, {
		priority = 85,
		name = "project_progress_task_completed",
	})

	-- Listen for task uncompleted events
	Events.on("task:uncompleted", function(data)
		if data.xp_context and data.xp_context.project_link and data.xp_context.bufnr then
			M.queue_project_update(
				data.xp_context.bufnr,
				data.xp_context.project_link,
				-1, -- completed_delta
				0 -- total_delta
			)
		end
	end, {
		priority = 85,
		name = "project_progress_task_uncompleted",
	})

	-- Listen for task created events
	Events.on("task:created", function(data)
		if data.task and data.task.project_link and data.bufnr then
			M.queue_project_update(
				data.bufnr,
				data.task.project_link,
				data.task.completed and 1 or 0, -- completed_delta
				1 -- total_delta
			)
		end
	end, {
		priority = 85,
		name = "project_progress_task_created",
	})
end

-- Force update all projects in a buffer
function M.update_all_projects(bufnr)
	local doc = Doc.get_buffer(bufnr)
	if not doc then
		return 0
	end

	local projects = require("zortex.services.projects").get_projects_from_document(doc)
	local updated = 0

	for _, project in pairs(projects) do
		-- Create link for project
		local project_link = project.section:build_link(doc)
		if project_link then
			-- Count tasks
			local all_tasks = project.section:get_all_tasks()
			local total = #all_tasks
			local completed = 0

			for _, task in ipairs(all_tasks) do
				if task.completed then
					completed = completed + 1
				end
			end

			-- Update attributes
			local attributes = {}
			if total > 0 then
				attributes.progress = string.format("%d/%d", completed, total)
				if completed >= total then
					attributes.done = os.date("%Y-%m-%d")
				else
					attributes.done = nil
				end
			else
				attributes.progress = nil
				attributes.done = nil
			end

			buffer_sync.update_attributes(bufnr, project.section.start_line, attributes)
			updated = updated + 1
		end
	end

	return updated
end

return M
