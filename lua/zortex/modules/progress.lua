-- modules/progress.lua - Progress tracking with individual task state management
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")
local constants = require("zortex.constants")
local skills = require("zortex.modules.skills")
local xp = require("zortex.modules.xp")
local task_tracker = require("zortex.modules.task_tracker")
local attributes = require("zortex.core.attributes")

-- =============================================================================
-- Task ID Management
-- =============================================================================

-- Ensure all tasks have IDs
local function ensure_task_ids(lines)
	local modified = false

	for i, line in ipairs(lines) do
		local is_task = parser.is_task_line(line)
		if is_task then
			local id = attributes.extract_task_id(line)
			if not id then
				-- Generate new ID
				id = task_tracker.generate_unique_id()
				lines[i] = attributes.add_task_id(line, id)
				modified = true
			end
		end
	end

	return modified
end

-- =============================================================================
-- Direct Task Counting (Excludes Children)
-- =============================================================================

local function count_direct_tasks(lines, start_idx, end_idx, level)
	local tasks = {}
	local current_section_level = level

	for i = start_idx + 1, end_idx - 1 do
		local line = lines[i]
		local heading_level = parser.get_heading_level(line)

		if heading_level > 0 then
			if heading_level <= level then
				-- We've exited the current project
				break
			else
				-- We're entering a child section - skip it entirely
				current_section_level = heading_level
				-- Find the end of this child section
				for j = i + 1, end_idx - 1 do
					local next_level = parser.get_heading_level(lines[j])
					if next_level > 0 and next_level <= heading_level then
						i = j - 1 -- Skip to end of child section
						break
					elseif j == end_idx - 1 then
						i = j -- Skip to end
						break
					end
				end
			end
		else
			-- Only count tasks at the direct level
			local is_task, is_completed = parser.is_task_line(line)
			if is_task then
				local id = attributes.extract_task_id(line)
				if id then
					table.insert(tasks, {
						id = id,
						line_num = i,
						completed = is_completed,
						line = line,
					})
				end
			end
		end
	end

	return tasks
end

-- =============================================================================
-- Project Progress Tracking
-- =============================================================================

function M.update_project_progress(bufnr)
	bufnr = bufnr or 0
	local lines = buffer.get_lines(bufnr)
	local modified = false

	-- First ensure all tasks have IDs
	if ensure_task_ids(lines) then
		modified = true
		-- Write back the lines with IDs before continuing
		buffer.set_lines(bufnr, 0, -1, lines)
		-- Re-read to ensure we have the latest
		lines = buffer.get_lines(bufnr)
	end

	-- Load task tracker state
	task_tracker.load_state()

	-- Batch XP changes
	local xp_changes = {
		total_delta = 0,
		task_changes = {},
		project_completions = {},
	}

	-- Get all headings
	local headings = buffer.get_all_headings(bufnr)

	for i, heading_info in ipairs(headings) do
		local lnum = heading_info.lnum
		local level = heading_info.level
		local project_name = heading_info.text

		-- Find the end of this section
		local end_idx = #lines + 1
		for j = i + 1, #headings do
			if headings[j].level <= level then
				end_idx = headings[j].lnum
				break
			end
		end

		-- Get direct tasks only (not from child projects)
		local tasks = count_direct_tasks(lines, lnum, end_idx, level)

		-- Get area links for this project
		local area_links = skills.get_project_area_links(lines, lnum)

		-- Process each task
		local total_tasks = #tasks
		local completed_tasks = 0

		for position, task_info in ipairs(tasks) do
			if task_info.completed then
				completed_tasks = completed_tasks + 1
			end

			-- Register task with tracker
			task_tracker.register_task(
				task_info.id,
				project_name,
				attributes.parse_task_attributes(task_info.line),
				area_links
			)

			-- Update task status and get XP delta
			local xp_delta = task_tracker.update_task_status(task_info.id, task_info.completed, position, total_tasks)

			if xp_delta ~= 0 then
				table.insert(xp_changes.task_changes, {
					task_id = task_info.id,
					project = project_name,
					delta = xp_delta,
					completed = task_info.completed,
					position = position,
					total = total_tasks,
					area_links = area_links, -- Include area links for XP processing
				})
				xp_changes.total_delta = xp_changes.total_delta + xp_delta
			end
		end

		-- Update the heading line with progress
		local old_line = lines[lnum]
		local new_line = attributes.update_progress_attribute(old_line, completed_tasks, total_tasks)

		-- Mark as done if all tasks completed
		local was_done = attributes.was_done(old_line)
		local is_done = total_tasks > 0 and completed_tasks == total_tasks

		if is_done and not was_done then
			new_line = attributes.update_done_attribute(new_line, true)

			-- Track project completion
			if #area_links > 0 then
				local proj_xp = task_tracker.get_project_total_xp(project_name)
				xp.complete_project(project_name, proj_xp, area_links)
			end
		elseif not is_done and was_done then
			-- Remove done if project is no longer complete
			new_line = attributes.update_done_attribute(new_line, false)
		end

		if new_line ~= old_line then
			lines[lnum] = new_line
			modified = true
		end
	end

	-- Apply XP changes through the XP system
	if xp_changes.total_delta ~= 0 then
		-- Apply task XP changes
		for _, change in ipairs(xp_changes.task_changes) do
			if change.delta > 0 then
				-- Task completed
				skills.process_task_completion(
					change.project,
					change.position,
					change.total,
					change.area_links, -- Use the area links we captured
					true -- silent
				)
			elseif change.delta < 0 then
				-- task reverted ➜ remove XP (project + areas)
				xp.uncomplete_task(change.project, -change.delta, change.area_links, true)
			end
		end

		-- Save states
		if modified then
			buffer.set_lines(bufnr, 0, -1, lines)
		end

		-- Show notification
		M.show_xp_notification(xp_changes)
	end

	task_tracker.save_state()
	xp.save_state()

	return modified
