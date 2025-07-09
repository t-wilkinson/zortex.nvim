-- features/progress.lua - Progress tracking updated for new XP system
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")
local constants = require("zortex.constants")
local skills = require("zortex.modules.skills")
local xp = require("zortex.modules.xp")

-- =============================================================================
-- Progress Attribute Management
-- =============================================================================

local function update_progress_attribute(line, completed, total)
	local cleaned = line:gsub(" " .. constants.PATTERNS.PROGRESS, "")

	if total > 0 then
		return cleaned .. string.format(" @progress(%d/%d)", completed, total)
	else
		return cleaned
	end
end

local function update_done_attribute(line, done)
	local cleaned = line:gsub(" " .. constants.PATTERNS.DONE_DATE, "")

	if done then
		local date = os.date("%Y-%m-%d")
		return cleaned .. string.format(" @done(%s)", date)
	else
		return cleaned
	end
end

-- =============================================================================
-- Project Progress Tracking
-- =============================================================================

local function count_project_tasks(lines, start_idx, end_idx, level)
	local total = 0
	local completed = 0
	local task_positions = {}

	for i = start_idx + 1, end_idx - 1 do
		local line = lines[i]

		-- Check if we've hit a subproject
		local heading_level = parser.get_heading_level(line)

		-- Only count immediate tasks
		if heading_level == 0 or heading_level > level then
			local is_task, is_completed = parser.is_task_line(line)
			if is_task then
				total = total + 1
				if is_completed then
					completed = completed + 1
				end
				-- Store task position info
				table.insert(task_positions, {
					line_num = i,
					position = total,
					completed = is_completed,
				})
			end
		end
	end

	return total, completed, task_positions
end

function M.update_project_progress(bufnr)
	bufnr = bufnr or 0
	local lines = buffer.get_lines(bufnr)
	local modified = false

	-- Reload XP state to ensure we have the latest data
	xp.load_state()

	-- Batch XP awards to avoid notification spam
	local xp_awards = {
		tasks = {},
		projects = {},
		total_xp = 0,
	}

	-- Get all headings
	local headings = buffer.get_all_headings(bufnr)

	local count = 0
	for _ in pairs(headings) do
		count = count + 1
	end

	for i, heading_info in ipairs(headings) do
		local lnum = heading_info.lnum
		local level = heading_info.level

		-- Find the end of this section
		local end_idx = #lines + 1
		for j = i + 1, #headings do
			if headings[j].level <= level then
				end_idx = headings[j].lnum
				break
			end
		end

		-- Count tasks and get positions
		local total, completed, task_positions = count_project_tasks(lines, lnum, end_idx, level)

		-- Get area links for this project
		local area_links = skills.get_project_area_links(lines, lnum)

		-- Award XP for tasks that became "[x]" since the last save
		local prev_completed = xp.get_project_completed_tasks(heading_info.text)

		-- Only process if there are new completions
		if completed > prev_completed and total > 0 then
			-- Calculate XP for all newly completed tasks
			local project_xp = 0
			for pos = prev_completed + 1, completed do
				local task_xp = skills.process_task_completion(heading_info.text, pos, total, area_links, true) -- true = silent mode
				project_xp = project_xp + (task_xp or 0)
			end

			-- Store for batch notification
			if project_xp > 0 then
				table.insert(xp_awards.tasks, {
					project = heading_info.text,
					count = completed - prev_completed,
					xp = project_xp,
					area_links = area_links,
				})
				xp_awards.total_xp = xp_awards.total_xp + project_xp
			end
		end

		-- Update the heading line
		local old_line = lines[lnum]
		local new_line = update_progress_attribute(old_line, completed, total)

		-- Mark as done if all tasks completed
		if total > 0 and completed == total and not old_line:match(constants.PATTERNS.DONE_DATE) then
			new_line = update_done_attribute(new_line, true)

			-- Award completion bonus if area links exist and project wasn't already completed
			if #area_links > 0 and prev_completed < total then
				local bonus_xp = skills.process_task_completion(heading_info.text, total, total, area_links, true)
				table.insert(xp_awards.projects, {
					name = heading_info.text,
					xp = bonus_xp or 0,
				})
			end
		elseif total > 0 and completed < total and old_line:match(constants.PATTERNS.DONE_DATE) then
			-- Remove done if tasks were added after completion
			new_line = update_done_attribute(new_line, false)
		end

		if new_line ~= old_line then
			lines[lnum] = new_line
			modified = true
		end

		-- Update the XP system's completed task count to match reality
		-- This ensures the count stays in sync even if state was corrupted
		xp.sync_project_completed_tasks(heading_info.text, completed)
	end

	-- Show batch notification if any XP was earned
	if xp_awards.total_xp > 0 then
		local notification_lines = {}
		table.insert(notification_lines, string.format("✨ Progress Update: +%d XP Total", xp_awards.total_xp))

		if #xp_awards.tasks > 0 then
			table.insert(notification_lines, "")
			table.insert(notification_lines, "📋 Tasks Completed:")
			for _, award in ipairs(xp_awards.tasks) do
				table.insert(
					notification_lines,
					string.format(
						"  • %s: %d task%s (+%d XP)",
						award.project,
						award.count,
						award.count > 1 and "s" or "",
						award.xp
					)
				)
			end
		end

		if #xp_awards.projects > 0 then
			table.insert(notification_lines, "")
			table.insert(notification_lines, "🎉 Projects Completed:")
			for _, project in ipairs(xp_awards.projects) do
				table.insert(notification_lines, string.format("  • %s (+%d XP bonus)", project.name, project.xp))
			end
		end

		vim.notify(table.concat(notification_lines, "\n"), vim.log.levels.INFO)
	end

	if modified then
		buffer.set_lines(bufnr, 0, -1, lines)
	end

	-- Save XP state after all updates
	xp.save_state()

	return modified
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
				local new_line = update_progress_attribute(old_line, objective_kr_completed, objective_kr_count)

				-- Check if objective was just completed
				local was_completed = old_line:match(constants.PATTERNS.DONE_DATE) ~= nil
				local is_completed = objective_kr_count > 0 and objective_kr_completed == objective_kr_count

				if is_completed and not was_completed then
					new_line = update_done_attribute(new_line, true)

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
		local new_line = update_progress_attribute(old_line, objective_kr_completed, objective_kr_count)

		local was_completed = old_line:match(constants.PATTERNS.DONE_DATE) ~= nil
		local is_completed = objective_kr_count > 0 and objective_kr_completed == objective_kr_count

		if is_completed and not was_completed then
			new_line = update_done_attribute(new_line, true)

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
-- Task Completion Command
-- =============================================================================

