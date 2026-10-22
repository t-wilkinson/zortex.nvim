-- The planning loop around the planner: tasks put off, P's next tasks, the
-- day's capacity, and the weekly focus from the reviews note.
local T = require("helpers")
local planner = require("zortex.services.planner")
local fs = require("zortex.utils.filesystem")

local ESP = "Projects/1 Programming/1.4 - esp32"
local ZORTEX = "Projects/1 Programming/1.4 - zortex"

local function refresh()
	require("zortex.core.document").invalidate()
	require("zortex.stores.calendar").load()
	require("zortex.core.link_index").refresh(true)
end

-- Run fn with lines appended to the calendar and @ids added to project
-- tasks ({ ["Compile code"] = "esp01" }), restoring both after.
local function with_notes(calendar_lines, ids, fn)
	local cal, proj = fs.get_calendar_file(), fs.get_projects_file()
	local cal0, proj0 = vim.fn.readfile(cal), vim.fn.readfile(proj)
	local reviews = fs.get_reviews_file()
	local reviews0 = vim.fn.filereadable(reviews) == 1 and vim.fn.readfile(reviews) or nil
	local p = vim.deepcopy(proj0)
	for i, l in ipairs(p) do
		for text, id in pairs(ids or {}) do
			if l:find("- [ ] " .. text, 1, true) then
				p[i] = l .. " @id(" .. id .. ")"
			end
		end
	end
	vim.fn.writefile(p, proj)
	local c = vim.deepcopy(cal0)
	vim.list_extend(c, calendar_lines or {})
	vim.fn.writefile(c, cal)
	refresh()
	local ok, err = xpcall(fn, debug.traceback)
	vim.fn.writefile(cal0, cal)
	vim.fn.writefile(proj0, proj)
	if reviews0 then
		vim.fn.writefile(reviews0, reviews)
	else
		vim.fn.delete(reviews)
	end
	for _, path in ipairs({ cal, proj, reviews }) do
		local b = vim.fn.bufnr(path)
		if b > 0 then
			vim.cmd("silent! bwipeout! " .. b)
		end
	end
	refresh()
	assert(ok, err)
end

local function find(list, text)
	for _, item in ipairs(list) do
		if (item.text or ""):find(text, 1, true) and item.project_key then
			return item
		end
	end
end

-- =============================================================================
-- Put off
-- =============================================================================

local CARRIED = {
	"",
	"2026-10-12:",
	"- [>] [P/#1 Programming/#1.4 - esp32/-Compile code] @id(esp01)",
	"",
	"2026-10-13:",
	"- [>] [P/#1 Programming/#1.4 - esp32/-Compile code] @id(esp01)",
	"- [>] [P/#1 Programming/#1.4 - esp32/-Compile code] @id(esp01)",
	"",
	"2026-10-14:",
	"- [ ] [P/#1 Programming/#1.4 - esp32/-Compile code] @id(esp01)",
}

