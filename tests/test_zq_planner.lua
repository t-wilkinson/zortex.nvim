local T = require("helpers")
local planner = require("zortex.services.planner")
local Config = require("zortex.config")

local TODAY = "2026-10-11"

local function with_config(planner_cfg, fn)
	Config.ui = Config.ui or {}
	local saved = Config.ui.planner
	Config.ui.planner = planner_cfg
	local ok, err = pcall(fn)
	Config.ui.planner = saved
	assert(ok, err)
end

T.test("put: spacing, markers, blank lines", function()
	T.eq({ planner.put("09:00", 0, "Call [P/#X]") }, { "09:00 Call [P/#X]", 16 })
	T.eq({ planner.put("16:00 - 17:00", 3, "Gym") }, { "16:00 - 17:00 Gym", 16 })
	T.eq(planner.put("10:00 Meet", 9, "[P/#1.4]"), "10:00 Meet [P/#1.4]")
	T.eq(planner.put("- [ ] Do", 0, "it"), "- [ ] it Do")
	T.eq(planner.put("", 0, "Read"), "- Read")
	T.eq(planner.put("  ", 1, "Read"), "  - Read")
	T.eq(planner.put("a b", 0, "X"), "a X b")
	T.eq(planner.plain("Search works [P/#1.4.1] now"), "Search works now")
end)

T.test("templates by weekday", function()
	with_config({ templates = { weekday = { "09:00" }, saturday = { "10:00" }, monday = { "08:00" } } }, function()
		T.eq(planner.template("2026-10-12"), { "08:00" }) -- Monday override
		T.eq(planner.template("2026-10-13"), { "09:00" }) -- Tuesday -> weekday
		T.eq(planner.template("2026-10-10"), { "10:00" }) -- Saturday
		T.eq(planner.template("2026-10-11"), {}) -- Sunday: none
	end)
end)

