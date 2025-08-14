-- services/task.lua - Stateless service for task operations using workspace
local M = {}

local Events = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local parser = require("zortex.utils.parser")
local workspace = require("zortex.core.workspace")
local attributes = require("zortex.utils.attributes")

-- =============================================================================
-- ID Generation
-- =============================================================================

local CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local BASE = #CHARS
local TIME_MOD = 131072
local RAND_MAX = 4096

-- Generate unique task ID
local function generate_task_id()
	local function generate_base_id()
		local time_part = vim.loop.hrtime() % TIME_MOD
		local rand_part = math.random(0, RAND_MAX - 1)
		local id_num = time_part * RAND_MAX + rand_part

		local out = {}
		for i = 5, 1, -1 do
			local idx = (id_num % BASE) + 1
			out[i] = CHARS:sub(idx, idx)
			id_num = math.floor(id_num / BASE)
		end
		return table.concat(out)
	end

	-- Generate and ensure uniqueness by checking workspace
	local id
	local attempts = 0
	repeat
		id = generate_base_id()
		attempts = attempts + 1
		if attempts > 100 then
			-- Fallback to timestamp-based ID
			id = "T" .. tostring(vim.loop.hrtime())
			break
		end
	until not M.find_task_by_id(id)

	return id
end

-- =============================================================================
-- Task Finding and Retrieval
-- =============================================================================

-- Find a task by ID across all workspace documents
-- Returns: task_data, document, line_number
function M.find_task_by_id(task_id)
	if not task_id then
		Logger.warn("tasks", "find_task_by_id called with nil task_id")
		return nil
	end

	Logger.debug("tasks", "Searching for task", { task_id = task_id })

	-- Search in all workspace documents
	local docs_to_search = {
		workspace.calendar(),
		workspace.projects(),
		workspace.areas(),
		workspace.okr(),
	}

	for _, doc in ipairs(docs_to_search) do
		if doc and doc.sections then
			-- Get all tasks from document
			local all_tasks = doc:get_all_tasks()
			for _, task in ipairs(all_tasks) do
				if task.attributes and task.attributes.id == task_id then
					Logger.debug("tasks", "Found task", {
						task_id = task_id,
						document = doc.name,
						line = task.line,
					})
					return task, doc, task.line
				end
			end
		end
	end

	Logger.debug("tasks", "Task not found", { task_id = task_id })
	return nil
end

-- Get task at specific line in document
function M.get_task_at_line(doc, lnum)
	if not doc or not doc.sections then
		return nil
	end

	local section = doc:get_section_at_line(lnum)
	if not section then
		return nil
	end

	for _, task in ipairs(section.tasks) do
		if task.line == lnum then
			return task, section
		end
	end

	return nil
end

-- =============================================================================
-- Line Manipulation Helpers
-- =============================================================================

-- Update task attributes in a line
local function update_task_line_attributes(line, updates)
	local modified_line = line

	for key, value in pairs(updates) do
		if value == nil then
			-- Remove attribute
			modified_line = attributes.remove_attribute(modified_line, key)
		else
			-- Update/add attribute
			modified_line = attributes.update_attribute(modified_line, key, value)
		end
	end

	return modified_line
end

-- Toggle task checkbox in line
local function toggle_task_checkbox(line, completed)
	if completed then
		return line:gsub("%[[ ]%]", "[x]", 1)
	else
		return line:gsub("%[[xX]%]", "[ ]", 1)
	end
end

-- =============================================================================
-- Task Completion Operations
-- =============================================================================

