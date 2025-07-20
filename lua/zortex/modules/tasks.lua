-- modules/tasks.lua - Consolidated task management
local M = {}

local Task = require("zortex.models.task")
local parser = require("zortex.core.parser")
local buffer = require("zortex.core.buffer")
local xp_projects = require("zortex.xp.projects")
local constants = require("zortex.constants")

-- =============================================================================
-- Task Processing in Buffer
-- =============================================================================

-- Ensure all tasks in buffer have IDs
function M.ensure_task_ids(bufnr)
	bufnr = bufnr or 0
	local lines = buffer.get_lines(bufnr)
	local modified = false

	for i, line in ipairs(lines) do
		local new_line, id = Task.ensure_id_in_line(line)
		if new_line ~= line then
			lines[i] = new_line
			modified = true
		end
	end

	if modified then
		buffer.set_lines(bufnr, 0, -1, lines)
	end

	return modified
end

-- Process all tasks in a project section
function M.process_project_tasks(lines, project_name, start_idx, end_idx, area_links)
	local tasks = {}
	local xp_changes = {}

	-- Find all direct tasks (not in child sections)
	local i = start_idx + 1
	while i < end_idx do
		local line = lines[i]
		local heading_level = parser.get_heading_level(line)

		if heading_level > 0 then
			-- Skip child section
			local child_end = parser.find_section_end(lines, i, constants.SECTION_TYPE.HEADING, heading_level)
			i = child_end
		else
			-- Check if it's a task
			local task = Task.from_line(line, i)
			if task then
				task.project = project_name
				task.area_links = area_links
				task.position = #tasks + 1
				table.insert(tasks, task)
			end
			i = i + 1
		end
	end

	-- Update total count and save tasks
	local total_tasks = #tasks
	for _, task in ipairs(tasks) do
		task.total_in_project = total_tasks

		-- Check if task state changed
		local existing = Task.load(task.id)
		local xp_delta = 0

		if existing then
			-- Task exists - check for completion change
			if existing.completed ~= task.completed then
				if task.completed then
					-- Task was completed
					xp_delta = xp_projects.complete_task(project_name, task.position, total_tasks, area_links)
					task.xp_awarded = xp_delta
				else
					-- Task was uncompleted
					xp_delta = xp_projects.uncomplete_task(project_name, existing.xp_awarded, area_links)
					task.xp_awarded = 0
				end
			elseif existing.position ~= task.position or existing.total_in_project ~= task.total_in_project then
				-- Position changed - might need XP recalculation
				-- For now, we'll leave XP as is
			end
		else
			-- New task
			if task.completed then
				xp_delta = xp_projects.complete_task(project_name, task.position, total_tasks, area_links)
				task.xp_awarded = xp_delta
			end
		end

		task:save()

		if xp_delta ~= 0 then
			table.insert(xp_changes, {
				task = task,
				delta = xp_delta,
			})
		end
	end

	return tasks, xp_changes
end

-- =============================================================================
-- Current Task Operations
-- =============================================================================

---Convert an arbitrary line into a task.
---@param line string  The raw buffer line.
---@return string|nil      new_line   The rewritten task line (`- [ ] foo … @id(abc)`)
---@return table|nil   task       Parsed **Task** model (already has an id & saved).
local function convert_line_to_task(line)
	-- Preserve leading indentation so list nesting still looks right.
	local indent, content = line:match("^(%s*)(.-)%s*$")
	if content == "" then -- ignore empty lines
		return nil, nil
	end

	-- 1. Construct checkbox list item.
	local task_line = string.format("%s- [ ] %s", indent, content)

	-- 2. Ensure the line contains an @id attribute.
	task_line = Task.ensure_id_in_line(task_line)

	-- 3. Parse back into a Task model so downstream logic can reuse it.
	local task = Task.from_line(task_line, vim.fn.line("."))
	if task then
		task:save()
	end

	return task_line, task
end

