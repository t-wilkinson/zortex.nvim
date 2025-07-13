-- modules/xp_notifications.lua - Enhanced XP notifications and preview commands
local M = {}

local xp = require("zortex.modules.xp")
local xp_config = require("zortex.modules.xp_config")
local parser = require("zortex.core.parser")

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
