-- stores/xp.lua - Seasons, area levels and what was announced
--
-- XP itself is not stored: services/xp/ledger derives every award from the
-- notes, services/xp/season the season's progress. This store keeps what
-- can't be derived: a season started by hand (a name and a date window),
-- past seasons, and the area levels and season tier last announced (so each
-- is announced once).
--
-- Version 3: seasons have tiers from OKR progress instead of levels.
-- Version 2. Version 1 kept a transaction log and running totals that drifted
-- (season resets wiped the log but not the area totals, unchecking a
-- standalone task didn't remove its XP, ...); they are dropped on migration,
-- seasons are kept.
local M = {}

local Events = require("zortex.core.event_bus")
local State = require("zortex.core.state")

local store = State.open("xp_state", {
	version = 3,
	default = function()
		return {
			current_season = nil, -- { name, start_date, end_date, start_time }
			season_history = {}, -- { name, start_date, end_date, final_progress, final_tier }
			seen = { season = nil, season_tier = 0, area_levels = {} },
		}
	end,
	migrate = function(data)
		local history = {}
		for _, s in ipairs(data.season_history or {}) do
			history[#history + 1] = {
				name = s.name,
				start_date = s.start_date,
				end_date = s.end_date,
				final_progress = s.final_progress,
				final_tier = s.final_tier,
				-- seasons before version 3 were XP and levels
				final_level = s.final_level,
				final_xp = s.final_xp,
			}
		end
		return {
			current_season = data.current_season,
			season_history = history,
			seen = { season = nil, season_tier = 0, area_levels = (data.seen or {}).area_levels or {} },
		}
	end,
})

local cfg = {} -- Config.xp

function M.setup(opts)
	cfg = opts or {}
end

local function data()
	local d = store:get()
	d.seen = d.seen or { season_tier = 0, area_levels = {} }
	d.seen.area_levels = d.seen.area_levels or {}
	d.season_history = d.season_history or {}
	return d
end

-- =============================================================================
-- Level curves: XP to reach level L = base * L^exponent
-- =============================================================================

local function area_curve()
	return (cfg.area and cfg.area.level_curve) or { base = 316, exponent = 2.5 }
end

local function threshold(curve, level)
	if level <= 1 then
		return 0
	end
	return math.floor(curve.base * math.pow(level, curve.exponent))
end

-- Highest level whose threshold xp reaches (level 1 from 0 XP)
local function level_for(xp, curve)
	if not curve or curve.base <= 0 or curve.exponent <= 0 then
		return 1
	end
	local level = 1
	while level < 1000 and xp >= threshold(curve, level + 1) do
		level = level + 1
	end
	return level
end

function M.calculate_area_level_xp(level)
	return threshold(area_curve(), level)
end

function M.calculate_area_level(xp)
	return level_for(xp, area_curve())
end

--- { current_level, progress (0..1), xp_to_next, current_threshold, next_threshold }
function M.get_level_progress(xp, level, level_calc_fn)
	local current, next_t = level_calc_fn(level), level_calc_fn(level + 1)
	local span = next_t - current
	return {
		current_level = level,
		progress = span > 0 and math.max(0, math.min(1, (xp - current) / span)) or 1,
		xp_to_next = math.max(0, next_t - xp),
		current_threshold = current,
		next_threshold = next_t,
	}
end

-- =============================================================================
-- Seasons
-- =============================================================================

--- The season now: the one started with :ZortexSeasonStart while its end
--- date hasn't passed, else (xp.season.follow_quarter, the default) the
--- calendar quarter, the window of a 3M-YYYY-Qn objective, marked auto.
function M.current_season(today)
	today = today or os.date("%Y-%m-%d")
	local explicit = data().current_season
	if explicit and (not explicit.end_date or explicit.end_date >= today) then
		return explicit
	end
	if (cfg.season or {}).follow_quarter == false then
		return explicit
	end
	local q = require("zortex.services.okr.objective").quarter(today)
	q.auto = true
	return q
end

--- The season started by hand, if any (ended or not)
function M.started_season()
	return data().current_season
end

function M.season_history()
	return data().season_history
end

function M.start_season(name, end_date, start_date)
	local d = data()
	d.current_season = {
		name = name,
		start_date = start_date or os.date("%Y-%m-%d"),
		end_date = end_date,
		start_time = os.time(),
	}
	d.seen.season, d.seen.season_tier = nil, 0
	store:save()
	Events.emit("season:started", { name = name, end_date = end_date })
end

--- End the current season, archiving its final progress and tier
--- (computed by the caller, services/xp/season). Returns the record.
function M.end_season(final)
	local d = data()
	local season = d.current_season
	if not season then
		return nil
	end
	final = final or {}
	local record = {
		name = season.name,
		start_date = season.start_date,
		end_date = os.date("%Y-%m-%d"),
		planned_end_date = season.end_date,
		final_progress = final.progress or 0,
		final_tier = final.tier,
	}
	table.insert(d.season_history, record)
	d.current_season = nil
	d.seen.season, d.seen.season_tier = nil, 0
	store:save()
	Events.emit("season:ended", { season = record })
	return record
end

function M.reset_season()
	local d = data()
	d.current_season = nil
	d.seen.season, d.seen.season_tier = nil, 0
	store:save()
end

-- =============================================================================
-- Announced levels
-- =============================================================================

--- Record the season tier (by index, for the season named season_key) and
--- area levels just computed; returns what went up since last time:
--- { season = { old, new }?, areas = { { key, old, new }, ... } }
function M.update_seen(season_key, season_tier, area_levels)
	local seen = data().seen
	local ups = { areas = {} }
	if season_key then
		if seen.season ~= season_key then
			-- a new season: start from its current tier without announcing it
			seen.season, seen.season_tier = season_key, season_tier or 0
		elseif (season_tier or 0) > (seen.season_tier or 0) then
			ups.season = { old = seen.season_tier or 0, new = season_tier }
			seen.season_tier = season_tier
		else
			seen.season_tier = season_tier or 0
		end
	end
	for key, level in pairs(area_levels or {}) do
		local old = seen.area_levels[key]
		if old and level > old then
			ups.areas[#ups.areas + 1] = { key = key, old = old, new = level }
		end
		seen.area_levels[key] = level
	end
	store:save()
	return ups
end

function M.seen()
	return data().seen
end

function M.reload()
	store:reload()
end

function M.save()
	store:save()
end

return M