-- Toggle current task completion
function M.toggle_current_task()
	local bufnr = 0
	local line_num = vim.fn.line(".") -- 1‑based (matches existing buffer helpers)
	local line = buffer.get_current_line()
	local task = Task.from_line(line, line_num)

	-- If the cursor isn't on a task yet, turn the line into one
	if not task then
		local new_line, _ = convert_line_to_task(line)
		if not new_line then
			vim.notify("Not on a task line", vim.log.levels.WARN)
			return
		end
		buffer.update_line(bufnr, line_num, new_line)
		vim.cmd("silent! write")
		require("zortex.modules.projects").update_progress()
		return
	end

	-- Ensure task has ID
	if not task.id then
		task.id = Task.generate_id()
	end

	-- Toggle completion
	local new_line
	if task.completed then
		new_line = line:gsub("%[.%]", "[ ]")
		task:uncomplete()
	else
		new_line = line:gsub("%[%s*%]", "[x]")
		task:complete()
	end

	-- Update line with ID
	new_line = parser.update_attribute(new_line, "id", task.id)
	buffer.update_line(bufnr, line_num, new_line)

	-- Trigger project progress update
	vim.cmd("silent! write")
	require("zortex.modules.projects").update_progress()
end

-- Complete current task
function M.complete_current_task()
	local line = buffer.get_current_line()
	local task = Task.from_line(line, vim.fn.line("."))

	if not task then
		vim.notify("Not on a task line", vim.log.levels.WARN)
		return
	end

	if task.completed then
		vim.notify("Task already completed", vim.log.levels.INFO)
		return
	end

	-- Complete task
	task:complete()
	local new_line = line:gsub("%[%s*%]", "[x]")
	new_line = parser.update_attribute(new_line, "id", task.id)
	buffer.update_line(0, vim.fn.line("."), new_line)

	vim.cmd("silent! write")
	require("zortex.modules.projects").update_progress()
end

-- Uncomplete current task
function M.uncomplete_current_task()
	local line = buffer.get_current_line()
	local task = Task.from_line(line, vim.fn.line("."))

	if not task then
		vim.notify("Not on a task line", vim.log.levels.WARN)
		return
	end

	if not task.completed then
		vim.notify("Task already incomplete", vim.log.levels.INFO)
		return
	end

	-- Uncomplete task
	task:uncomplete()
	local new_line = line:gsub("%[.%]", "[ ]")
	new_line = parser.update_attribute(new_line, "id", task.id)
	buffer.update_line(0, vim.fn.line("."), new_line)

	vim.cmd("silent! write")
	require("zortex.modules.projects").update_progress()
end

-- =============================================================================
-- Task Statistics
-- =============================================================================

-- Get task statistics
function M.get_stats()
	return require("zortex.stores.tasks").get_stats()
end

-- Show task statistics
function M.show_stats()
	local stats = M.get_stats()

	local lines = {}
	table.insert(lines, "📊 Task Statistics")
	table.insert(lines, "")
	table.insert(lines, string.format("Total Tasks: %d", stats.total_tasks))
	table.insert(
		lines,
		string.format(
			"Completed: %d (%.0f%%)",
			stats.completed_tasks,
			stats.total_tasks > 0 and (stats.completed_tasks / stats.total_tasks * 100) or 0
		)
	)
	table.insert(lines, string.format("Total XP Awarded: %d", stats.total_xp_awarded))

	if next(stats.tasks_by_project) then
		table.insert(lines, "")
		table.insert(lines, "By Project:")

		-- Sort projects by total tasks
		local sorted = {}
		for project, data in pairs(stats.tasks_by_project) do
			table.insert(sorted, { project = project, data = data })
		end
		table.sort(sorted, function(a, b)
			return a.data.total > b.data.total
		end)

		for _, item in ipairs(sorted) do
			local proj = item.data
			table.insert(
				lines,
				string.format(
					"  • %s: %d/%d tasks (%.0f%%), %d XP",
					item.project,
					proj.completed,
					proj.total,
					proj.total > 0 and (proj.completed / proj.total * 100) or 0,
					proj.xp
				)
			)
		end
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- =============================================================================
-- Task Cleanup
-- =============================================================================

-- Archive old completed tasks
function M.archive_old_tasks(days)
	days = days or 30
	local archived = require("zortex.stores.tasks").archive_old_tasks(days)

	vim.notify(string.format("Archived %d completed tasks older than %d days", archived, days), vim.log.levels.INFO)

	return archived
end

return M
