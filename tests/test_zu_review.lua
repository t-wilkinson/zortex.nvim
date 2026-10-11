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
	T.ok(find(lines, "## Stale: no calendar time behind or ahead (4)"), "stale header")
	-- unscheduled excludes the stale ones
	T.ok(find(lines, "## Unscheduled: open work, nothing on the calendar ahead (3)"), "unscheduled header")
	T.ok(find(lines, "## Broken links (1)"), "broken links header")

	local i, line = find(lines, "Change task sizes")
	T.ok(line:find("[P/", 1, true), line) -- due task links its project
	T.eq(locations[i].lnum > 0, true)

	local _, kr = find(lines, "- KR1: ")
	T.ok(kr and kr:find("[O/", 1, true), kr)

	-- every link rendered resolves (except the broken ones, listed last)
	local resolver = require("zortex.utils.link_resolver")
	local broken = find(lines, "## Broken links")
	for n, l in ipairs(lines) do
		for link in l:gmatch("%[([PAO]/[^%]]+)%]") do
			if n < broken then
				T.ok(resolver.resolve_first(link), "resolves: " .. link)
			end
		end
	end
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
