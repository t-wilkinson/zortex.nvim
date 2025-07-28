-- services/projects/progress.lua - Handles project progress updates
local M = {}

local EventBus = require("zortex.core.event_bus")
local DocumentManager = require("zortex.core.document_manager")
local buffer_sync = require("zortex.core.buffer_sync")
local parser = require("zortex.utils.parser")
local Logger = require("zortex.core.logger")

-- Batch update queue
local update_queue = {} -- project_key -> { bufnr, project_link, completed_delta, total_delta }
local update_timer = nil

-- Queue a project update
function M.queue_project_update(bufnr, project_link, completed_delta, total_delta)
	if not bufnr or not project_link then
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

	stop_timer({ project_count = vim.tbl_count(update_queue) })
end

-- Update a single project
function M.update_single_project(update)
	local doc = DocumentManager.get_buffer(update.bufnr)
	if not doc then
		return false, "Document not found"
	end

	-- Parse link definition
	local link_def = parser.parse_link_definition(update.project_link)
	if not link_def or #link_def.components == 0 then
		return false, "Invalid project link"
	end

	-- Find the project section using link
	local project_section = M.find_section_by_link(doc, link_def)
	if not project_section then
		return false, "Project section not found"
	end

	-- Get current progress from section
	local current_progress = nil
	if project_section.raw_text then
		local progress_str = parser.extract_attribute(project_section.raw_text, "progress")
		if progress_str then
			local completed, total = progress_str:match("(%d+)/(%d+)")
			if completed and total then
				current_progress = {
					completed = tonumber(completed),
					total = tonumber(total),
				}
			end
		end
	end

	-- Calculate new progress
	local new_completed = (current_progress and current_progress.completed or 0) + update.completed_delta
	local new_total = (current_progress and current_progress.total or 0) + update.total_delta

	-- Ensure non-negative
	new_completed = math.max(0, new_completed)
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
		old_progress = current_progress,
		new_progress = { completed = new_completed, total = new_total },
	})

	-- Emit event
	EventBus.emit("project:progress_updated", {
		bufnr = update.bufnr,
		project_name = project_section.text,
		project_link = update.project_link,
		completed = new_completed,
		total = new_total,
		completed_delta = update.completed_delta,
		total_delta = update.total_delta,
	})

	return true
end

-- Find section in document using parsed link
function M.find_section_by_link(doc, link_def)
	if not doc.sections or not link_def.components then
		return nil
	end

	local current_section = doc.sections

	-- Navigate through link components
	for i, component in ipairs(link_def.components) do
		local found = false

		-- Handle different component types
		if component.type == "article" then
			-- For article, check if it matches document's article name
			if i == 1 and doc.sections.article_names then
				for _, name in ipairs(doc.sections.article_names) do
					if name == component.text then
						found = true
						break
					end
				end
			end
		elseif component.type == "heading" then
			-- Search children for matching heading
			for _, child in ipairs(current_section.children) do
				if child.type == "heading" and child.text == component.text then
					current_section = child
					found = true
					break
				end
			end
		elseif component.type == "label" then
			-- Search children for matching label
			for _, child in ipairs(current_section.children) do
				if child.type == "label" and child.text == component.text then
					current_section = child
					found = true
					break
				end
			end
		end

		if not found then
			return nil
		end
	end

	return current_section
end

-- Build a link to a project section
function M.build_project_link(doc, section)
	if not section then
		return nil
	end

	local components = {}

	-- Walk up the section tree to build path
	local path = section:get_path()
	table.insert(path, section)

	for _, s in ipairs(path) do
		if s.type == "heading" then
			table.insert(components, "#" .. s.text)
		elseif s.type == "label" then
			table.insert(components, ":" .. s.text)
		elseif s.type == "article" and s.text and s.text ~= "Document Root" then
			table.insert(components, s.text)
		end
	end

	if #components == 0 then
		return nil
	end

	return "[" .. table.concat(components, "/") .. "]"
end

-- Initialize project progress tracking
function M.init()
	-- Listen for task completed events
	EventBus.on("task:completed", function(data)
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
	EventBus.on("task:uncompleted", function(data)
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
	EventBus.on("task:created", function(data)
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
	local doc = DocumentManager.get_buffer(bufnr)
	if not doc then
		return 0
	end

	local projects = require("zortex.services.projects").get_projects_from_document(doc)
	local updated = 0

	for _, project in pairs(projects) do
		-- Create link for project
		local project_link = M.build_project_link(doc, project.section)
		if project_link then
			local update = {
				bufnr = bufnr,
				project_link = project_link,
				completed_delta = 0,
				total_delta = 0,
			}

			local ok = M.update_single_project(update)
			if ok then
				updated = updated + 1
			end
		end
	end

	return updated
end

return M
