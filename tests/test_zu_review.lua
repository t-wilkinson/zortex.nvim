local T = require("helpers")
local review = require("zortex.ui.review")

local TODAY = "2026-10-11"

local function find(lines, pattern)
	for i, l in ipairs(lines) do
		if l:find(pattern, 1, true) then
			return i, l
		end
	end
end

T.test("render: sections with counts and links", function()
	local r = require("zortex.services.agenda").review({ today = TODAY, days = 7 })
	local lines, locations = review.render(r)
	T.eq(lines[1], "@@Weekly Review")
	T.ok(find(lines, "## Overdue (2)"), "overdue header")
	T.ok(find(lines, "## Due soon (1)"), "due soon header")
	T.ok(find(lines, "## Completed (2)"), "completed header")
	T.ok(find(lines, "## Stale: no calendar time behind or ahead (s schedules, n next action, z someday, a archives a done one) (3)"), "stale header")
	-- unscheduled excludes the stale ones
	T.ok(find(lines, "## Unscheduled: open work, nothing on the calendar ahead (3)"), "unscheduled header")
	T.ok(find(lines, "## Broken links (F: fix from the search) (1)"), "broken links header")

	local i, line = find(lines, "Change task sizes")
	T.ok(line:find("[P/#1 Programming/#1.4 - zortex]", 1, true), line) -- due task links its project
	T.eq(locations[i].lnum > 0, true)

	local _, kr = find(lines, "/-KR1] ")
	T.ok(kr and kr:find("[O/", 1, true), kr)

	-- every link rendered resolves (except the broken ones, listed last)
	local resolver = require("zortex.core.link")
	local broken = find(lines, "## Broken links")
	for n, l in ipairs(lines) do
		for _, span in ipairs(require("zortex.core.syntax").links(l)) do
			if n < broken then
				T.ok(resolver.resolve_first(span.definition), "resolves: " .. span.definition)
			end
		end
	end
end)

T.test("render: no broken links, no section and no count for them", function()
	local r = require("zortex.services.agenda").review({ today = TODAY, days = 7 })
	r.broken_links, r.mirror_issues = {}, {}
	local lines = review.render(r)
	T.ok(not find(lines, "Broken links"), "no broken links section")
	T.ok(not find(lines, "# Notes"), "no empty Notes heading")
	T.ok(not find(lines, "broken link"), "no 0 broken links in the summary")
end)

T.test("buffer: read-only, <CR> jumps to the source", function()
	local buf = review.open({ today = TODAY })
	T.eq(vim.api.nvim_buf_get_name(buf), "zortex://review")
	T.eq(vim.bo[buf].modifiable, false)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local i = find(lines, "Change task sizes")
	local loc = review._state().locations[i]
	vim.api.nvim_win_set_cursor(0, { i, 0 })
	vim.fn.maparg("<CR>", "n", false, true).callback()
	T.eq(vim.api.nvim_buf_get_name(0), vim.fn.fnamemodify(loc.file, ":p"))
	T.ok(vim.api.nvim_get_current_line():find("Change task sizes", 1, true), vim.api.nvim_get_current_line())

	-- reopening reuses the same buffer
	T.eq(review.open({ today = TODAY }), buf)
	vim.cmd("bwipeout! " .. buf)
end)

T.test("daily review: since the last one, at most a week; time, XP and objectives", function()
	local agenda = require("zortex.services.agenda")
	-- no daily review yet: today only
	T.eq(agenda.day_window("2026-10-12"), "2026-10-12")
	agenda.mark_day_reviewed("2026-10-09", "2026-10-09")
	T.eq(agenda.day_window("2026-10-12"), "2026-10-10") -- skipped days roll in
	agenda.mark_day_reviewed("2026-10-12", "2026-10-10")
	T.eq(agenda.day_window("2026-10-12"), "2026-10-10") -- reopened the same day: same window
	agenda.mark_day_reviewed("2026-09-01", "2026-09-01")
	T.eq(agenda.day_window("2026-10-12"), "2026-10-06") -- at most 7 days

	-- time tracked by the server, per day
	local z = require("zortex.config").notes_dir .. ".z/"
	vim.fn.mkdir(z, "p")
	vim.fn.writefile({
		vim.json.encode({
			version = 1,
			days = {
				["2026-10-12"] = { { rel = "projects.zortex", lnum = 16, text = "Improve website", key = "k", minutes = 85 } },
				["2026-10-01"] = { { rel = "projects.zortex", lnum = 16, text = "Improve website", key = "k", minutes = 30 } },
			},
		}),
	}, z .. "time_spent.json")

	local r = agenda.review({ today = "2026-10-12", scope = "day", from = "2026-10-11" })
	T.eq(r.scope, "day")
	T.eq(r.time.minutes, 85) -- 10-01 is outside the window
	T.eq(r.to, "2026-10-13")
	local lines = review.render(r)
	T.eq(lines[1], "@@Daily Review")
	T.ok(find(lines, "## Time spent: 1h 25m (1)"), vim.inspect(lines))
	T.ok(find(lines, "## Objectives (2)"), "objectives first")
	T.ok(find(lines, "100% behind"), "key results behind schedule")
	T.ok(find(lines, "## Not done (t: same time tomorrow)"), "calendar tasks left")
	T.ok(find(lines, "Work done: "), "the alignment line")
	vim.fn.delete(z .. "time_spent.json")
	agenda.mark_day_reviewed("2000-01-01", "2000-01-01")
end)

T.test("weekly review: XP by alignment, areas without objectives, unaligned projects", function()
	local r = require("zortex.services.agenda").review({ today = TODAY, days = 7 })
	T.ok(r.xp and r.xp.by_alignment, "xp totals")
	local lines = review.render(r)
	T.ok(find(lines, "on key results"), "aligned share")
	T.ok(find(lines, "## Areas without an objective this period"), "areas without objective")
	local _, unaligned = find(lines, "## Projects with neither a key result nor an area")
	T.ok(unaligned, "unaligned projects")
end)
