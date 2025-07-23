-- services/task.lua - Stateless service for task operations
local M = {}

local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local buffer_sync = require("zortex.core.buffer_sync")
local parser = require("zortex.core.parser")
local task_store = require("zortex.stores.tasks")

-- ID generation (moved from models/task.lua)
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

	-- Ensure uniqueness
	local id
	local attempts = 0
	repeat
		id = generate_base_id()
		attempts = attempts + 1
		if attempts > 100 then
			id = "T" .. task_store.get_next_numeric_id()
			break
		end
	until not task_store.task_exists(id)

	return id
end

-- Complete a task
function M.complete_task(task_id, context)
	local stop_timer = Logger.start_timer("task_service.complete_task")

	-- Get task from store
	local task = task_store.get_task(task_id)
	if not task then
		stop_timer()
		return nil, "Task not found"
	end

	if task.completed then
		stop_timer()
		return nil, "Task already completed"
	end

	-- Update task
	task.completed = true
	task.completed_at = os.time()

	-- Calculate XP context for distribution
	local xp_context = M._build_xp_context(task, context)

	-- Emit completing event for XP calculation
	EventBus.emit("task:completing", {
		task = task,
		xp_context = xp_context,
		bufnr = context.bufnr,
	})

	-- Save task
	task_store.update_task(task_id, task)

	-- Update buffer through buffer_sync
	if context.bufnr and task.line then
		buffer_sync.toggle_task(context.bufnr, task.line, true)
	end

	-- Emit completed event
	EventBus.emit("task:completed", {
		task = task,
		xp_context = xp_context,
		bufnr = context.bufnr,
	})

	stop_timer()
	return task
end

-- Uncomplete a task
function M.uncomplete_task(task_id, context)
	local task = task_store.get_task(task_id)
	if not task or not task.completed then
		return nil, "Task not completed"
	end

	-- Build XP context before reverting
	local xp_context = M._build_xp_context(task, context)

	-- Update task
	task.completed = false
	task.completed_at = nil
	local xp_to_remove = task.xp_awarded or 0
	task.xp_awarded = 0

	task_store.update_task(task_id, task)

	-- Update buffer
	if context.bufnr and task.line then
		buffer_sync.toggle_task(context.bufnr, task.line, false)
	end

	-- Emit event for XP reversal
	EventBus.emit("task:uncompleted", {
		task = task,
		xp_removed = xp_to_remove,
		xp_context = xp_context,
		bufnr = context.bufnr,
	})

	return task
end

-- Toggle task at line
function M.toggle_task_at_line(context)
	local doc = require("zortex.core.document_manager").get_buffer(context.bufnr)
	if not doc then
		return nil, "No document found"
	end

	local section = doc:get_section_at_line(context.lnum)
	if not section then
		-- Try to convert line to task
		return M.convert_line_to_task(context)
	end

	-- Find task at line
	local task = nil
	for _, t in ipairs(section.tasks) do
		if t.line == context.lnum then
			task = t
			break
		end
	end

	if not task then
		return M.convert_line_to_task(context)
	end

	-- Ensure task has ID
	if not task.attributes or not task.attributes.id then
		local id = generate_task_id()
		task.attributes = task.attributes or {}
		task.attributes.id = id

		-- Update line with ID
		buffer_sync.update_task(context.bufnr, context.lnum, { id = id })
	end

	-- Save to store if new
	local stored_task = task_store.get_task(task.attributes.id)
	if not stored_task then
		task_store.create_task(task.attributes.id, {
			id = task.attributes.id,
			text = task.text,
			completed = task.completed,
			line = task.line,
			project = M._find_project_for_task(doc, section),
			area_links = M._extract_area_links(doc, section),
			attributes = task.attributes,
			created_at = os.time(),
		})
	end

	-- Toggle completion
	if task.completed then
		return M.uncomplete_task(task.attributes.id, context)
	else
		return M.complete_task(task.attributes.id, context)
	end
end