function M.complete_current_task()
	local bufnr = 0
	local line_num = vim.fn.line(".")
	local lines = buffer.get_lines(bufnr)
	local line = lines[line_num]

	-- Check if it's a task
	local is_task, is_completed = parser.is_task_line(line)
	if not is_task then
		vim.notify("Not on a task line", vim.log.levels.WARN)
		return
	end

	if is_completed then
		vim.notify("Task already completed", vim.log.levels.INFO)
		return
	end

	-- Mark task as complete
	local new_line = line:gsub("%[%s*%]", "[x]")
	lines[line_num] = new_line
	buffer.set_lines(bufnr, 0, -1, lines)

	-- Find the project this task belongs to
	local project_heading = nil
	local project_line_num = nil
	local task_position = 1
	local total_tasks = 1

	for i = line_num - 1, 1, -1 do
		local heading = parser.parse_heading(lines[i])
		if heading then
			project_heading = heading
			project_line_num = i

			-- Count tasks in this project
			local _, end_idx = buffer.find_section_bounds(lines, i)
			local t, c, positions = count_project_tasks(lines, i, end_idx, heading.level)
			total_tasks = t

			-- Find our task position
			for _, pos_info in ipairs(positions) do
				if pos_info.line_num == line_num then
					task_position = pos_info.position
					break
				end
			end

			break
		end
	end

	if project_heading and project_line_num then
		-- Get area links for the project
		local area_links = skills.get_project_area_links(lines, project_line_num)

		if #area_links > 0 then
			-- Award XP for task completion
			local xp_awarded =
				skills.process_task_completion(project_heading.text, task_position, total_tasks, area_links)

			vim.notify(string.format("Task complete! +%d XP", xp_awarded), vim.log.levels.INFO)

			-- Update project progress
			M.update_project_progress(bufnr)
		else
			vim.notify("Task completed (no area links for XP)", vim.log.levels.INFO)
		end
	else
		vim.notify("Task completed", vim.log.levels.INFO)
	end
end

-- =============================================================================
-- Auto-update Setup
-- =============================================================================

function M.setup_autocmd()
	vim.api.nvim_create_autocmd("BufWritePre", {
		pattern = "*.zortex",
		callback = function(args)
			local filename = vim.fn.expand("%:t")

			if filename == "projects.zortex" then
				M.update_project_progress(args.buf)
				M.update_okr_progress()
			elseif filename == "okr.zortex" then
				M.update_okr_progress()
			end
		end,
		group = vim.api.nvim_create_augroup("ZortexProgress", { clear = true }),
	})
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

return M