T.test("put off: days a task was planned and not done", function()
	with_notes(CARRIED, { ["Compile code"] = "esp01" }, function()
		local mirrors = require("zortex.services.mirrors")
		-- 10-12 and 10-13 carried on (twice on 10-13 counts once), 10-14 left open
		T.eq(mirrors.put_off("esp01", "2026-10-15"), 3)
		T.eq(mirrors.put_off("esp01", "2026-10-14"), 2) -- today's copy isn't put off yet
		T.eq(mirrors.put_off("esp01", "2026-10-12"), 0)
		local task = require("zortex.services.projects").get(ESP):tasks()[1]
		T.eq(task.put_off, mirrors.put_off("esp01"))
		-- the weekly review lists it, most often first
		local list = require("zortex.services.agenda").put_off("2026-10-15")
		T.eq(#list, 1)
		T.eq({ list[1].count, list[1].text, list[1].project.key }, { 3, "Compile code", ESP })
	end)
end)

T.test("put off: ranks higher the more often, with a badge", function()
	local before = find(planner.candidates({ today = "2026-10-15" }).tasks, "Compile code")
	with_notes(CARRIED, { ["Compile code"] = "esp01" }, function()
		local after = find(planner.candidates({ today = "2026-10-15" }).tasks, "Compile code")
		T.ok(after, "listed")
		T.ok(vim.tbl_contains(after.badges, "put off ×3"), vim.inspect(after.badges))
		T.eq(after.score, (before and before.score or 0) + 3 * planner.weights.put_off)
		local once = find(planner.candidates({ today = "2026-10-13" }).tasks, "Compile code")
		T.ok(once.score < after.score, "more often, higher")
	end)
	-- capped
	local w = planner.weights
	T.ok(w.put_off_max >= w.put_off, "cap")
end)

-- =============================================================================
-- P: the next few tasks
-- =============================================================================

T.test("P puts the project's next open tasks on the day, not all of them", function()
	with_notes({}, {}, function()
		local P = require("zortex.services.projects")
		local p = P.get(ZORTEX)
		local c = { project_key = p.key, project_link = p.link, text = p.link }
		local function day_lines()
			local cal = fs.get_calendar_file()
			local lines = require("zortex.core.workspace").get_lines(cal)
			local block = require("zortex.stores.calendar").date_block("2026-10-20", lines)
			return vim.list_slice(lines, block.heading_lnum + 1, block.last_lnum)
		end
		local _, added = planner.add_project("2026-10-20", c, { count = 2 })
		T.eq(added, 2)
		local lines = day_lines()
		T.eq(#lines, 3, vim.inspect(lines))
		T.eq(lines[1], "- [1.4 - zortex](P/#1 Programming/#1.4 - zortex)")
		T.ok(lines[2]:find("[Add research-ready references](./-Add research-ready references)", 1, true), lines[2])
		T.ok(lines[3]:find("[Improve website](./-Improve website)", 1, true), lines[3])
		-- again with the default (3): the first two are there; one more comes
		refresh()
		_, added = planner.add_project("2026-10-20", c)
		T.eq(added, 1)
		T.ok(day_lines()[4]:find("[Change task sizes](./-Change task sizes)", 1, true), vim.inspect(day_lines()))
	end)
end)

-- =============================================================================
-- Capacity
-- =============================================================================

T.test("capacity: open tasks against the free time left in the day", function()
	local day = {
		"",
		"2026-10-20:",
		"09:00 - 10:30 Lecture",
		"12:00 Lunch",
		"14:00 - 16:00 [P/#1 Programming/#1.4 - zortex]",
		"  - [ ] [./-Improve website] @id(imp01)",
		"- [ ] Buy milk @size(xs)",
		"- [ ] Call home",
		"- [x] Done already @size(sm)",
		"- [>] Carried on @size(xl)",
		"- [ ] [P/#1.4 - zortex/#1.4.1/-Fix project search] @id(fix01)",
	}
	with_notes(day, { ["Improve website"] = "imp01", ["Fix project search"] = "fix01" }, function()
		local c = planner.capacity("2026-10-20", { today = "2026-10-19" })
		-- the copy weighs its project task (xl, 3h); unsized = md (1h)
		T.eq(c.planned, 180 + 15 + 60 + 30)
		T.eq({ c.tasks, c.unsized }, { 4, 1 })
		-- 1.4.1 is what an open key result links (KR2); 1.4's KR is done
		T.eq(c.aligned, 30)
		T.eq(c.done, 30)
		-- the lecture and lunch (no end: 30m) are busy; the project block isn't
		T.eq(c.busy, 90 + 30)
		T.eq(c.free, 14 * 60 - 120)
		T.eq(c.over, c.planned - c.free)
		local line = planner.capacity_line(c)
		T.ok(line:find("^Capacity: 4h45m planned %(4 tasks, 1 unsized%) · 30m on key results · 12h free %(08:00%-22:00, 2h busy%) · 7h15m to spare · 30m done$"), line)

		-- today at 15:00: only what's left of the window counts
		c = planner.capacity("2026-10-20", { today = "2026-10-20", now = "15:00" })
		T.eq({ c.busy, c.free }, { 0, 7 * 60 })
		c = planner.capacity("2026-10-20", { today = "2026-10-20", now = "21:00" })
		T.eq(c.free, 60)
		T.ok(planner.capacity_line(c):find("3h45m over", 1, true), planner.capacity_line(c))
	end)
end)

-- =============================================================================
-- Weeks and the reviews note
-- =============================================================================

T.test("weeks: ISO weeks, and the week a review plans", function()
	local R = require("zortex.services.review")
	T.eq({ R.week_of("2026-10-16") }, { "2026-W42", "2026-10-12", "2026-10-18" })
	T.eq(R.week_of("2026-10-12"), "2026-W42")
	T.eq(R.week_of("2026-10-18"), "2026-W42")
	T.eq(R.week_of("2026-01-01"), "2026-W01") -- a Thursday
	T.eq(R.week_of("2027-01-01"), "2026-W53") -- a Friday: still 2026's last week
	T.eq(R.week_of("2025-12-29"), "2026-W01") -- a Monday: already 2026's first
	-- Friday: this week; Saturday and Sunday: the coming week
	T.eq(R.review_week("2026-10-16"), "2026-W42")
	T.eq(R.review_week("2026-10-17"), "2026-W43")
	T.eq(R.review_week("2026-10-18"), "2026-W43")
	T.eq(R.review_week("2026-10-19"), "2026-W43")
end)

T.test("reviews note: weeks newest first, days inside them, focus links", function()
	with_notes({}, {}, function()
		local R = require("zortex.services.review")
		local path = fs.get_reviews_file()
		vim.fn.delete(path)
		local P = require("zortex.services.projects")
		T.eq(R.ensure_week("2026-W42"), 3)
		T.eq(R.ensure_week("2026-W42"), 3) -- already there
		R.ensure_week("2026-W43") -- newer: on top
		R.ensure_week("2026-W41") -- older: at the end
		T.eq(R.ensure_day("2026-10-14"), R.entries(vim.fn.readfile(path)).weeks["2026-W42"].days["2026-10-14"])
		R.ensure_day("2026-10-16") -- newer day first
		T.eq(R.toggle_focus("2026-W42", P.get(ESP)), true)
		T.eq(R.toggle_focus("2026-W42", P.get(ZORTEX)), true)
		T.eq(vim.fn.readfile(path), {
			"@@Reviews",
			"",
			"# 2026-W43",
			"Focus:",
			"",
			"Wins:",
			"",
			"Lessons:",
			"",
			"# 2026-W42",
			"Focus:",
			"- [1.4 - esp32](P/#1 Programming/#1.4 - esp32)",
			"- [1.4 - zortex](P/#1 Programming/#1.4 - zortex)",
			"",
			"Wins:",
			"",
			"Lessons:",
			"",
			"## 2026-10-16",
			"Done:",
			"Blocked:",
			"First thing tomorrow:",
			"",
			"## 2026-10-14",
			"Done:",
			"Blocked:",
			"First thing tomorrow:",
			"",
			"# 2026-W41",
			"Focus:",
			"",
			"Wins:",
			"",
			"Lessons:",
		})
		-- the week's focus, and later weeks without one keep it
		local f = R.focus("2026-10-16")
		T.eq({ f.week, f.from_earlier, #f.projects, f.projects[1].key }, { "2026-W42", false, 2, ESP })
		f = R.focus("2026-10-21")
		T.eq({ f.week, f.from_earlier }, { "2026-W42", true })
		T.eq(R.focus("2026-10-07"), nil) -- W41: nothing picked
		-- toggling again takes it out
		T.eq(R.toggle_focus("2026-W42", P.get(ESP)), false)
		T.eq(#R.week_focus("2026-W42"), 1)
	end)
end)

T.test("planner: the week's focus projects come first", function()
	with_notes({}, {}, function()
		local R = require("zortex.services.review")
		vim.fn.delete(fs.get_reviews_file())
		local without = planner.candidates({ today = "2026-10-16" })
		T.ok(not without.tasks[1].text:find("Compile code", 1, true), "not first without focus")
		R.toggle_focus("2026-W42", require("zortex.services.projects").get(ESP))
		local c = planner.candidates({ today = "2026-10-16" })
		T.eq(c.focus_week, "2026-W42")
		T.ok(c.tasks[1].text:find("Compile code", 1, true), vim.inspect(c.tasks[1]))
		T.eq(c.tasks[1].badges[1], "focus")
		T.eq(c.groups[1].project.project_key, ESP)
		T.ok(c.groups[1].project.focus, "the project is marked")
		-- the plan buffer says which week's focus it uses
		local lines = require("zortex.ui.planner").render(c, "2026-10-16")
		T.eq(lines[1], "@@Plan 2026-10-16")
	end)
end)

T.test(":ZortexReview opens the week's entry beside the findings; f picks the focus", function()
	with_notes({}, {}, function()
		vim.fn.delete(fs.get_reviews_file())
		local ui = require("zortex.ui.review")
		local buf = ui.open({ scope = "week", today = "2026-10-16" })
		local st = ui._state()
		T.eq(st.week, "2026-W42")
		T.ok(vim.api.nvim_win_is_valid(st.note_win) and st.note_win ~= st.win, "two windows")
		T.eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(st.note_win)), vim.fn.fnamemodify(fs.get_reviews_file(), ":p"))
		T.eq(vim.api.nvim_win_get_cursor(st.note_win)[1], 3) -- "# 2026-W42"
		local function lines()
			return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		end
		local function at(text)
			for i, l in ipairs(lines()) do
				if l:find(text, 1, true) then
					return i
				end
			end
		end
		T.ok(at("# Week 2026-W42"), vim.inspect(lines()))
		T.ok(at("## Focus (f on a project adds or removes it) (0)"), vim.inspect(lines()))
		-- f on an active project adds it to the week's focus
		local row = at("- [1.4 - esp32](P/#1 Programming/#1.4 - esp32)")
		T.ok(row and row > at("## Active projects"), vim.inspect(lines()))
		vim.api.nvim_set_current_win(st.win)
		vim.api.nvim_win_set_cursor(st.win, { row, 0 })
		vim.fn.maparg("f", "n", false, true).callback()
		T.ok(at("## Focus (f on a project adds or removes it) (1)"), vim.inspect(lines()))
		local note = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(st.note_win), 0, -1, false)
		T.ok(vim.tbl_contains(note, "- [1.4 - esp32](P/#1 Programming/#1.4 - esp32)"), vim.inspect(note))
		-- and saved, for the web app
		T.ok(vim.tbl_contains(vim.fn.readfile(fs.get_reviews_file()), "- [1.4 - esp32](P/#1 Programming/#1.4 - esp32)"), "written")
		T.eq(vim.bo[vim.api.nvim_win_get_buf(st.note_win)].modified, false)
		-- the daily review: the day's entry inside the week
		ui.open({ scope = "day", today = "2026-10-16" })
		T.eq(vim.api.nvim_get_current_line ~= nil, true)
		local day_line = vim.api.nvim_win_get_cursor(st.note_win)[1]
		T.eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(st.note_win), day_line - 1, day_line, false)[1], "## 2026-10-16")
		T.ok(at("## Focus 2026-W42 (1)"), vim.inspect(lines()))
		ui.close()
		vim.cmd("silent! %bwipeout!")
	end)
end)

