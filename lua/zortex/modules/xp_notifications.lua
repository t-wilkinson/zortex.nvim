-- modules/xp_notifications.lua - Enhanced XP notifications and preview commands
local M = {}

local xp = require("zortex.modules.xp")
local xp_config = require("zortex.modules.xp_config")
local parser = require("zortex.core.parser")
local buffer = require("zortex.core.buffer")
local skills = require("zortex.modules.skills")

-- =============================================================================
-- Enhanced Notifications
-- =============================================================================

-- Create detailed XP notification with project and area info
function M.notify_xp_earned(xp_type, amount, details)
	local lines = {}

	-- Header with XP amount
	table.insert(lines, string.format("✨ +%d %s XP", amount, xp_type))
	table.insert(lines, "")

	-- Project info
	if details.project_name then
		table.insert(lines, string.format("📁 Project: %s", details.project_name))
		if details.task_position and details.total_tasks then
			table.insert(lines, string.format("   Progress: %d/%d tasks", details.task_position, details.total_tasks))
		end
	end

	-- Area links
	if details.area_links and #details.area_links > 0 then
		table.insert(lines, "")
		table.insert(lines, "🎯 Areas:")
		for _, area_link in ipairs(details.area_links) do
			local parsed = parser.parse_link_definition(area_link)
			if parsed then
				local area_path = xp.build_area_path(parsed.components)
				if area_path then
					-- Calculate area XP if applicable
					local area_xp = 0
					if xp_type == "Project" then
						local transfer_rate = xp_config.get("project.area_transfer_rate")
						area_xp = math.floor(amount * transfer_rate / #details.area_links)
					elseif xp_type == "Area" then
						area_xp = math.floor(amount / #details.area_links)
					end

					if area_xp > 0 then
						table.insert(lines, string.format("   • %s (+%d XP)", area_path, area_xp))
					else
						table.insert(lines, string.format("   • %s", area_path))
					end
				end
			end
		end
	end

	-- Season progress
	if xp_type == "Project" and details.season_info then
		table.insert(lines, "")
		table.insert(lines, string.format("🏆 Season: %s", details.season_info.name))
		table.insert(
			lines,
			string.format(
				"   Level %d → %d",
				details.season_info.old_level or details.season_info.level,
				details.season_info.level
			)
		)
		if details.season_info.tier then
			table.insert(lines, string.format("   Tier: %s", details.season_info.tier))
		end
	end

	-- Create multi-line notification
	local message = table.concat(lines, "\n")
	vim.notify(message, vim.log.levels.INFO, {
		title = "XP Earned!",
		timeout = 5000,
	})
end

-- =============================================================================
-- XP Preview Functions
-- =============================================================================

-- Preview XP for completing current task
function M.preview_task_xp()
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

	-- Find the project
	local project_heading = nil
	local project_line_num = nil
	local task_position = 1
	local total_tasks = 1

	for i = line_num - 1, 1, -1 do
		local heading = parser.parse_heading(lines[i])
		if heading then
			project_heading = heading
			project_line_num = i

			-- Count tasks
			local _, end_idx = buffer.find_section_bounds(lines, i)
			total_tasks = 0
			task_position = 0
			local found_our_task = false

			for j = i + 1, end_idx - 1 do
				local is_t, _ = parser.is_task_line(lines[j])
				if is_t then
					total_tasks = total_tasks + 1
					if j <= line_num then
						task_position = total_tasks
					end
					if j == line_num then
						found_our_task = true
					end
				end
			end

			break
		end
	end

	if not project_heading then
		vim.notify("Task not in a project", vim.log.levels.WARN)
		return
	end

	-- Calculate XP
	local task_xp = xp_config.calculate_task_xp(task_position, total_tasks)

	-- Get area links
	local area_links = skills.get_project_area_links(lines, project_line_num)

	-- Build preview message
	local preview_lines = {}
	table.insert(preview_lines, "📊 Task Completion Preview")
	table.insert(preview_lines, "")
	table.insert(preview_lines, string.format("Project: %s", project_heading.text))
	table.insert(preview_lines, string.format("Task Position: %d of %d", task_position, total_tasks))
	table.insert(preview_lines, "")
	table.insert(preview_lines, string.format("Project XP: +%d", task_xp))

	-- Special bonuses
	if task_position <= 3 then
		table.insert(preview_lines, "  ⚡ Initiation bonus!")
	elseif task_position == total_tasks then
		table.insert(preview_lines, "  🎉 Completion bonus!")
	end

	-- Area XP
	if #area_links > 0 then
		local transfer_rate = xp_config.get("project.area_transfer_rate")
		local area_xp = math.floor(task_xp * transfer_rate)
		local xp_per_area = math.floor(area_xp / #area_links)

		table.insert(preview_lines, "")
		table.insert(preview_lines, string.format("Area XP: +%d total", area_xp))
		for _, area_link in ipairs(area_links) do
			local parsed = parser.parse_link_definition(area_link)
			if parsed then
				local area_path = xp.build_area_path(parsed.components)
				if area_path then
					table.insert(preview_lines, string.format("  • %s: +%d", area_path, xp_per_area))
				end
			end
		end
	end

	vim.notify(table.concat(preview_lines, "\n"), vim.log.levels.INFO)
end

-- Preview XP for completing current project
function M.preview_project_xp()
	local bufnr = 0
	local line_num = vim.fn.line(".")
	local lines = buffer.get_lines(bufnr)

	-- Find current project
	local project_heading = nil
	local project_line_num = nil

	-- Check if we're on a heading
	local heading = parser.parse_heading(lines[line_num])
	if heading then
		project_heading = heading
		project_line_num = line_num
	else
		-- Search backwards for project
		for i = line_num - 1, 1, -1 do
			heading = parser.parse_heading(lines[i])
			if heading then
				project_heading = heading
				project_line_num = i
				break
			end
		end
	end

	if not project_heading then
		vim.notify("Not in a project", vim.log.levels.WARN)
		return
	end

	-- Count tasks
	local _, end_idx = buffer.find_section_bounds(lines, project_line_num)
	local total_tasks = 0
	local completed_tasks = 0
	local task_details = {}

	for i = project_line_num + 1, end_idx - 1 do
		local is_task, is_completed = parser.is_task_line(lines[i])
		if is_task then
			total_tasks = total_tasks + 1
			if is_completed then
				completed_tasks = completed_tasks + 1
			else
				-- Calculate XP for this uncompleted task
				local position = total_tasks
				local task_xp = xp_config.calculate_task_xp(position, total_tasks)
				table.insert(task_details, {
					position = position,
					xp = task_xp,
					line = lines[i]:match("^%s*%[.%]%s*(.+)$") or lines[i],
				})
			end
		end
	end

	-- Get total project XP
	local total_project_xp = 0
	for i = completed_tasks + 1, total_tasks do
		total_project_xp = total_project_xp + xp_config.calculate_task_xp(i, total_tasks)
	end

	-- Get area links
	local area_links = skills.get_project_area_links(lines, project_line_num)

	-- Build preview
	local preview_lines = {}
	table.insert(preview_lines, "📊 Project Completion Preview")
	table.insert(preview_lines, "")
	table.insert(preview_lines, string.format("Project: %s", project_heading.text))
	table.insert(preview_lines, string.format("Progress: %d/%d tasks completed", completed_tasks, total_tasks))
	table.insert(preview_lines, "")

	if #task_details > 0 then
		table.insert(preview_lines, "Remaining tasks:")
		for _, task in ipairs(task_details) do
			table.insert(
				preview_lines,
				string.format(
					"  [%d] %s: +%d XP",
					task.position,
					task.line:sub(1, 40) .. (task.line:len() > 40 and "..." or ""),
					task.xp
				)
			)
		end
		table.insert(preview_lines, "")
	end

	table.insert(preview_lines, string.format("Total Project XP: +%d", total_project_xp))

	-- Area XP
	if #area_links > 0 then
		local transfer_rate = xp_config.get("project.area_transfer_rate")
		local total_area_xp = math.floor(total_project_xp * transfer_rate)
		local xp_per_area = math.floor(total_area_xp / #area_links)

		table.insert(preview_lines, "")
		table.insert(preview_lines, string.format("Area XP: +%d total", total_area_xp))
		for _, area_link in ipairs(area_links) do
			local parsed = parser.parse_link_definition(area_link)
			if parsed then
				local area_path = xp.build_area_path(parsed.components)
				if area_path then
					table.insert(preview_lines, string.format("  • %s: +%d", area_path, xp_per_area))
				end
			end
		end
	end

	vim.notify(table.concat(preview_lines, "\n"), vim.log.levels.INFO)
end

-- =============================================================================
-- XP System Overview
-- =============================================================================

function M.show_xp_overview()
	local lines = {}

	table.insert(lines, "🎮 Zortex XP System Overview")
	table.insert(lines, "=" .. string.rep("=", 40))
	table.insert(lines, "")

	-- Dual XP System
	table.insert(lines, "📊 Dual XP System:")
	table.insert(lines, "")
	table.insert(lines, "1️⃣ Area XP (Long-term Mastery)")
	table.insert(lines, "   • Earned from completing objectives")
	table.insert(lines, "   • Uses exponential level curve (1000 * level^2.5)")
	table.insert(lines, "   • 75% bubbles up to parent areas")
	table.insert(lines, "   • Time horizon multipliers:")
	table.insert(lines, "     - Daily: 0.1x")
	table.insert(lines, "     - Weekly: 0.25x")
	table.insert(lines, "     - Monthly: 0.5x")
	table.insert(lines, "     - Quarterly: 1.0x")
	table.insert(lines, "     - Yearly: 3.0x")
	table.insert(lines, "     - 5-Year: 10.0x")
	table.insert(lines, "")

	table.insert(lines, "2️⃣ Project XP (Seasonal Momentum)")
	table.insert(lines, "   • Earned from completing tasks")
	table.insert(lines, "   • 3-stage reward structure:")
	table.insert(lines, "     - Initiation (tasks 1-3): 100 XP with 2x multiplier")
	table.insert(lines, "     - Execution (middle tasks): 20 XP each")
	table.insert(lines, "     - Completion (final task): 5x multiplier + 200 XP bonus")
	table.insert(lines, "   • 10% transfers to linked areas")
	table.insert(lines, "   • Seasonal levels: 100 * level^1.2")
	table.insert(lines, "")

	-- Current Status
	local status = xp.get_season_status()
	if status then
		table.insert(lines, "🏆 Current Season:")
		table.insert(lines, string.format("   • Name: %s", status.season.name))
		table.insert(
			lines,
			string.format(
				"   • Level: %d (%s Tier)",
				status.level,
				status.current_tier and status.current_tier.name or "None"
			)
		)
		table.insert(lines, string.format("   • XP: %d", status.xp))
		table.insert(lines, string.format("   • Progress to next: %.0f%%", status.progress_to_next * 100))
		table.insert(lines, "")
	end

	-- Area Stats
	local area_stats = xp.get_area_stats()
	if next(area_stats) then
		table.insert(lines, "🎯 Top Areas:")
		local sorted = {}
		for path, data in pairs(area_stats) do
			table.insert(sorted, { path = path, data = data })
		end
		table.sort(sorted, function(a, b)
			return a.data.xp > b.data.xp
		end)

		for i = 1, math.min(5, #sorted) do
			local item = sorted[i]
			table.insert(lines, string.format("   • %s - Level %d (%d XP)", item.path, item.data.level, item.data.xp))
		end
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