T.test("candidates: signals add up; every line carries a resolving link", function()
	with_config({ todo_link = "P/#1 Programming/#1.4 - zortex" }, function()
		local c = planner.candidates({ today = TODAY })
		local texts = vim.tbl_map(function(t)
			return t.text
		end, c.tasks)
		-- work on a key result that is behind schedule comes first: the
		-- habits objective (3M-2026-Q1) is long past, its KR2 half done
		T.ok(vim.tbl_contains(c.tasks[1].badges, "OKR"), vim.inspect(c.tasks[1]))
		T.ok(texts[1]:find("Morning routine", 1, true), vim.inspect(texts))
		-- "Improve website" is a TODO with @p1 (its KR1 is done: no OKR bonus)
		local improve
		for _, t in ipairs(c.tasks) do
			if t.text:find("Improve website", 1, true) then
				improve = t
			end
		end
		T.ok(improve and improve.text:find("[P/#1 Programming/#1.4 - zortex/-Improve website]", 1, true), vim.inspect(improve))
		T.ok(vim.tbl_contains(improve.badges, "TODO") and vim.tbl_contains(improve.badges, "P1"), vim.inspect(improve.badges))
		local overdue = vim.tbl_filter(function(t)
			return t.text:find("Morning routine", 1, true)
		end, c.tasks)[1]
		T.ok(overdue and overdue.badges[1]:find("overdue"), vim.inspect(overdue))
		T.ok(#c.projects > 0 and #c.key_results > 0 and #c.areas > 0, "all sections")
		T.ok(c.key_results[1].text:find("/%-KR%d+%]"), c.key_results[1].text)

		local resolver = require("zortex.core.link")
		for key, section in pairs(c) do
			for _, item in ipairs(key == "groups" and {} or section) do
				local link = item.text:match("%[([^%]]+)%]%s*$")
				T.ok(link and resolver.resolve_first(link), "resolves: " .. item.text)
			end
		end
	end)
end)

T.test("plan buffer: a heading per project with its tasks; Tasks holds the to-dos", function()
	with_config({ todo_link = "P/#1 Programming/#1.4 - zortex/#1.4.1 - zortex search" }, function()
		local c = planner.candidates({ today = TODAY })
		local lines = require("zortex.ui.planner").render(c, TODAY)
		local function at(text)
			for i, l in ipairs(lines) do
				if l:find(text, 1, true) then
					return i
				end
			end
		end
		local projects, krs, todos, areas = at("# Projects ("), at("# Key results ("), at("# Tasks ("), at("# Areas (")
		T.ok(projects < krs and krs < todos and todos < areas, "sections in order")
		-- a project task sits under its project's heading
		local heading = at("## [P/#1 Programming/#1.4 - zortex]")
		local improve = at("Improve website [P/")
		T.ok(heading and heading > projects and improve > heading and improve < krs, vim.inspect(lines))
		-- a TODO-project task and an overdue calendar task are to-dos
		T.ok(at("Fix project search [P/") > todos, "TODO project task under Tasks")
		T.ok(at("Call the mechanic") > todos, "calendar task under Tasks")
		for _, g in ipairs(c.groups) do
			for _, t in ipairs(g.tasks) do
				T.eq(t.project_key, g.project.project_key)
				T.ok(not t.todo, t.text)
			end
		end
	end)
end)

T.test("plan buffer puts items into the calendar day", function()
	local cal = require("zortex.utils.filesystem").get_calendar_file()
	local original = vim.fn.readfile(cal)
	local proj = require("zortex.utils.filesystem").get_projects_file()
	local original_proj = vim.fn.readfile(proj) -- p gives the task an @id
	with_config({ todo_link = "P/#1 Programming/#1.4 - zortex", templates = { sunday = { "09:00", "12:00 Lunch" } } }, function()
		local ui = require("zortex.ui.planner")
		local buf = ui.open({ date = "2026-10-18" }) -- a Sunday, not in the calendar yet
		local st = ui._state()
		local cal_lines = vim.api.nvim_buf_get_lines(st.cal_buf, 0, -1, false)
		local h
		for i, l in ipairs(cal_lines) do
			if l == "2026-10-18:" then
				h = i
			end
		end
		T.ok(h, "day created")
		T.eq({ cal_lines[h + 1], cal_lines[h + 2] }, { "09:00", "12:00 Lunch" })
		T.eq(vim.api.nvim_win_get_cursor(st.cal_win)[1], h + 1)

		-- first task line in the plan buffer
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local first
		for i, l in ipairs(lines) do
			if l:find("Improve website", 1, true) then
				first = i
				break
			end
		end
		vim.api.nvim_win_set_cursor(st.win, { first, 0 })
		vim.fn.maparg("<CR>", "n", false, true).callback()
		local put = vim.api.nvim_buf_get_lines(st.cal_buf, h, h + 1, false)[1]
		T.ok(put:match("^09:00 Improve website %[P/"), put)

		-- the calendar sees it as an event on that day, linked to the project
		require("zortex.core.link_index").refresh(true)
		local items = require("zortex.services.agenda").day("2026-10-18")
		T.eq(items[1].time, "09:00")
		T.eq(items[1].project and items[1].project.key, "Projects/1 Programming/1.4 - zortex")

		-- i / o / O: text on the current / next / previous line, insert mode at line start
		local function press(key)
			vim.api.nvim_set_current_win(st.win)
			vim.api.nvim_win_set_cursor(st.win, { first, 0 })
			vim.fn.maparg(key, "n", false, true).callback()
			vim.cmd("stopinsert")
		end
		local text = lines[first]
		vim.api.nvim_win_set_cursor(st.cal_win, { h + 2, 0 }) -- "12:00 Lunch"
		press("o")
		T.eq(vim.api.nvim_get_current_win(), st.cal_win)
		T.eq(vim.api.nvim_win_get_cursor(st.cal_win), { h + 3, 0 })
		T.eq(vim.api.nvim_buf_get_lines(st.cal_buf, h + 2, h + 3, false)[1], text)
		press("O")
		T.eq(vim.api.nvim_win_get_cursor(st.cal_win), { h + 3, 0 })
		T.eq(vim.api.nvim_buf_get_lines(st.cal_buf, h + 2, h + 4, false), { text, text })
		vim.api.nvim_buf_set_lines(st.cal_buf, h + 2, h + 4, false, { "" })
		vim.api.nvim_win_set_cursor(st.cal_win, { h + 3, 0 })
		press("i")
		T.eq(vim.api.nvim_buf_get_lines(st.cal_buf, h + 2, h + 3, false)[1], text)
		vim.api.nvim_buf_set_lines(st.cal_buf, h + 2, h + 3, false, {})

		-- p: a task goes in as a copy with the task's @id, after the day's last
		-- entry; focus stays in the plan buffer
		vim.api.nvim_set_current_win(st.win)
		vim.api.nvim_win_set_cursor(st.win, { first, 0 })
		vim.fn.maparg("p", "n", false, true).callback()
		T.eq(vim.api.nvim_get_current_win(), st.win)
		local block = require("zortex.stores.calendar").date_block("2026-10-18", vim.api.nvim_buf_get_lines(st.cal_buf, 0, -1, false))
		local id = require("zortex.services.mirrors").id_of(select(2, (function()
			for i, l in ipairs(vim.fn.readfile(proj)) do
				if l:find("Improve website", 1, true) then
					return i, l
				end
			end
		end)()))
		T.ok(id, "the project task has an @id")
		T.eq(
			vim.api.nvim_buf_get_lines(st.cal_buf, block.last_lnum - 1, block.last_lnum, false)[1],
			"- [ ] [P/#1 Programming/#1.4 - zortex/-Improve website] @id(" .. id .. ")"
		)
		T.eq(block.last_lnum, h + 3) -- 09:00 …, 12:00 Lunch, then the new entry
		-- again: it's already on the day
		vim.fn.maparg("p", "n", false, true).callback()
		block = require("zortex.stores.calendar").date_block("2026-10-18", vim.api.nvim_buf_get_lines(st.cal_buf, 0, -1, false))
		T.eq(block.last_lnum, h + 3)

		ui.close()
		vim.cmd("silent! bwipeout! " .. st.cal_buf)
	end)
	vim.fn.writefile(original, cal)
	vim.fn.writefile(original_proj, proj)
	require("zortex.core.document").invalidate()
	require("zortex.stores.calendar").load()
end)

T.test("plan buffer: what is left in the inbox, last; p puts it on the day as written", function()
	local fs = require("zortex.utils.filesystem")
	local inbox, cal = fs.get_inbox_file(), fs.get_calendar_file()
	local cal0 = vim.fn.readfile(cal)
	vim.fn.writefile({ "@@Inbox", "", "- [ ] Call the plumber", "- [x] Done already", "Idea: a shelf for the hall" }, inbox)
	require("zortex.core.document").invalidate()
	with_config({ templates = {} }, function()
		local ui = require("zortex.ui.planner")
		local buf = ui.open({ date = "2026-11-15" })
		local st = ui._state()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local at = {}
		for i, l in ipairs(lines) do
			at[l] = i
		end
		T.ok(at["# Inbox (2)"] and at["# Areas (" .. #(planner.candidates({ today = "2026-11-15" }).areas) .. ")"] < at["# Inbox (2)"], vim.inspect(lines))
		T.eq(lines[at["# Inbox (2)"] + 1], "[ ] Call the plumber")
		T.eq(lines[at["# Inbox (2)"] + 2], "Idea: a shelf for the hall")
		vim.api.nvim_set_current_win(st.win)
		vim.api.nvim_win_set_cursor(st.win, { at["# Inbox (2)"] + 1, 0 })
		vim.fn.maparg("p", "n", false, true).callback()
		local block = require("zortex.stores.calendar").date_block("2026-11-15", vim.api.nvim_buf_get_lines(st.cal_buf, 0, -1, false))
		T.eq(vim.api.nvim_buf_get_lines(st.cal_buf, block.last_lnum - 1, block.last_lnum, false)[1], "- [ ] Call the plumber")
		ui.close()
		vim.cmd("silent! bwipeout! " .. st.cal_buf)
	end)
	vim.fn.delete(inbox)
	vim.fn.writefile(cal0, cal)
	require("zortex.core.document").invalidate()
	require("zortex.stores.calendar").load()
end)

T.test(":ZortexPlan again from the plan window, or over an unsaved calendar", function()
	local fs = require("zortex.utils.filesystem")
	local cal, proj = fs.get_calendar_file(), fs.get_projects_file()
	local original, original_proj = vim.fn.readfile(cal), vim.fn.readfile(proj)
	local confirm = vim.o.confirm
	vim.o.confirm = false -- E37 instead of a dialog
	with_config({ templates = { sunday = { "09:00" } } }, function()
		local ui = require("zortex.ui.planner")
		vim.cmd("only")
		-- the calendar is open with changes the planner made (a new day)
		vim.cmd("edit " .. vim.fn.fnameescape(cal))
		require("zortex.stores.calendar").ensure_date("2026-11-01", { "08:00" })
		T.ok(vim.bo.modified, "calendar buffer modified")
		local ok, err = pcall(ui.open, { date = "2026-11-08" })
		T.ok(ok, err)
		local st = ui._state()
		T.ok(st.cal_win ~= st.win, "two windows")
		-- again, from the plan window
		vim.api.nvim_set_current_win(st.win)
		ok, err = pcall(ui.open, { date = "2026-11-08" })
		T.ok(ok, err)
		T.ok(st.cal_win ~= st.win, "still two windows")
		T.eq(vim.api.nvim_win_get_buf(st.cal_win), st.cal_buf)
		T.eq(vim.api.nvim_win_get_buf(st.win), st.buf)
		T.eq(#vim.api.nvim_tabpage_list_wins(0), 2)

		-- <CR> and p reach the calendar
		local first
		for l, it in pairs(st.items) do
			if it.kind == "task" and (not first or l < first) then
				first = l
			end
		end
		local h = require("zortex.stores.calendar").date_block("2026-11-08", vim.api.nvim_buf_get_lines(st.cal_buf, 0, -1, false)).heading_lnum
		vim.api.nvim_win_set_cursor(st.cal_win, { h + 1, 0 })
		vim.api.nvim_win_set_cursor(st.win, { first, 0 })
		ok, err = pcall(vim.fn.maparg("<CR>", "n", false, true).callback)
		T.ok(ok, err)
		T.ok(vim.api.nvim_buf_get_lines(st.cal_buf, h, h + 1, false)[1]:match("^09:00 %S"), "put on the 09:00 line")
		ok, err = pcall(vim.fn.maparg("p", "n", false, true).callback)
		T.ok(ok, err)

		-- ? lists the buffer's keys from their descriptions
		local help = table.concat(require("zortex.ui.keyhelp").lines(st.buf, "Zortex plan: "), "\n")
		T.ok(help:find("  P  ", 1, true) and help:find("add the project with its next open tasks", 1, true), help)
		vim.api.nvim_set_current_win(st.win)
		local hwin = require("zortex.ui.keyhelp").show("Zortex plan: ", "Plan keys")
		T.ok(hwin and vim.api.nvim_win_get_config(hwin).relative == "editor", "help float")
		vim.api.nvim_win_close(hwin, true)

		ui.close()
		vim.cmd("silent! bwipeout! " .. st.cal_buf)
	end)
	vim.o.confirm = confirm
	vim.fn.writefile(original, cal)
	vim.fn.writefile(original_proj, proj)
	require("zortex.core.document").invalidate()
	require("zortex.stores.calendar").load()
end)

T.test("new days go after the closest earlier day, not before a stray later one", function()
	local calendar = require("zortex.stores.calendar")
	local cal = require("zortex.utils.filesystem").get_calendar_file()
	local original = vim.fn.readfile(cal)
	-- a far-future appointment near the top; recent days at the bottom
	vim.fn.writefile({
		"@@Calendar",
		"",
		"2026-10-21:",
		"09:00 Dentist",
		"",
		"2026-10-09:",
		"- one",
		"",
		"2026-10-10:",
		"- two",
	}, cal)
	require("zortex.core.document").invalidate(cal)
	calendar.ensure_date("2026-10-12", { "09:00" })
	local lines = vim.fn.readfile(cal)
	T.eq(vim.list_slice(lines, 9), { "2026-10-10:", "- two", "", "2026-10-12:", "09:00" })

	-- between two days that are in order
	calendar.ensure_date("2026-10-11", {})
	lines = vim.fn.readfile(cal)
	T.eq(vim.list_slice(lines, 9), { "2026-10-10:", "- two", "", "2026-10-11:", "", "2026-10-12:", "09:00" })

	-- earlier than everything: before the earliest day
	calendar.add_entry("2026-10-01", "- zero")
	lines = vim.fn.readfile(cal)
	T.eq(vim.list_slice(lines, 6, 9), { "2026-10-01:", "- zero", "", "2026-10-09:" })

	vim.fn.writefile(original, cal)
	require("zortex.core.document").invalidate(cal)
	calendar.load()
end)

T.test("alignment: key-result work first, behind schedule more; then areas", function()
	with_config({ todo_link = "" }, function()
		local P = require("zortex.services.projects")
		local c = planner.candidates({ today = "2026-03-15" })
		local function find(list, text)
			for i, item in ipairs(list) do
				if item.text:find(text, 1, true) then
					return i, item
				end
			end
		end
		-- 1.4 - zortex is linked from "KR1 Projects API" (done) and KR2 via its
		-- sub-project; Habits from an open KR of the habits objective
		local _, habits = find(c.tasks, "Morning routine")
		T.ok(habits and vim.tbl_contains(habits.badges, "OKR"), vim.inspect(habits))
		-- the alignment score itself: KR > area > none, and behind adds more
		local ctx = { krs = {}, kr_of = {}, today_str = "2026-03-15" }
		local zortex = P.get("Projects/1 Programming/1.4 - zortex")
		local fake_kr = {
			id = "KR9",
			lag = function(_, _)
				return 0.3
			end,
		}
		ctx.krs[zortex.key] = { fake_kr }
		local behind = planner._alignment(zortex, nil, ctx)
		fake_kr.lag = function()
			return 0
		end
		ctx.kr_of = {}
		local on_track = planner._alignment(zortex, nil, ctx)
		local esp = P.get("Projects/1 Programming/1.4 - esp32")
		local area_only = planner._alignment(zortex, nil, { krs = {}, kr_of = {} })
		local none = planner._alignment(esp, nil, { krs = {}, kr_of = {} })
		T.ok(behind > on_track and on_track > area_only and area_only > none, vim.inspect({ behind, on_track, area_only, none }))
		-- key results: furthest behind first
		for i = 2, #c.key_results do
			T.ok(c.key_results[i - 1].score >= c.key_results[i].score)
		end
		-- areas without a current objective come first, and say so
		T.ok(vim.tbl_contains(c.areas[1].badges, "no objective"), vim.inspect(c.areas[1]))
	end)
end)