T.test("plan buffer: the capacity line follows what goes on the day", function()
	with_notes({}, {}, function()
		local ui = require("zortex.ui.planner")
		local buf = ui.open({ date = "2026-10-25" })
		local st = ui._state()
		local function cap()
			return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
		end
		T.ok(cap():find("^Capacity: 0h planned · 14h free"), cap())
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local row
		for i, l in ipairs(lines) do
			if l:find("Improve website", 1, true) then
				row = i
				break
			end
		end
		vim.api.nvim_set_current_win(st.win)
		vim.api.nvim_win_set_cursor(st.win, { row, 0 })
		vim.fn.maparg("p", "n", false, true).callback()
		T.ok(cap():find("^Capacity: 3h planned %(1 task%)"), cap()) -- @size(xl)
		-- a hand edit in the calendar is picked up too
		local n = vim.api.nvim_buf_line_count(st.cal_buf)
		vim.api.nvim_buf_set_lines(st.cal_buf, n, n, false, { "- [ ] Buy milk @size(xs)" })
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = st.cal_buf })
		T.ok(cap():find("^Capacity: 3h15m planned %(2 tasks%)"), cap())
		ui.close()
		vim.cmd("silent! %bwipeout!")
	end)
end)

T.test("calendar view: the day as written, tasks under their project's block", function()
	local DAY = {
		"",
		"2026-10-27:",
		"09:00 [P/#1 Programming/#1.4 - zortex]",
		"  - [ ] [./-Improve website]",
		"  - [ ] Write the docs",
		"12:00 Lunch",
		"- [ ] Buy milk",
	}
	with_notes(DAY, {}, function()
		local calendar = require("zortex.stores.calendar")
		local got = vim.tbl_map(function(e)
			return string.rep("  ", e.depth) .. vim.trim(e.raw_text)
		end, calendar.get_day_entries("2026-10-27"))
		T.eq(got, {
			"09:00 [P/#1 Programming/#1.4 - zortex]",
			"  - [ ] [./-Improve website]",
			"  - [ ] Write the docs",
			"12:00 Lunch",
			"- [ ] Buy milk",
		})
		-- the calendar view lists them in that order, indented
		local render = require("zortex.ui.calendar.render")
		local Config = require("zortex.config")
		local saved_ui = Config.ui
		-- setup() hasn't run in these tests: the defaults under what is set
		Config.ui = vim.tbl_deep_extend("keep", vim.deepcopy(saved_ui or {}), vim.deepcopy(Config.defaults.ui))
		local cfg = vim.deepcopy(Config.ui.calendar)
		local state = { current_date = require("zortex.utils.datetime").parse_date("2026-10-27") }
		local ok, lines = pcall(render.month, state.current_date, state, cfg, 80)
		Config.ui = saved_ui
		assert(ok, lines)
		local order = {}
		for _, l in ipairs(lines) do
			for _, want in ipairs({ "1.4 - zortex", "Improve website", "Write the docs", "Lunch", "Buy milk" }) do
				if l:find(want, 1, true) then
					order[#order + 1] = want
				end
			end
		end
		T.eq(order, { "1.4 - zortex", "Improve website", "Write the docs", "Lunch", "Buy milk" })
	end)
end)
