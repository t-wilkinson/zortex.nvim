-- services/xp/season.lua - Manage seasons

local M = {}

local Events = require("zortex.core.event_bus")
local xp_store = require("zortex.stores.xp")
local xp_calculator = require("zortex.services.xp.calculator")

-- Season management
function M.start_season(name, end_date)
	xp_store.start_season(name, end_date)

	Events.emit("season:started", {
		name = name,
		end_date = end_date,
	})
end

function M.end_season()
	local season_record = xp_store.end_season()

	if season_record then
		Events.emit("season:ended", {
			season = season_record,
		})
	end

	return season_record
end

function M.get_season_status()
	local season_data = xp_store.get_season_data()

	if not season_data.current_season then
		return nil
	end

	local tier_info = xp_calculator.get_season_tier(season_data.season_level)
	local progress = xp_calculator.get_level_progress(
		season_data.season_xp,
		season_data.season_level,
		xp_calculator.calculate_season_level_xp
	)

	return {
		season = season_data.current_season,
		level = season_data.season_level,
		xp = season_data.season_xp,
		current_tier = tier_info.current,
		next_tier = tier_info.next,
		is_max_tier = tier_info.is_max_tier,
		progress = progress,
	}
end

return M
