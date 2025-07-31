-- notifications/types/xp.lua - Enhanced XP notifications
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

function M.show_xp_overview()
	local xp_service = require("zortex.services.xp")
	local lines = {}

	table.insert(lines, "🎮 Zortex XP System")
	table.insert(lines, string.rep("─", 40))
	table.insert(lines, "")

	-- Dual XP System
	table.insert(lines, "📊 Dual XP System:")
	table.insert(lines, "")
	table.insert(lines, "1️⃣  Area XP (Long-term Mastery)")
	table.insert(lines, "   • From objectives & key results")
	table.insert(lines, "   • Level curve: 1000 × level^2.5")
	table.insert(lines, "   • 75% bubbles to parent areas")
	table.insert(lines, "   • Time multipliers: 0.1x-10x")
	table.insert(lines, "")

	table.insert(lines, "2️⃣  Project XP (Seasonal Progress)")
	table.insert(lines, "   • From completing tasks")
	table.insert(lines, "   • Early tasks: 2x multiplier")
	table.insert(lines, "   • Final task: 5x + 200 bonus")
	table.insert(lines, "   • 10% transfers to areas")
	table.insert(lines, "   • Season levels: 100 × level^1.2")
	table.insert(lines, "")

	-- Current Status
	local season_status = xp_service.get_season_status()
	if season_status then
		table.insert(lines, "🏆 Current Season:")
		table.insert(lines, string.format("   Name: %s", season_status.season.name))
		table.insert(
			lines,
			string.format(
				"   Level: %d (%s)",
				season_status.level,
				season_status.current_tier and season_status.current_tier.name or "None"
			)
		)
		table.insert(lines, string.format("   Progress: %.0f%%", season_status.progress.progress * 100))

		if season_status.next_tier and not season_status.is_max_tier then
			table.insert(
				lines,
				string.format(
					"   Next tier: %s (Level %d)",
					season_status.next_tier.name,
					season_status.next_tier.required_level
				)
			)
		end
	else
		table.insert(lines, "No active season")
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- =============================================================================
-- Level Up Notifications
-- =============================================================================

function M.setup()
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
		if data.amount >= 10 then -- Only notify for significant XP
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