-- Complete a task
function M.complete_task(task_id, context)
	local timer = Logger.start_timer("tasks.complete_task")

	-- Find task across workspace
	local task, doc, lnum = M.find_task_by_id(task_id)
	if not task then
		timer()
		Logger.error("tasks", "Task not found", { task_id = task_id })
		return nil, "Task not found: " .. tostring(task_id)
	end

	if task.completed then
		timer()
		Logger.info("tasks", "Task already completed", { task_id = task_id })
		return nil, "Task already completed"
	end

	Logger.info("tasks", "Completing task", {
		task_id = task_id,
		document = doc.name,
		line = lnum,
	})

	-- Get current line
	local line = doc:get_line(lnum)
	if not line then
		timer()
		Logger.error("tasks", "Could not get line", { lnum = lnum })
		return nil, "Could not get line " .. lnum
	end

	-- Update line: toggle checkbox and add attributes
	local new_line = toggle_task_checkbox(line, true)
	new_line = update_task_line_attributes(new_line, {
		done = os.date("%Y-%m-%d"),
		completed_at = tostring(os.time()),
	})

	-- Update document
	local success = doc:change_line(lnum, new_line)
	if not success then
		timer()
		Logger.error("tasks", "Failed to update line", { lnum = lnum })
		return nil, "Failed to update line"
	end

	-- Reparse to get updated task
	doc:parse()

	-- Build XP context
	local xp_context = M._build_xp_context(task, doc, context)

	-- Update task object for event
	task.completed = true
	task.completed_at = os.time()

	-- Emit event
	Events.emit("task:completed", {
		task = task,
		task_id = task_id,
		xp_context = xp_context,
		document = doc.name,
		line = lnum,
	})

	timer()
	return task
end

-- Uncomplete a task
function M.uncomplete_task(task_id, context)
	local timer = Logger.start_timer("tasks.uncomplete_task")

	-- Find task
	local task, doc, lnum = M.find_task_by_id(task_id)
	if not task then
		timer()
		return nil, "Task not found: " .. tostring(task_id)
	end

	if not task.completed then
		timer()
		return nil, "Task not completed"
	end

	Logger.info("tasks", "Uncompleting task", {
		task_id = task_id,
		document = doc.name,
		line = lnum,
	})

	-- Get current line
	local line = doc:get_line(lnum)
	if not line then
		timer()
		return nil, "Could not get line"
	end

	-- Build XP context before reverting (for event)
	local xp_context = M._build_xp_context(task, doc, context)
	local xp_to_remove = task.attributes.xp_awarded and tonumber(task.attributes.xp_awarded) or 0

	-- Update line: toggle checkbox and remove completion attributes
	local new_line = toggle_task_checkbox(line, false)
	new_line = update_task_line_attributes(new_line, {
		done = nil,
		completed_at = nil,
		xp_awarded = nil,
	})

	-- Update document
	local success = doc:change_line(lnum, new_line)
	if not success then
		timer()
		return nil, "Failed to update line"
	end

	-- Reparse
	doc:parse()

	-- Update task object for event
	task.completed = false
	task.completed_at = nil

	-- Emit event
	Events.emit("task:uncompleted", {
		task = task,
		task_id = task_id,
		xp_removed = xp_to_remove,
		xp_context = xp_context,
		document = doc.name,
		line = lnum,
	})

	timer()
	return task
end

-- =============================================================================
-- Task Creation and Conversion
-- =============================================================================

-- Convert a line to a task
function M.convert_line_to_task(context)
	if not context or not context.doc or not context.lnum then
		Logger.error("tasks", "Invalid context for convert_line_to_task")
		return nil, "Invalid context"
	end

	local line = context.line or context.doc:get_line(context.lnum)
	if not line or line:match("^%s*$") then
		return nil, "Empty line"
	end

	Logger.info("tasks", "Converting line to task", {
		document = context.doc.name,
		line = context.lnum,
	})

	-- This function now assumes it's being called on a non-task line.
	-- The check for `is_task` has been moved to the calling function.

	-- Parse the line structure
	local indent, content = line:match("^(%s*)(.-)%s*$")

	-- Check if content starts with a list marker and extract the actual text
	-- Handles: "- text", "-text", "* text", "+ text", etc.
	local list_text = content:match("^[-*+]%s*(.+)") or content

	-- Build the task line
	local task_id = generate_task_id()
	local task_line = indent .. "- [ ] " .. list_text

	-- Add ID attribute
	task_line = update_task_line_attributes(task_line, {
		id = task_id,
	})

	-- Update document
	local success = context.doc:change_line(context.lnum, task_line)
	if not success then
		return nil, "Failed to update line"
	end

	-- Reparse to get the new task
	context.doc:parse()

	-- Get the created task
	local task = M.get_task_at_line(context.doc, context.lnum)
	if not task then
		return nil, "Failed to create task"
	end

	-- Get project info
	local project_info = M._find_project_for_task(context)

	-- Emit event
	Events.emit("task:created", {
		task = task,
		task_id = task_id,
		document = context.doc.name,
		line = context.lnum,
		project = project_info,
	})

	return task
