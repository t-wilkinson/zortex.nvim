-- services/xp/publish.lua - Hand the XP summary to the web app
--
-- `zortex serve` can't read the ledger (it lives in Neovim), so after every
-- XP refresh a small summary is published:
--
--   notes_dir/.z/xp_summary.<device>.json   synced along with the notes
--   POST <server>/api/xp                    when Config.server is enabled (immediate)
--
-- Each device writes its own file (core/state device_name: the host name,
-- or Config.device), so two Neovims never write the same synced file; the
-- server shows the newest of them and of what was POSTed. Nothing is
-- written or sent when the summary didn't change. Conflict copies of these
-- files (derived data) are deleted.
local M = {}

local last_body = nil

local function round(x)
	return math.floor(x + 0.5)
end

--- The summary: the season (progress on its objectives, its season XP),
--- area XP per day (14 days; `days`: 60 days of area, season and work XP and
--- how the work served the plan), top areas, every area (`area_tree`) and
--- their total, recent awards, and the calibration (XP per hour, hours per
--- task @size, priority and importance multipliers, the default area).
function M.summary()
	local q = require("zortex.query").xp({ days = 30, limit = 8 })
	local today, week = 0, 0
	for i, d in ipairs(q.daily) do
		if i == #q.daily then
			today = d.xp
		end
		if i > #q.daily - 7 then
			week = week + d.xp
		end
	end
	local areas = {}
	for i, a in ipairs(q.areas) do
		if i > 6 then
			break
		end
		areas[#areas + 1] = {
			key = a.key,
			name = a.name,
			xp = a.xp,
			level = a.level,
			progress = a.progress,
			xp_to_next = a.xp_to_next,
		}
	end
	local awards = {}
	for _, e in ipairs(q.awards) do
		awards[#awards + 1] = {
			date = e.date,
			xp = round(e.mastery or 0),
			effort = round(e.xp),
			season = round(e.season or 0),
			aligned = e.aligned,
			title = e.title,
			source = e.source,
			project = e.project,
			rel = e.rel,
			lnum = e.lnum,
		}
	end
	local history = {}
	for i = #q.history, math.max(1, #q.history - 3), -1 do
		local h = q.history[i]
		history[#history + 1] = {
			name = h.name,
			final_progress = h.final_progress,
			final_tier = h.final_tier,
			end_date = h.end_date,
		}
	end
	-- how the server estimates XP for tasks completed on the web before
	-- Neovim counts them, and weighs project progress (task @size hours)
	local calc = require("zortex.services.xp.calculator")
	local task_hours = {}
	for _, size in ipairs({ "xs", "sm", "md", "lg", "xl", "2xl", "3xl", "4xl", "5xl" }) do
		task_hours[size] = calc.hours("task", size)
	end
	local calibration = {
		xp_per_hour = calc.xp_per_hour(),
		task_hours = task_hours,
		default_size = require("zortex.constants").DEFAULT_TASK_SIZE,
		default_area = calc.default_area_value() or "",
		area_transfer = calc.area_transfer(),
		season_transfer = calc.season_transfer(),
		priority = {},
		importance = {},
	}
	for _, n in ipairs({ "1", "2", "3" }) do
		calibration.priority[n] = calc.get_priority_multiplier(n)
		calibration.importance[n] = calc.get_importance_multiplier(n)
	end
	return {
		-- 2: the season is progress on its objectives (no levels); 3: area XP
		-- and season XP apart, the whole area tree, 60 days of totals
		version = 3,
		calibration = calibration,
		season = q.season,
		today = today,
		week = week,
		daily = q.daily,
		days = require("zortex.services.xp.stats").daily(60),
		areas = areas,
		area_tree = q.area_tree,
		area_total = q.area_total,
		awards = awards,
		history = history,
	}
end

--- This device's summary file.
function M.path()
	local State = require("zortex.core.state")
	return State.path("xp_summary." .. State.device_name())
end

local function write_file(body)
	local State = require("zortex.core.state")
	for _, copy in ipairs(State.conflict_copies(State.path("xp_summary"))) do
		os.remove(copy) -- derived: the next publish says the same
	end
	return State.write_file(M.path(), body)
end

--- Publish the summary if it changed. opts.force publishes regardless.
function M.publish(opts)
	local ok, summary = pcall(M.summary)
	if not ok then
		require("zortex.core.logger").error("xp", "summary failed", { error = summary })
		return false
	end
	local body = vim.json.encode(summary)
	if body == last_body and not (opts and opts.force) then
		return false
	end
	last_body = body
	summary.generated = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local full = vim.json.encode(summary)
	write_file(full)
	local server = require("zortex.notifications.server")
	if server.enabled() then
		server.request("POST", "/api/xp", summary, function(sent, _, err)
			if not sent then
				require("zortex.core.logger").warn("xp", "publish to server failed", { error = err })
				last_body = nil -- retry next time
			end
		end, { timeout = 10 })
	end
	return true
end

--- Forget what was last published (tests).
function M._reset()
	last_body = nil
end

return M