-- Convert line to task
function M.convert_line_to_task(context)
	local lines = vim.api.nvim_buf_get_lines(context.bufnr, context.lnum - 1, context.lnum, false)
	local line = lines[1]

	if not line or line:match("^%s*$") then
		return nil, "Empty line"
	end

	-- Create task from line
	local indent, content = line:match("^(%s*)(.-)%s*$")
	local task_line = indent .. "- [ ] " .. content

	-- Generate ID
	local task_id = generate_task_id()
	task_line = parser.update_attribute(task_line, "id", task_id)

	-- Update buffer
	buffer_sync.update_text(context.bufnr, context.lnum, context.lnum, { task_line })

	-- Get document context
	local doc = require("zortex.core.document_manager").get_buffer(context.bufnr)
	local section = doc and doc:get_section_at_line(context.lnum)

	-- Create task in store
	local task = {
		id = task_id,
		text = content,
		completed = false,
		line = context.lnum,
		project = section and M._find_project_for_task(doc, section),
		area_links = section and M._extract_area_links(doc, section) or {},
		attributes = { id = task_id },
		created_at = os.time(),
	}

	task_store.create_task(task_id, task)

	EventBus.emit("task:created", {
		task = task,
		bufnr = context.bufnr,
	})

	return task
end

-- Build XP context for a task
function M._build_xp_context(task, context)
	local doc = context.bufnr and require("zortex.core.document_manager").get_buffer(context.bufnr)
	local section = doc and task.line and doc:get_section_at_line(task.line)

	-- Calculate position within project
	local position, total = 1, 1
	if task.project and doc then
		position, total = M._calculate_task_position_in_project(doc, task, task.project)
	end

	return {
		task_id = task.id,
		project_name = task.project,
		task_position = position,
		total_tasks = total,
		area_links = task.area_links or {},
		task_attributes = task.attributes,
	}
end

-- Find project containing task
function M._find_project_for_task(doc, section)
	-- Walk up section tree to find project (heading)
	local current = section
	while current do
		if current.type == "heading" then
			return current.text
		end
		current = current.parent
	end
	return nil
end

-- Extract area links from section hierarchy
function M._extract_area_links(doc, section)
	local links = {}
	local seen = {}

	-- Walk up tree collecting area links
	local current = section
	while current do
		-- Check section text for area links
		local all_links = parser.extract_all_links(current.raw_text or current.text)
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
		current = current.parent
	end

	return links
end

-- Calculate task position within project
function M._calculate_task_position_in_project(doc, task, project_name)
	if not doc.sections then
		return 1, 1
	end

	-- Find project section and count tasks
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

-- Update task attributes
function M.update_task_attributes(task_id, attributes, context)
	local task = task_store.get_task(task_id)
	if not task then
		return nil, "Task not found"
	end

	-- Merge attributes
	task.attributes = vim.tbl_extend("force", task.attributes or {}, attributes)
	task_store.update_task(task_id, task)

	-- Update buffer if we have line info
	if context.bufnr and task.line then
		buffer_sync.update_task(context.bufnr, task.line, attributes)
	end

	EventBus.emit("task:updated", {
		task = task,
		updates = { attributes = attributes },
		bufnr = context.bufnr,
	})

	return task
end

-- Process all tasks in buffer (for bulk operations)
function M.process_buffer_tasks(bufnr)
	local doc = require("zortex.core.document_manager").get_buffer(bufnr)
	if not doc then
		return
	end

	local processed = 0
	local tasks = doc:get_all_tasks()

	for _, task in ipairs(tasks) do
		-- Ensure task has ID
		if not task.attributes or not task.attributes.id then
			local id = generate_task_id()
			task.attributes = task.attributes or {}
			task.attributes.id = id

			-- Update in buffer
			buffer_sync.update_task(bufnr, task.line, { id = id })
			processed = processed + 1
		end

		-- Ensure task is in store
		local stored = task_store.get_task(task.attributes.id)
		if not stored then
			local section = doc:get_section_at_line(task.line)
			task_store.create_task(task.attributes.id, {
				id = task.attributes.id,
				text = task.text,
				completed = task.completed,
				line = task.line,
				project = section and M._find_project_for_task(doc, section),
				area_links = section and M._extract_area_links(doc, section) or {},
				attributes = task.attributes,
				created_at = os.time(),
			})
		end
	end

	if processed > 0 then
		Logger.info("task_service", "Processed tasks", {
			bufnr = bufnr,
			processed = processed,
		})
	end

	return processed
end

return M