end

-- =============================================================================
-- XP Notifications
-- =============================================================================

function M.show_xp_notification(xp_changes)
	if xp_changes.total_delta == 0 then
		return
	end

	local lines = {}

	if xp_changes.total_delta > 0 then
		table.insert(lines, string.format("✨ Progress Update: +%d XP", xp_changes.total_delta))
	else
		table.insert(lines, string.format("⚠️  Progress Reverted: %d XP", xp_changes.total_delta))
	end

	-- Group by project
	local by_project = {}
	for _, change in ipairs(xp_changes.task_changes) do
		if not by_project[change.project] then
			by_project[change.project] = {
				completed = 0,
				uncompleted = 0,
				xp = 0,
			}
		end

		local proj = by_project[change.project]
		if change.completed then
			proj.completed = proj.completed + 1
		else
			proj.uncompleted = proj.uncompleted + 1
		end
		proj.xp = proj.xp + change.delta
	end

	table.insert(lines, "")
	table.insert(lines, "📋 Task Changes:")
	for project, stats in pairs(by_project) do
		local parts = {}
		if stats.completed > 0 then
			table.insert(parts, string.format("%d completed", stats.completed))
		end
		if stats.uncompleted > 0 then
			table.insert(parts, string.format("%d uncompleted", stats.uncompleted))
		end

		table.insert(lines, string.format("  • %s: %s (%+d XP)", project, table.concat(parts, ", "), stats.xp))
	end

	if #xp_changes.project_completions > 0 then
		table.insert(lines, "")
		table.insert(lines, "🎉 Projects Completed:")
		for _, proj in ipairs(xp_changes.project_completions) do
			table.insert(lines, string.format("  • %s", proj.name))
		end
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- =============================================================================
-- OKR Progress Tracking
-- =============================================================================

local function extract_linked_projects(kr_line)
	local projects = {}
	local all_links = parser.extract_all_links(kr_line)

	for _, link_info in ipairs(all_links) do
		if link_info.type == "link" then
			local parsed = parser.parse_link_definition(link_info.definition)
			if parsed and #parsed.components > 0 then
				for _, component in ipairs(parsed.components) do
					if component.type == "article" then
						table.insert(projects, component.text)
					end
				end
			end
		end
	end

	return projects
end

