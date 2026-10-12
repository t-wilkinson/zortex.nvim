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
		string.format("Final Level: %d", season_record.final_level),
		string.format("Total XP: %d", season_record.final_xp),
		string.format("Transactions: %d", vim.tbl_count(season_record.xp_transactions or {})),
	}
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Season Complete!", timeout = 10000 })
end

function M.init()
	Events.on("season:leveled_up", function(data)
		local message = string.format("🏆 Season Level Up!\nLevel %d", data.new_level)
		if data.tier_info and data.tier_info.current then
			message = message .. string.format("\nTier: %s", data.tier_info.current.name)
		end
		vim.notify(message, vim.log.levels.INFO, { title = "Level Up!", timeout = 5000 })
	end, { priority = 90, name = "xp_notifications.season_level_up" })

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
			local season = data.season_amount and data.season_amount > 0 and data.season_amount ~= data.amount
					and string.format(" (+%d season)", data.season_amount)
				or ""
			vim.notify(string.format("✨ +%d XP%s", data.amount, season), vim.log.levels.INFO, { title = "XP Gained", timeout = 3000 })
		end
	end, { priority = 80, name = "xp_notifications.xp_awarded" })
end

return M
