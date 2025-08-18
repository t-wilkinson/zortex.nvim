-- services/xp/notifications.lua - Enhanced XP notifications
local M = {}

local Events = require("zortex.core.event_bus")

-- =============================================================================
-- Task Progress Notifications
-- =============================================================================

function M.notify_progress_update(xp_changes, projects_completed)
	if #xp_changes == 0 and #projects_completed == 0 then
		return
	end

	local lines = {}
	local total_delta = 0

	-- Calculate total XP change
	for _, change in ipairs(xp_changes) do
		total_delta = total_delta + change.delta
	end

	-- Header
	if total_delta > 0 then
		table.insert(lines, string.format("✨ Progress Update: +%d XP", total_delta))
	elseif total_delta < 0 then
		table.insert(lines, string.format("⚠️  Progress Reverted: %d XP", total_delta))
	end

	-- Group changes by project
	local by_project = {}
	for _, change in ipairs(xp_changes) do
		local project = change.task.project or "No Project"
		if not by_project[project] then
			by_project[project] = {
				completed = 0,
				uncompleted = 0,
				xp = 0,
			}
		end

		local proj = by_project[project]
		if change.delta > 0 then
			proj.completed = proj.completed + 1
		else
			proj.uncompleted = proj.uncompleted + 1
		end
		proj.xp = proj.xp + change.delta
	end

	-- Show task changes
	if next(by_project) then
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
	end

	-- Show completed projects
	if #projects_completed > 0 then
		table.insert(lines, "")
		table.insert(lines, "🎉 Projects Completed:")
		for _, proj in ipairs(projects_completed) do
			table.insert(lines, string.format("  • %s (+%d XP)", proj.name, proj.xp))
		end
	end

	-- Show season progress if applicable
	local xp_service = require("zortex.services.xp")
	local season_status = xp_service.get_season_status()
	if season_status and total_delta > 0 then
		table.insert(lines, "")
		table.insert(lines, string.format("🏆 Season: %s", season_status.season.name))
		table.insert(
			lines,
			string.format("   Level %d (%.0f%% to next)", season_status.level, season_status.progress.progress * 100)
		)

		if season_status.current_tier then
			table.insert(lines, string.format("   Tier: %s", season_status.current_tier.name))
		end
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, {
		title = "XP Update",
		timeout = 5000,
	})
end

-- =============================================================================
-- Objective Completion Notifications
-- =============================================================================

function M.notify_objective_completion(objective_text, xp_awarded, area_awards)
	local lines = {}

	table.insert(lines, string.format("🎯 Objective Complete: +%d Area XP", xp_awarded))
	table.insert(lines, "")
	table.insert(lines, string.format("📝 %s", objective_text))

	if #area_awards > 0 then
		table.insert(lines, "")
		table.insert(lines, "🏔️  Areas:")
		for _, award in ipairs(area_awards) do
			table.insert(lines, string.format("  • %s (+%d XP)", award.path, award.xp))
		end
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, {
		title = "Objective Complete!",
		timeout = 5000,
	})
end

-- =============================================================================
-- XP System Overview
-- =============================================================================

-- Show XP overview
function M.show_xp_overview()
	local stats = xp_service.get_stats()
	local lines = {}

	table.insert(lines, "🎮 Zortex XP System (Project-Centric)")
	table.insert(lines, string.rep("─", 50))
	table.insert(lines, "")

	-- Season status
	if stats.season then
		table.insert(lines, "🏆 Current Season: " .. stats.season.season.name)
		table.insert(
			lines,
			string.format(
				"   Level %d (%s)",
				stats.season.level,
				stats.season.current_tier and stats.season.current_tier.name or "None"
			)
		)
		table.insert(lines, string.format("   Progress: %.1f%% to next level", stats.season.progress.progress * 100))
		table.insert(lines, string.format("   Total XP: %d", stats.season.xp))
		table.insert(lines, "")
	end

	-- XP sources breakdown
	table.insert(lines, "📊 XP Sources:")
	for source, percentage in pairs(stats.source_percentages) do
		local amount = stats.sources[source]
		table.insert(
			lines,
			string.format("   %s: %d XP (%.1f%%)", source:gsub("_", " "):gsub("^%l", string.upper), amount, percentage)
		)
	end
	table.insert(lines, "")

	-- Project statistics
	table.insert(lines, "📁 Projects:")
	table.insert(lines, string.format("   Active: %d", stats.totals.active_projects))
	table.insert(lines, string.format("   Completed: %d", stats.totals.completed_projects))
	table.insert(lines, "")

	-- Area statistics
	table.insert(lines, "🗺️ Areas:")
	table.insert(lines, string.format("   Total: %d", stats.totals.total_areas))
	table.insert(lines, string.format("   Average Level: %.1f", stats.totals.avg_area_level))

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, {
		title = "XP Overview",
		timeout = 10000,
	})
end

