-- features/progress.lua - Progress tracking system for Zortex
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")
local constants = require("zortex.constants")

-- Forward declaration - will be set after skills module loads
local skills = nil

-- =============================================================================
-- Progress Attribute Management
-- =============================================================================

-- Update progress attribute on a heading line
local function update_progress_attribute(line, completed, total)
	-- Remove existing progress attribute
	local cleaned = line:gsub(constants.PATTERNS.PROGRESS, "")

	-- Add new progress attribute
	if total > 0 then
		return cleaned .. string.format(" @progress(%d/%d)", completed, total)
	else
		return cleaned
	end
end

-- Update done attribute on a heading line
local function update_done_attribute(line, done)
	-- Remove existing done attribute
	local cleaned = line:gsub(constants.PATTERNS.DONE_DATE, "")

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

-- Count tasks in a project section
local function count_project_tasks(lines, start_idx, end_idx, level)
	local total = 0
	local completed = 0

	for i = start_idx + 1, end_idx - 1 do
		local line = lines[i]

		-- Check if we've hit a subproject
		local heading_level = parser.get_heading_level(line)

		-- Only count immediate tasks (not in subprojects)
		if heading_level == 0 or heading_level > level then
			local is_task, is_completed = parser.is_task_line(line)
			if is_task then
				total = total + 1
				if is_completed then
					completed = completed + 1
				end
			end
		end
	end

	return total, completed
end

-- Update progress for all projects in a buffer
function M.update_project_progress(bufnr)
	bufnr = bufnr or 0
	local lines = buffer.get_lines(bufnr)
	local modified = false

	-- Get all headings
	local headings = buffer.get_all_headings(bufnr)

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

		-- Count tasks
		local total, completed = count_project_tasks(lines, lnum, end_idx, level)

		-- Update the heading line
		local old_line = lines[lnum]
		local new_line = update_progress_attribute(old_line, completed, total)

		-- Mark as done if all tasks completed and has tasks
		if total > 0 and completed == total and not old_line:match(constants.PATTERNS.DONE_DATE) then
			new_line = update_done_attribute(new_line, true)
		elseif total > 0 and completed < total and old_line:match(constants.PATTERNS.DONE_DATE) then
			-- Remove done if tasks were added after completion
			new_line = update_done_attribute(new_line, false)
		end

		if new_line ~= old_line then
			lines[lnum] = new_line
			modified = true
		end
	end

	if modified then
		buffer.set_lines(bufnr, 0, -1, lines)
	end

	return modified
end

-- =============================================================================
-- OKR Progress Tracking
-- =============================================================================

-- Find all projects linked in a key result line
local function extract_linked_projects(kr_line)
	local projects = {}
	local all_links = parser.extract_all_links(kr_line)

	for _, link_info in ipairs(all_links) do
		if link_info.type == "link" then
			local parsed = parser.parse_link_definition(link_info.definition)
			if parsed and #parsed.components > 0 then
				-- Look for article/project references
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

-- Check if a project is completed (has @done attribute)
local function is_project_completed(project_name)
	-- Search in projects.zortex
	local projects_file = fs.get_projects_file()
	if not projects_file or not fs.file_exists(projects_file) then
		return false, nil
	end

	local lines = fs.read_lines(projects_file)
	if not lines then
		return false, nil
	end

	-- Search for the project heading
	for _, line in ipairs(lines) do
		local heading = parser.parse_heading(line)
		if heading then
			-- Extract just the heading text without attributes
			local heading_text = heading.text:gsub(" @%w+%([^%)]*%)", ""):gsub(" @%w+", "")
			heading_text = parser.trim(heading_text)

			if heading_text:lower() == project_name:lower() then
				local done_date = line:match(constants.PATTERNS.DONE_DATE)
				return done_date ~= nil, done_date
			end
		end
	end

	-- Also check in archive
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
						return true, nil -- Archived projects are always done
					end
				end
			end
		end
	end

	return false, nil
end

-- Update OKR progress in the OKR file
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
	local objective_kr_newly_completed = {}

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

					-- Award skill tree XP for objective completion
					if skills then
						current_objective_data.line_text = old_line
						local skill_xp = skills.process_objective_completion(current_objective_data)
						vim.notify(
							string.format("OKR Objective completed! +%d Skill XP", skill_xp),
							vim.log.levels.INFO
						)
					end
				end

				if new_line ~= old_line then
					lines[current_objective_idx] = new_line
					modified = true
				end

				-- Process any newly completed KRs
				if skills then
					for _, kr_data in ipairs(objective_kr_newly_completed) do
						current_objective_data.completed_krs = kr_data.completed_krs
						current_objective_data.total_krs = objective_kr_count
						current_objective_data.line_text = old_line

						local skill_xp = skills.process_kr_completion(current_objective_data, kr_data.line)
						if skill_xp > 0 then
							vim.notify(
								string.format("Key Result completed! +%d Skill XP", skill_xp),
								vim.log.levels.INFO
							)
						end
					end
				end
			end

			-- Start tracking new objective
			current_objective_idx = i
			current_objective_data = okr_date
			objective_kr_count = 0
			objective_kr_completed = 0
			objective_kr_newly_completed = {}
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

					-- Track this as newly completed
					table.insert(objective_kr_newly_completed, {
						line = line,
						completed_krs = objective_kr_completed,
					})
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

			-- Award skill tree XP for objective completion
			if skills then
				current_objective_data.line_text = old_line
				local skill_xp = skills.process_objective_completion(current_objective_data)
				vim.notify(string.format("OKR Objective completed! +%d Skill XP", skill_xp), vim.log.levels.INFO)
			end
		end

		if new_line ~= old_line then
			lines[current_objective_idx] = new_line
			modified = true
		end

		-- Process any newly completed KRs
		if skills then
			for _, kr_data in ipairs(objective_kr_newly_completed) do
				current_objective_data.completed_krs = kr_data.completed_krs
				current_objective_data.total_krs = objective_kr_count
				current_objective_data.line_text = old_line

				local skill_xp = skills.process_kr_completion(current_objective_data, kr_data.line)
				if skill_xp > 0 then
					vim.notify(string.format("Key Result completed! +%d Skill XP", skill_xp), vim.log.levels.INFO)
				end
			end
		end
	end

	if modified then
		fs.write_lines(okr_file, lines)
	end

	return modified
end

-- =============================================================================
-- Auto-update Setup
-- =============================================================================

-- Setup autocmd for updating progress on buffer write
function M.setup_autocmd()
	vim.api.nvim_create_autocmd("BufWritePre", {
		pattern = "*.zortex",
		callback = function(args)
			local filename = vim.fn.expand("%:t")

			-- Update project progress for projects.zortex
			if filename == "projects.zortex" then
				M.update_project_progress(args.buf)
				-- Also update OKR progress since projects may have changed
				M.update_okr_progress()
			elseif filename == "okr.zortex" then
				-- Update OKR progress
				M.update_okr_progress()
			end
		end,
		group = vim.api.nvim_create_augroup("ZortexProgress", { clear = true }),
	})
end

-- =============================================================================
-- Manual Commands
-- =============================================================================

-- Update all progress (projects and OKRs)
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
-- Module Setup
-- =============================================================================

-- Set skills module reference (called by init module to avoid circular dependency)
function M.set_skills_module(skills_module)
	skills = skills_module
end

return M