end

-- =============================================================================
-- Task Completion Handler
-- =============================================================================

-- Change task completion at current context
function M.change_task_completion(context, should_complete)
	if not context or not context.doc then
		Logger.error("tasks", "Invalid context")
		return nil, "Invalid context"
	end

	local timer = Logger.start_timer("tasks.change_task_completion")

	-- Get task at current line
	local task, section = M.get_task_at_line(context.doc, context.lnum)
	local line = context.doc:get_line(context.lnum)

	-- FIX: If no task object is found, but the line *is* formatted as a task,
	-- the parsed data is stale. Force a re-parse and try to find the task again.
	if not task and parser.is_task_line(line) then
		Logger.info("tasks", "Stale task cache detected. Reparsing document.")
		context.doc:parse(true) -- Force a full re-parse
		task, section = M.get_task_at_line(context.doc, context.lnum)
	end

	-- If there's still no task object, it means the line is not a task. Convert it.
	if not task then
		timer()
		-- After converting, the toggle action is complete for this call.
		return M.convert_line_to_task(context)
	end

	-- Ensure task has ID
	if not task.attributes or not task.attributes.id then
		Logger.info("tasks", "Adding ID to existing task")
		local id = generate_task_id()
		local new_line = update_task_line_attributes(line, { id = id })
		context.doc:change_line(context.lnum, new_line)
		context.doc:parse()
		task = M.get_task_at_line(context.doc, context.lnum)
	end

	local task_id = task.attributes.id

	-- Handle completion based on should_complete parameter
	local result, err
	if should_complete == nil then
		-- Toggle
		if task.completed then
			result, err = M.uncomplete_task(task_id, context)
		else
			result, err = M.complete_task(task_id, context)
		end
	elseif should_complete and not task.completed then
		result, err = M.complete_task(task_id, context)
	elseif not should_complete and task.completed then
		result, err = M.uncomplete_task(task_id, context)
	else
		-- No change needed
		result = task
	end

	timer()
	return result, err
end

-- =============================================================================
-- Context Building Helpers
-- =============================================================================

-- Build XP context for a task
function M._build_xp_context(task, doc, context)
	local project_info = M._find_project_for_task({
		doc = doc,
		section = doc:get_section_at_line(task.line),
	})

	-- Calculate position within project
	local position, total = 1, 1
	if project_info then
		position, total = M._calculate_task_position_in_project(doc, task, project_info.text)
	end

	return {
		task_id = task.attributes.id,
		project_name = project_info and project_info.text,
		project_link = project_info and project_info.link,
		task_position = position,
		total_tasks = total,
		area_links = M._extract_area_links(doc:get_section_at_line(task.line)),
		task_attributes = task.attributes,
		document = doc.name,
	}
end

-- Find project containing task
function M._find_project_for_task(context)
	if not context or not context.section then
		return nil
	end

	-- Walk up section tree to find project (heading)
	local current = context.section
	while current do
		if current.type == "heading" then
			local link = current:build_link(context.doc)
			return {
				text = current.text,
				link = link,
			}
		end
		current = current.parent
	end
	return nil
end

