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
		-- "Improve website" is a TODO with @p1 in a project with @p1 and an OKR link
		T.ok(texts[1]:find("Improve website", 1, true), vim.inspect(texts))
		T.ok(texts[1]:find("[P/#1 Programming/#1.4 - zortex/-Improve website]", 1, true), texts[1])
		T.ok(vim.tbl_contains(c.tasks[1].badges, "TODO") and vim.tbl_contains(c.tasks[1].badges, "P1"), vim.inspect(c.tasks[1].badges))
		local overdue = vim.tbl_filter(function(t)
			return t.text:find("Morning routine", 1, true)
		end, c.tasks)[1]
		T.ok(overdue and overdue.badges[1]:find("overdue"), vim.inspect(overdue))
		T.ok(#c.projects > 0 and #c.key_results > 0 and #c.areas > 0, "all sections")
		T.ok(c.key_results[1].text:find("/%-KR%d+%]"), c.key_results[1].text)

		local resolver = require("zortex.utils.link_resolver")
		for _, section in pairs(c) do
			for _, item in ipairs(section) do
				local link = item.text:match("%[([^%]]+)%]%s*$")
				T.ok(link and resolver.resolve_first(link), "resolves: " .. item.text)
			end
		end
	end)
end)

T.test("plan buffer puts items into the calendar day", function()
	local cal = require("zortex.utils.filesystem").get_calendar_file()
	local original = vim.fn.readfile(cal)
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

		-- p: "- text" after the day's last entry, focus stays in the plan buffer
		vim.api.nvim_set_current_win(st.win)
		vim.api.nvim_win_set_cursor(st.win, { first, 0 })
		vim.fn.maparg("p", "n", false, true).callback()
		T.eq(vim.api.nvim_get_current_win(), st.win)
		local block = require("zortex.stores.calendar").date_block("2026-10-18", vim.api.nvim_buf_get_lines(st.cal_buf, 0, -1, false))
		T.eq(vim.api.nvim_buf_get_lines(st.cal_buf, block.last_lnum - 1, block.last_lnum, false)[1], "- " .. text)
		T.eq(block.last_lnum, h + 3) -- 09:00 …, 12:00 Lunch, then the new entry

		ui.close()
		vim.cmd("silent! bwipeout! " .. st.cal_buf)
	end)
	vim.fn.writefile(original, cal)
	require("zortex.stores.calendar").load()
end)
