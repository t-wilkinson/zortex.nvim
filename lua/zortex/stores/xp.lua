-- stores/xp.lua - Seasons, area levels and what was announced
--
-- XP itself is not stored: services/xp/ledger derives every award from the
-- notes, services/xp/season the season's progress. This store keeps what
-- can't be derived, in two files (core/state):
--
--   xp_state  synced: a season started by hand (a name and a date window)
--             and past seasons. Written only when a season starts or ends;
--             conflict copies from two devices are merged (merge_seasons).
--   xp_seen   this machine's: the area levels and season tier last
--             announced, so each is announced once per device. It changes
--             on every XP refresh, so it never travels with the notes.
local M = {}

local Events = require("zortex.core.event_bus")
local State = require("zortex.core.state")

local function season_key(s)
	return (s.name or "") .. "|" .. (s.start_date or "")
end

--- Two copies of the seasons (a sync conflict) as one: every past season
--- of either, and the current season started last unless it has ended in
--- either copy.
function M.merge_seasons(mine, other)
	local out = { version = mine.version, season_history = {} }
	local seen = {}
	for _, list in ipairs({ mine.season_history or {}, other.season_history or {} }) do
		for _, record in ipairs(list) do
			local key = season_key(record)
			if not seen[key] then
				seen[key] = true
				out.season_history[#out.season_history + 1] = record
			end
		end
	end
	table.sort(out.season_history, function(a, b)
		return (a.end_date or "") < (b.end_date or "")
	end)
	local current
	for _, c in ipairs({ mine.current_season or false, other.current_season or false }) do
		if c and not seen[season_key(c)] and (not current or (c.start_time or 0) > (current.start_time or 0)) then
			current = c
		end
	end
	out.current_season = current
	return out
end

local store = State.open("xp_state", {
	version = 3,
	default = function()
		return {
			current_season = nil, -- { name, span, start_date, end_date, start_time }
			season_history = {}, -- { name, span, start_date, end_date, final_progress, final_tier }
		}
	end,
	merge = M.merge_seasons,
})

local seen_store = State.open("xp_seen", {
	version = 1,
	device = true,
	default = function()
		return { season = nil, season_tier = 0, area_levels = {} }
	end,
})

local cfg = {} -- Config.xp

function M.setup(opts)
	cfg = opts or {}
end

local function data()
	local d = store:get()
	d.season_history = d.season_history or {}
	return d
end

-- What was announced on this machine. Older versions kept it in xp_state
-- (synced): it moves here the first time, and leaves xp_state at its next
-- save.
local function seen()
	local s = seen_store:get()
	local d = store:get()
	if d.seen then
		if next(s.area_levels or {}) == nil and s.season == nil then
			s.season, s.season_tier, s.area_levels = d.seen.season, d.seen.season_tier, d.seen.area_levels
		end
		d.seen = nil
	end
	s.area_levels = s.area_levels or {}
	s.season_tier = s.season_tier or 0
	return s
end

local function forget_season_seen()
	local s = seen()
	s.season, s.season_tier = nil, 0
	seen_store:save()
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

--- The season now: the one started with :ZortexSeason start while its end
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
	q.span = require("zortex.services.okr").quarter_span(today)
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

--- Start a season: its name, its window, and the span it was given as
--- ("3M-2026-Q4", as objectives write theirs).
function M.start_season(name, end_date, start_date, span)
	local d = data()
	d.current_season = {
		name = name,
		span = span,
		start_date = start_date or os.date("%Y-%m-%d"),
		end_date = end_date,
		start_time = os.time(),
	}
	store:save()
	forget_season_seen()
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
		span = season.span,
		start_date = season.start_date,
		end_date = os.date("%Y-%m-%d"),
		planned_end_date = season.end_date,
		final_progress = final.progress or 0,
		final_tier = final.tier,
	}
	table.insert(d.season_history, record)
	d.current_season = nil
	store:save()
	forget_season_seen()
	Events.emit("season:ended", { season = record })
	return record
end

function M.reset_season()
	local d = data()
	d.current_season = nil
	store:save()
	forget_season_seen()
end

-- =============================================================================
-- Announced levels
-- =============================================================================

--- Record the season tier (by index, for the season named season_key) and
--- area levels just computed; returns what went up since last time:
--- { season = { old, new }?, areas = { { key, old, new }, ... } }
function M.update_seen(current_key, season_tier, area_levels)
	local s = seen()
	local ups = { areas = {} }
	if current_key then
		if s.season ~= current_key then
			-- a new season: start from its current tier without announcing it
			s.season, s.season_tier = current_key, season_tier or 0
		elseif (season_tier or 0) > (s.season_tier or 0) then
			ups.season = { old = s.season_tier or 0, new = season_tier }
			s.season_tier = season_tier
		else
			s.season_tier = season_tier or 0
		end
	end
	for key, level in pairs(area_levels or {}) do
		local old = s.area_levels[key]
		if old and level > old then
			ups.areas[#ups.areas + 1] = { key = key, old = old, new = level }
		end
		s.area_levels[key] = level
	end
	seen_store:save() -- written only when something changed (core/state)
	return ups
end

return M
