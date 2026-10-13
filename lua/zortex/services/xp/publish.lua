-- services/xp/publish.lua - Hand the XP summary to the web app
--
-- `zortex serve` can't read the ledger (it lives in Neovim), so after every
-- XP refresh a small summary is published:
--
--   notes_dir/.z/xp_summary.json   synced along with the notes
--   POST <server>/api/xp           when Config.server is enabled (immediate)
--
-- The home page shows whichever is newer. Nothing is written or sent when
-- the summary didn't change.
local M = {}

local last_body = nil

local function round(x)
	return math.floor(x + 0.5)
end

--- The summary: the season (progress on its objectives), Mastery XP per day
--- (14 days), top areas, recent awards.
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
	return {
		version = 2, -- 2: the season is progress on its objectives (no levels)
		season = q.season,
		today = today,
		week = week,
		daily = q.daily,
		areas = areas,
		awards = awards,
		history = history,
	}
end

local function write_file(body)
	local path = require("zortex.core.state").path("xp_summary")
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local tmp = path .. ".tmp." .. vim.uv.getpid()
	local f = io.open(tmp, "w")
	if not f then
		return false
	end
	f:write(body)
	f:close()
	return os.rename(tmp, path)
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