local function is_project_completed(project_name)
	local projects_file = fs.get_projects_file()
	if not projects_file or not fs.file_exists(projects_file) then
		return false, nil
	end

	local lines = fs.read_lines(projects_file)
	if not lines then
		return false, nil
	end

	for _, line in ipairs(lines) do
		local heading = parser.parse_heading(line)
		if heading then
			local heading_text = heading.text:gsub(" @%w+%([^%)]*%)", ""):gsub(" @%w+", "")
			heading_text = parser.trim(heading_text)

			if heading_text:lower() == project_name:lower() then
				local done_date = line:match(constants.PATTERNS.DONE_DATE)
				return done_date ~= nil, done_date
			end
		end
	end

	-- Check archive
	local archive_file = fs.get_archive_file()
	if archive_file and fs.file_exists(archive_file) then
		lines = fs.read_lines(archive_file)
		if lines then
			for _, line in ipairs(lines) do
				local heading = parser.parse_heading(line)
				if heading then
					local heading_text = heading.text:gsub(" @%w+%([^%)]*%)", ""):gsub(" @%w+", "")
					heading_text = parser.trim(heading_text)
					if heading_text:lower() == project_name:lower() then
						return true, nil
					end
				end
			end
		end
	end

	return false, nil
end

function M.update_okr_progress()
	local okr_file = fs.get_okr_file()
	if not okr_file or not fs.file_exists(okr_file) then
		return false
	end

	local lines = fs.read_lines(okr_file)
	if not lines then
		return false
	end

	local modified = false
	local current_objective_idx = nil
	local current_objective_data = nil
	local objective_kr_count = 0
	local objective_kr_completed = 0

	for i, line in ipairs(lines) do
		-- Check if this is an objective
		local okr_date = parser.parse_okr_date(line)
		if okr_date then
			-- Update previous objective if needed
			if current_objective_idx and current_objective_data then
				local old_line = lines[current_objective_idx]
				local new_line =
					attributes.update_progress_attribute(old_line, objective_kr_completed, objective_kr_count)

				-- Check if objective was just completed
				local was_completed = old_line:match(constants.PATTERNS.DONE_DATE) ~= nil
				local is_completed = objective_kr_count > 0 and objective_kr_completed == objective_kr_count

				if is_completed and not was_completed then
					new_line = attributes.update_done_attribute(new_line, true)

					-- Award area XP for objective completion
					local area_links = skills.get_area_links_for_heading(lines, current_objective_idx)
					if #area_links > 0 then
						current_objective_data.title = current_objective_data.title
							or old_line:match("^## %w+ %d+ %d+ (.+)$")
						local xp_awarded =
							skills.process_objective_completion(current_objective_data, lines, current_objective_idx)
						vim.notify(string.format("Objective completed! +%d Area XP", xp_awarded), vim.log.levels.INFO)
					end
				end

				if new_line ~= old_line then
					lines[current_objective_idx] = new_line
					modified = true
				end
			end

			-- Start tracking new objective
			current_objective_idx = i
			current_objective_data = okr_date
			objective_kr_count = 0
			objective_kr_completed = 0
		elseif line:match("^%s*- KR%-") then
			-- This is a key result
			if current_objective_idx then
				objective_kr_count = objective_kr_count + 1

				-- Extract linked projects
				local projects = extract_linked_projects(line)
				local all_completed = true
				local any_projects = false

				for _, project in ipairs(projects) do
					any_projects = true
					local completed, _ = is_project_completed(project)
					if not completed then
						all_completed = false
						break
					end
				end

				-- Count as completed if has projects and all are done
				if any_projects and all_completed then
					objective_kr_completed = objective_kr_completed + 1
				end
			end
		end
	end

	-- Update last objective if needed
	if current_objective_idx and current_objective_data then
		local old_line = lines[current_objective_idx]
		local new_line = attributes.update_progress_attribute(old_line, objective_kr_completed, objective_kr_count)

		local was_completed = old_line:match(constants.PATTERNS.DONE_DATE) ~= nil
		local is_completed = objective_kr_count > 0 and objective_kr_completed == objective_kr_count

		if is_completed and not was_completed then
			new_line = attributes.update_done_attribute(new_line, true)

			-- Award area XP
			local area_links = skills.get_area_links_for_heading(lines, current_objective_idx)
			if #area_links > 0 then
				current_objective_data.title = current_objective_data.title or old_line:match("^## %w+ %d+ %d+ (.+)$")
				local xp_awarded =
					skills.process_objective_completion(current_objective_data, lines, current_objective_idx)
				vim.notify(string.format("Objective completed! +%d Area XP", xp_awarded), vim.log.levels.INFO)
			end
		end

		if new_line ~= old_line then
			lines[current_objective_idx] = new_line
			modified = true
		end
	end

	if modified then
		fs.write_lines(okr_file, lines)
	end

	return modified