-- Show project XP details
function M.show_project_xp()
	local context = workspace.get_context()
	if not context then
		vim.notify("No workspace context", vim.log.levels.ERROR)
		return
	end

	-- Find current project
	local project_section = projects_service.find_project(context.section)
	if not project_section then
		vim.notify("Not in a project", vim.log.levels.WARN)
		return
	end

	local project = projects_service.get_project(project_section, context.doc)
	if not project then
		vim.notify("Could not get project data", vim.log.levels.ERROR)
		return
	end

	-- Get XP details
	local details = xp_store.get_project_details(project.name)
	local lines = {}

	table.insert(lines, string.format("📁 Project: %s", project.name))
	table.insert(lines, string.rep("─", 40))

	if details then
		table.insert(lines, string.format("Total XP: %d", details.total_xp))
		table.insert(lines, string.format("Earned XP: %d", details.earned_xp))
		table.insert(lines, string.format("Progress: %.1f%%", details.completion_percentage * 100))
		table.insert(lines, string.format("Tasks: %d", details.task_count))
		table.insert(lines, "")

		-- Task breakdown
		table.insert(lines, "Task Sizes:")
		local size_counts = {}
		local parser = require("zortex.utils.parser")
		local lines_in_project = project.section:get_lines(context.doc.bufnr)

		for _, line in ipairs(lines_in_project) do
			local task = parser.parse_task(line)
			if task then
				local size = task.attributes and task.attributes.size or "md"
				size_counts[size] = (size_counts[size] or 0) + 1
			end
		end

		for size, count in pairs(size_counts) do
			table.insert(lines, string.format("  %s: %d tasks", size:upper(), count))
		end
	else
		table.insert(lines, "No XP data yet - complete some tasks!")
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, {
		title = "Project XP",
		timeout = 5000,
	})
end

-- function M.show_xp_overview()
-- 	local xp_service = require("zortex.services.xp")
-- 	local lines = {}
--
-- 	table.insert(lines, "🎮 Zortex XP System")
-- 	table.insert(lines, string.rep("─", 40))
-- 	table.insert(lines, "")
--
-- 	-- Dual XP System
-- 	table.insert(lines, "📊 Dual XP System:")
-- 	table.insert(lines, "")
-- 	table.insert(lines, "1️⃣  Area XP (Long-term Mastery)")
-- 	table.insert(lines, "   • From objectives & key results")
-- 	table.insert(lines, "   • Level curve: 1000 × level^2.5")
-- 	table.insert(lines, "   • 75% bubbles to parent areas")
-- 	table.insert(lines, "   • Time multipliers: 0.1x-10x")
-- 	table.insert(lines, "")
--
-- 	table.insert(lines, "2️⃣  Project XP (Seasonal Progress)")
-- 	table.insert(lines, "   • From completing tasks")
-- 	table.insert(lines, "   • Early tasks: 2x multiplier")
-- 	table.insert(lines, "   • Final task: 5x + 200 bonus")
-- 	table.insert(lines, "   • 10% transfers to areas")
-- 	table.insert(lines, "   • Season levels: 100 × level^1.2")
-- 	table.insert(lines, "")
--
-- 	-- Current Status
-- 	local season_status = xp_service.get_season_status()
-- 	if season_status then
-- 		table.insert(lines, "🏆 Current Season:")
-- 		table.insert(lines, string.format("   Name: %s", season_status.season.name))
-- 		table.insert(
-- 			lines,
-- 			string.format(
-- 				"   Level: %d (%s)",
-- 				season_status.level,
-- 				season_status.current_tier and season_status.current_tier.name or "None"
-- 			)
-- 		)
-- 		table.insert(lines, string.format("   Progress: %.0f%%", season_status.progress.progress * 100))
--
-- 		if season_status.next_tier and not season_status.is_max_tier then
-- 			table.insert(
-- 				lines,
-- 				string.format(
-- 					"   Next tier: %s (Level %d)",
-- 					season_status.next_tier.name,
-- 					season_status.next_tier.required_level
-- 				)
-- 			)
-- 		end
-- 	else
-- 		table.insert(lines, "No active season")
-- 	end
--
-- 	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
-- end

-- =============================================================================
-- Level Up Notifications
-- =============================================================================

function M.init()
	-- Area level up notification
	Events.on("area:leveled_up", function(data) -- Changed from "xp:area_level_up"
		vim.notify(
			string.format("🎯 Area Level Up!\n%s → Level %d", data.path, data.new_level), -- Changed area_path to path
			vim.log.levels.INFO,
			{ title = "Level Up!", timeout = 5000 }
		)
	end, {
		priority = 90,
		name = "xp_notifications.area_level_up",
	})

	-- Season level up notification
	Events.on("season:leveled_up", function(data)
		local message = string.format("🏆 Season Level Up!\nLevel %d", data.new_level)

		if data.tier_info and data.tier_info.current then
			message = message .. string.format("\nTier: %s", data.tier_info.current.name)
		end

		vim.notify(message, vim.log.levels.INFO, { title = "Level Up!", timeout = 5000 })
	end, {
		priority = 90,
		name = "xp_notifications.season_level_up",
	})

	-- XP awarded notification
	Events.on("xp:awarded", function(data)
		if data.amount >= 20 then -- Only notify for significant XP
			vim.notify(
				string.format("✨ XP Earned: +%d XP", data.amount),
				vim.log.levels.INFO,
				{ title = "XP Gained", timeout = 3000 }
			)
		end
	end, {
		priority = 80,
		name = "xp_notifications.xp_awarded",
	})
end

return M
