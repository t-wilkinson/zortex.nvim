local T = require("helpers")
local cd = require("zortex.services.calendar_days")

T.test("caldays.json matches calendar_days (regenerate with tests/gen_edits.lua)", function()
	local fixture = vim.json.decode(table.concat(vim.fn.readfile(T.root .. "/tests/fixtures/caldays.json"), "\n"))
	local cases = require("caldays_cases")
	T.eq(#fixture.cases, #cases, "case count")
	for i, c in ipairs(cases) do
		local f = fixture.cases[i]
		for j, p in ipairs(c.place) do
			local ins = cd.insert_day(c.lines, p.date, { "- new" }, { group = p.group })
			local want = f.place[j]
			T.eq({ ins.at, ins.lines, ins.heading }, { want.at, want.lines, want.heading }, c.name .. " " .. p.date)
		end
		local grouped, moved = cd.group(c.lines)
		T.eq({ grouped, moved }, { f.grouped, f.moved }, c.name .. ": grouped")
	end
end)

T.test("month headings read in their forms", function()
	T.eq({ cd.month_heading("# October 2026") }, { "2026-10", 1 })
	T.eq({ cd.month_heading("## Oct 2026") }, { "2026-10", 2 })
	T.eq({ cd.month_heading("### 2026-03") }, { "2026-03", 3 })
	T.eq(cd.month_heading("# 2026-13"), nil)
	T.eq(cd.month_heading("# Octember 2026"), nil)
	T.eq(cd.month_heading("#October 2026"), nil)
	T.eq(cd.month_heading_line("2026-03", 2), "## March 2026")
end)

T.test("grouping moves every day into its month, once; the rest stays", function()
	local lines = {
		"@@Calendar",
		"",
		"# Repeating",
		"- Sam @on(03-14) @born(1990)",
		"",
		"2026-10-09:",
		"14:00 A",
		"  - [ ] under A",
		"",
		"2026-09-28:",
		"- [ ] C",
		"",
		"**2026-10-10:**",
		"Outcomes:",
		"- [ ] B",
	}
	local out, moved = cd.group(lines)
	T.eq(moved, 3)
	T.eq(out, {
		"@@Calendar",
		"",
		"# Repeating",
		"- Sam @on(03-14) @born(1990)",
		"",
		"# September 2026",
		"",
		"2026-09-28:",
		"- [ ] C",
		"",
		"# October 2026",
		"",
		"2026-10-09:",
		"14:00 A",
		"  - [ ] under A",
		"",
		"**2026-10-10:**",
		"Outcomes:",
		"- [ ] B",
	})
	local again, n = cd.group(out)
	T.eq(n, 0)
	T.eq(again, out)
	-- each day's lines are what they were
	local rules = require("zortex.services.calendar_rules").rules(out)
	T.eq(#rules, 1, "the Repeating section is untouched")
end)

T.test("a new day goes into its month; :ZortexCalendarGroup groups the calendar", function()
	local fs = require("zortex.utils.filesystem")
	local store = require("zortex.stores.calendar")
	local cal = fs.get_calendar_file()
	local before = vim.fn.readfile(cal)
	local function read()
		return require("zortex.core.workspace").get_lines(cal)
	end
	local ok, err = pcall(function()
		vim.fn.writefile({ "@@Calendar", "", "2026-10-09:", "14:00 A", "", "2026-10-12:", "- B" }, cal)
		require("zortex.core.document").invalidate(cal)
		store.load()
		-- a day of a month with loose days joins them: no heading yet
		local heading, created = store.ensure_date("2026-10-10")
		T.ok(created)
		local lines = read()
		T.eq(lines[heading], "**2026-10-10:**")
		T.eq(#cd.months(lines), 0, "no month heading for October's loose days")
		-- a new month gets its heading
		heading = store.ensure_date("2026-11-02", { "- [ ] Plan" })
		lines = read()
		T.eq(lines[heading], "**2026-11-02:**")
		T.eq(lines[heading - 2], "# November 2026")
		T.eq(lines[heading + 1], "- [ ] Plan")
		-- group the rest
		T.eq(store.group_by_month(), 3)
		lines = read()
		T.eq(lines, {
			"@@Calendar",
			"",
			"# October 2026",
			"",
			"2026-10-09:",
			"14:00 A",
			"",
			"**2026-10-10:**",
			"",
			"2026-10-12:",
			"- B",
			"",
			"# November 2026",
			"",
			"**2026-11-02:**",
			"- [ ] Plan",
		})
		T.eq(store.group_by_month(), 0)
		-- the days still read the same
		store.load()
		T.eq(#store.get_entries_for_date("2026-10-12", { feeds = false }) > 0, true)
		T.eq(store.date_block("2026-10-12", lines).last_lnum, 11, "a day ends before the next month's heading")
		-- grouping off: no new headings, but a month that has one still takes its days
		local Config = require("zortex.config")
		Config.ui = vim.tbl_deep_extend("force", Config.ui or {}, { calendar = { group_days = false } })
		heading = store.ensure_date("2026-12-01")
		lines = read()
		T.eq(#cd.months(lines), 2, "no December heading")
		heading = store.ensure_date("2026-10-20")
		lines = read()
		T.eq(lines[heading + 2], "# November 2026", "October's day went into October")
	end)
	local Config = require("zortex.config")
	if Config.ui and Config.ui.calendar then
		Config.ui.calendar.group_days = nil
	end
	local b = vim.fn.bufnr(cal)
	if b > 0 then
		vim.api.nvim_buf_delete(b, { force = true })
	end
	vim.fn.writefile(before, cal)
	require("zortex.core.document").invalidate(cal)
	store.load()
	T.ok(ok, err)
end)

T.test("carrying to a new day puts it in its month", function()
	local planner = require("zortex.services.planner")
	local lines = {
		"@@Calendar",
		"",
		"# October 2026",
		"",
		"2026-10-30:",
		"- [ ] Open",
		"",
		"# December 2026",
		"",
		"2026-12-01:",
		"- later",
	}
	local n = 0
	local plan = planner.carry(lines, "2026-11-02", {
		from = "2026-10-01",
		group = "month",
		new_id = function()
			n = n + 1
			return "C" .. n
		end,
	})
	T.eq(plan.inserts, { { at = 8, lines = { "# November 2026", "", "**2026-11-02:**", "- [ ] Open @id(C1)", "" } } })
end)

T.test("other months start folded in the calendar note", function()
	local fs = require("zortex.utils.filesystem")
	local folding = require("zortex.features.folding")
	local cal = fs.get_calendar_file()
	local this = os.date("*t")
	local name = cd.MONTHS[this.month] .. " " .. this.year
	local lines = { "@@Calendar", "", "# January 2001", "", "2001-01-01:", "- old", "", "# " .. name, "", os.date("%Y-%m-%d") .. ":", "- now" }
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, cal .. ".test")
	T.eq(folding.other_months(buf, lines), {}, "only the calendar note")
	vim.api.nvim_buf_delete(buf, { force = true })
	local cbuf = vim.fn.bufadd(cal)
	T.eq(folding.other_months(cbuf, lines), { 3 })
	local Config = require("zortex.config")
	local saved = Config.ui
	Config.ui = vim.tbl_deep_extend("force", saved or {}, { calendar = { fold_months = false } })
	T.eq(folding.other_months(cbuf, lines), {})
	Config.ui = saved
end)