end

-- =============================================================================
-- Change current task
-- =============================================================================

-- Internal helper that flips or sets the completion state of the **current** task line.
-- It handles validation, ID injection, checkbox toggle, buffer write, and downstream XP/XP updates.
local function set_current_task_completion(should_complete)
	local bufnr = 0
	local row = vim.fn.line(".") - 1
	local line = vim.api.nvim_get_current_line()

	-- Validate task
	local is_task, is_completed = parser.is_task_line(line)
	if not is_task then
		-- If line is a list then convert it to a task, otherwise fail
		local indent, line_content = line:match("(%s*)- (.*)")
		if indent and line_content then
			vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { indent .. "- [ ] " .. line_content })
		else
			vim.notify("Not on a task line", vim.log.levels.WARN)
		end
		return
	end

	-- Determine desired end‑state
	if should_complete == nil then
		should_complete = not is_completed -- toggle
	end
	if is_completed == should_complete then
		vim.notify(
			string.format("Task already %s", should_complete and "completed" or "incomplete"),
			vim.log.levels.INFO
		)
		return
	end

	-- Guarantee ID
	local id = attributes.extract_task_id(line)
	if not id then
		id = task_tracker.generate_unique_id()
		line = attributes.add_task_id(line, id)
	end

	-- Toggle checkbox
	local new_line
	if should_complete then
		new_line = line:gsub("%[%s*%]", "[x]") -- [ ] → [x]
	else
		new_line = line:gsub("%[.%]", "[ ]") -- [x] / [-] → [ ]
	end

	-- Update the specific line immediately
	vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { new_line })

	-- Force buffer write to ensure changes are saved
	vim.cmd("silent! write")

	-- Now update progress with fresh buffer data
	M.update_project_progress(bufnr)
end

function M.toggle_current_task()
	set_current_task_completion(nil)
end

function M.complete_current_task()
	set_current_task_completion(true)
end

function M.uncomplete_current_task()
	set_current_task_completion(false)
end

-- =============================================================================
-- Manual Commands
-- =============================================================================

function M.update_all_progress()
	-- Find and update projects.zortex
	local projects_file = fs.get_projects_file()
	if projects_file and fs.file_exists(projects_file) then
		local bufnr = vim.fn.bufadd(projects_file)
		vim.fn.bufload(bufnr)
		M.update_project_progress(bufnr)
	end

	-- Update OKRs
	M.update_okr_progress()

	vim.notify("Updated progress for all projects and OKRs", vim.log.levels.INFO)
end

-- =============================================================================
-- Debug Commands
-- =============================================================================

function M.show_task_stats()
	task_tracker.load_state()
	local stats = task_tracker.get_stats()

	local lines = {}
	table.insert(lines, "📊 Task Tracking Statistics")
	table.insert(lines, "")
	table.insert(lines, string.format("Total Tasks: %d", stats.total_tasks))
	table.insert(lines, string.format("Completed: %d", stats.completed_tasks))
	table.insert(lines, string.format("Total XP Awarded: %d", stats.total_xp_awarded))
	table.insert(lines, "")
	table.insert(lines, "By Project:")

	for project, proj_stats in pairs(stats.tasks_by_project) do
		table.insert(
			lines,
			string.format(
				"  • %s: %d/%d tasks, %d XP",
				project,
				proj_stats.completed,
				proj_stats.total,
				proj_stats.xp
			)
		)
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
