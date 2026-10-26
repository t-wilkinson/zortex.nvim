-- services/xp/season.lua - A season is progress on its objectives
--
-- The season (stores/xp: started by hand, else the calendar quarter) is a
-- date window. Its objectives are the ones whose window overlaps it
-- (3M-2026-Q4 for Q4 2026). Season progress is their progress weighted by
-- their value (calculator.objective_value: estimated hours x XP per hour),
-- so a large objective moves the season more than a small one, and every
-- task on a key result moves it a little. Tiers are thresholds on that
-- progress (xp.season.tiers); the last one is every objective done.
--
-- Season XP is the XP earned in the season's window by work a key result
-- links (and the key result and objective bonuses): the ledger's `season`
-- share of each award. Work no key result reaches earns none, however much
-- area XP it earns.
--
--   local S = require("zortex.services.xp.season")
--   S.status()   -- { season, progress, tier, tier_index, next_tier, objectives, value, season_xp, days_left }
local M = {}

local function cfg()
	return require("zortex.services.xp.calculator").conf()
end

--- "Season 10 Juniper" stays as it is; "2026 Q4" becomes "Season 2026 Q4".
function M.label(season)
	local name = season and season.name or "?"
	return name:match("^[Ss]eason") and name or ("Season " .. name)
end

--- The configured tiers, lowest first: { { name, at }, ... }
function M.tiers()
	local out = {}
	for _, t in ipairs((cfg().season or {}).tiers or {}) do
		if type(t) == "table" and t.name and tonumber(t.at) then
			out[#out + 1] = { name = t.name, at = tonumber(t.at) }
		end
	end
	table.sort(out, function(a, b)
		return a.at < b.at
	end)
	return out
end

--- The tier reached at `progress` (0..1): tier, its index (0: none yet),
--- and the next tier.
function M.tier_for(progress)
	local tiers = M.tiers()
	local current, index, nxt = nil, 0, nil
	for i, t in ipairs(tiers) do
		-- a hair of tolerance: 0.7 reached means 0.7, not 0.69999
		if progress >= t.at - 1e-9 then
			current, index = t, i
		else
			nxt = t
			break
		end
	end
	return current, index, nxt
end

local function overlaps(s1, e1, s2, e2)
	return s1 <= (e2 or "9999-12-31") and (e1 or "9999-12-31") >= s2
end

--- Objectives in the season's window: { { objective, value, progress, share } },
--- largest value first. share: the objective's part of the season (0..1).
function M.objectives(season)
	local calculator = require("zortex.services.xp.calculator")
	local ok, all = pcall(function()
		return require("zortex.services.okr").objectives()
	end)
	local out, total = {}, 0
	if not (ok and season) then
		return out, 0
	end
	for _, o in ipairs(all) do
		local s, e = o:window()
		if s and overlaps(s, e, season.start_date, season.end_date) then
			local value = calculator.objective_value(o)
			out[#out + 1] = { objective = o, value = value, progress = o:progress() }
			total = total + value
		end
	end
	for _, x in ipairs(out) do
		x.share = total > 0 and x.value / total or 0
	end
	table.sort(out, function(a, b)
		return a.value > b.value
	end)
	return out, total
end

local function days_left(end_date)
	local y, m, d = (end_date or ""):match("(%d+)-(%d+)-(%d+)")
	if not y then
		return nil
	end
	return math.ceil((os.time({ year = y, month = m, day = d, hour = 23 }) - os.time()) / 86400)
end

--- The season now (or `season`) and how far its objectives are; nil
--- without a season.
function M.status(season)
	season = season or require("zortex.stores.xp").current_season()
	if not season then
		return nil
	end
	local objectives, total = M.objectives(season)
	local done = 0
	for _, x in ipairs(objectives) do
		done = done + x.value * x.progress
	end
	local progress = total > 0 and done / total or 0
	local tier, index, nxt = M.tier_for(progress)
	local season_xp = 0
	local ok, l = pcall(function()
		return require("zortex.services.xp.ledger").get({ cached = true })
	end)
	if ok and l then
		local from, to = season.start_date or "0000-00-00", season.end_date or "9999-12-31"
		for _, e in ipairs(l.entries) do
			if e.date and e.date >= from and e.date <= to then
				season_xp = season_xp + (e.season or 0)
			end
		end
	end
	return {
		season = season,
		progress = progress,
		tier = tier,
		tier_index = index,
		next_tier = nxt,
		objectives = objectives,
		value = total,
		value_done = done,
		season_xp = season_xp,
		days_left = days_left(season.end_date),
	}
end

return M