-- Extract area links from section hierarchy
function M._extract_area_links(section)
	if not section then
		return {}
	end

	local links = {}
	local seen = {}

	-- Walk up tree collecting area links
	local current = section
	while current do
		-- Check section text for area links
		if current.raw_text then
			local all_links = parser.extract_all_links(current.raw_text)
			for _, link_info in ipairs(all_links) do
				if link_info.type == "link" then
					local parsed = parser.parse_link_definition(link_info.definition)
					if parsed and #parsed.components > 0 then
						local first = parsed.components[1]
						if first.type == "article" and (first.text == "A" or first.text == "Areas") then
							if not seen[link_info.definition] then
								table.insert(links, link_info.definition)
								seen[link_info.definition] = true
							end
						end
					end
				end
			end
		end
		current = current.parent
	end

	return links
end

-- Calculate task position within project
function M._calculate_task_position_in_project(doc, task, project_name)
	if not doc.sections then
		return 1, 1
	end

	local position = 0
	local total = 0
	local found_task = false

	local function count_in_section(section)
		if section.type == "heading" and section.text == project_name then
			-- Count all tasks in this project
			for _, t in ipairs(section:get_all_tasks()) do
				total = total + 1
				if t.line <= task.line and not found_task then
					position = total
				end
				if t.line == task.line then
					found_task = true
				end
			end
		end

		for _, child in ipairs(section.children) do
			count_in_section(child)
		end
	end

	count_in_section(doc.sections)

	return position > 0 and position or 1, total > 0 and total or 1
end

-- =============================================================================
-- Public Commands
-- =============================================================================

function M.toggle_current_task()
	local context = workspace.get_context()
	if not context then
		Logger.error("tasks", "No workspace context")
		return nil, "No workspace context"
	end
	return M.change_task_completion(context, nil)
end

function M.complete_current_task()
	local context = workspace.get_context()
	if not context then
		return nil, "No workspace context"
	end
	return M.change_task_completion(context, true)
end

function M.uncomplete_current_task()
	local context = workspace.get_context()
	if not context then
		return nil, "No workspace context"
	end
	return M.change_task_completion(context, false)
end

-- =============================================================================
-- Task Statistics (workspace-based)
-- =============================================================================

function M.get_stats()
	local stats = {
		total_tasks = 0,
		completed_tasks = 0,
		tasks_by_project = {},
		tasks_by_document = {},
	}

	local docs = {
		calendar = workspace.calendar(),
		projects = workspace.projects(),
		areas = workspace.areas(),
		okr = workspace.okr(),
	}

	for doc_name, doc in pairs(docs) do
		if doc and doc.sections then
			local doc_stats = {
				total = 0,
				completed = 0,
			}

			local all_tasks = doc:get_all_tasks()
			for _, task in ipairs(all_tasks) do
				-- Overall stats
				stats.total_tasks = stats.total_tasks + 1
				doc_stats.total = doc_stats.total + 1

				if task.completed then
					stats.completed_tasks = stats.completed_tasks + 1
					doc_stats.completed = doc_stats.completed + 1
				end

				-- Project stats
				local section = doc:get_section_at_line(task.line)
				local project_info = M._find_project_for_task({
					doc = doc,
					section = section,
				})

				if project_info then
					local project_name = project_info.text
					if not stats.tasks_by_project[project_name] then
						stats.tasks_by_project[project_name] = {
							total = 0,
							completed = 0,
						}
					end

					stats.tasks_by_project[project_name].total = stats.tasks_by_project[project_name].total + 1
					if task.completed then
						stats.tasks_by_project[project_name].completed = stats.tasks_by_project[project_name].completed
							+ 1
					end
				end
			end

			stats.tasks_by_document[doc_name] = doc_stats
		end
	end

	return stats
end

-- =============================================================================
-- Debugging Helpers
-- =============================================================================

-- Get detailed task info for debugging
function M.get_task_info(task_id)
	local task, doc, lnum = M.find_task_by_id(task_id)
	if not task then
		return nil
	end

	local section = doc:get_section_at_line(lnum)
	local project_info = M._find_project_for_task({
		doc = doc,
		section = section,
	})

	return {
		task = task,
		document = doc.name,
		line = lnum,
		section_path = section and section:get_breadcrumb() or "none",
		project = project_info,
		area_links = M._extract_area_links(section),
		line_content = doc:get_line(lnum),
	}
end

return M
