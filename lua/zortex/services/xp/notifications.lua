-- services/xp/notifications.lua - XP and season messages
local M = {}

local Logger = require("zortex.core.logger")
local Events = require("zortex.core.event_bus")

function M.show_area_xp()
	return require("zortex.services.xp.stats").show_area_xp(10)
end

function M.start_season()
	return require("zortex.services.xp.stats").prompt_start_season()
end

function M.end_season()
	local season_record = require("zortex.services.xp.stats").end_season()
	if not season_record then
		vim.notify("No active season to end", vim.log.levels.WARN)
		return
	end
	local lines = {
		string.format("Season '%s' completed!", season_record.name),
		string.rep("─", 40),
		string.format("Objectives: %d%%", math.floor((season_record.final_progress or 0) * 100 + 0.5)),
		string.format("Tier: %s", season_record.final_tier or "none"),
	}
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Season Complete!", timeout = 10000 })
end

function M.init()
	Events.on("season:tier_reached", function(data)
		vim.notify(
			string.format("🏆 %s: %s (%d%% of the season's objectives)", data.season and data.season.name or "Season", data.tier and data.tier.name or "", math.floor((data.progress or 0) * 100 + 0.5)),
			vim.log.levels.INFO,
			{ title = "Season tier", timeout = 5000 }
		)
	end, { priority = 90, name = "xp_notifications.season_tier" })

	Events.on("area:leveled_up", function(data)
		vim.notify(
			string.format("🗺️ %s reached level %d", data.key:match("[^/]+$") or data.key, data.new_level),
			vim.log.levels.INFO,
			{ title = "Area Level Up!", timeout = 5000 }
		)
	end, { priority = 90, name = "xp_notifications.area_level_up" })

	Events.on("xp:awarded", function(data)
		Logger.info("xp:awarded", "xp", data)
		local cfg = (require("zortex.config").xp or {}).notify_min or 5
		if data.amount >= cfg then
			vim.notify(string.format("✨ +%d Mastery XP", data.amount), vim.log.levels.INFO, { title = "XP Gained", timeout = 3000 })
		end
	end, { priority = 80, name = "xp_notifications.xp_awarded" })
end

return M
