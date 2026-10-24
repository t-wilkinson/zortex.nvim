local T = require("helpers")
local R = require("zortex.services.calendar_rules")

T.test("@repeat specs: days of the week, dates, days of the month, every n from @from", function()
	local function on(line, date)
		return R.matches(R.rule(line, 1), date)
	end
	T.eq(on("- Sam @repeat(03-14)", "2027-03-14"), true)
	T.eq(on("- Sam @repeat(03-14)", "2027-03-15"), false)
	T.eq(on("- Review @repeat(weekly, Sunday)", "2026-10-18"), true)
	T.eq(on("- Review @repeat(weekly, Sunday)", "2026-10-19"), false)
	T.eq(on("- Review @repeat(sun)", "2026-10-25"), true)
	T.eq(on("- Standup @repeat(weekdays)", "2026-10-24"), false) -- Saturday
	T.eq(on("- Standup @repeat(weekdays)", "2026-10-23"), true)
	T.eq(on("- Rent @repeat(monthly 15)", "2026-11-15"), true)
	T.eq(on("- Rent @repeat(1st)", "2026-11-01"), true)
	T.eq(on("- Bins @repeat(2w) @from(2026-10-06)", "2026-10-20"), true)
	T.eq(on("- Bins @repeat(2w) @from(2026-10-06)", "2026-10-13"), false)
	T.eq(on("- Bins @repeat(2w) @from(2026-10-06)", "2026-09-22"), false, "not before @from")
	T.eq(on("- Bins @repeat(2w)", "2026-10-20"), false, "every n needs @from")
	T.eq(on("- Run @repeat(daily) @to(2026-10-21)", "2026-10-22"), false)
	T.eq(on("- Run @repeat(daily) @to(2026-10-21)", "2026-10-21"), true, "@to is the last day")
	-- a time in @from / @to is the entry's time, not a bound
	T.eq(on("- Swim @repeat(sat) @from(07:30) @to(08:15)", "2026-10-24"), true)
	T.eq(R.plain_line("- Swim @repeat(sat) @from(07:30) @to(08:15) @from(2026-10-17)"), "- Swim @from(07:30) @to(08:15)")
	T.eq(on("- Dad @repeat(yearly) @born(1961-10-13)", "2030-10-13"), true)
	T.eq(on("- Typo @repeat(fortnightly)", "2026-10-13"), false)
	T.eq(R.label(R.rule("- Sam @repeat(03-14) @born(1990)", 1), "Sam", "2026-03-14"), "Sam (36)")
	T.eq(R.plain_line("  - [ ] Bins out @repeat(2w) @from(2026-10-06) @to(2026-12-31) @at(18:00)"), "- [ ] Bins out @at(18:00)")
end)

T.test("@on: which days, with @repeat or alone; a weekday of the month; the last day", function()
	local function on(line, date)
		return R.matches(R.rule(line, 1), date)
	end
	T.eq(on("- Review @repeat(weekly) @on(sun)", "2026-10-18"), true)
	T.eq(on("- Review @repeat(weekly) @on(sun)", "2026-10-19"), false)
	T.eq(on("- Yoga @on(tue, thu)", "2026-10-22"), true, "@on alone repeats")
	T.eq(on("- Yoga @on(tue, thu)", "2026-10-23"), false)
	T.eq(on("- Rent @repeat(monthly) @on(1st)", "2026-11-01"), true)
	T.eq(on("- Sam @on(03-14)", "2027-03-14"), true)
	T.eq(on("- Club @repeat(monthly) @on(last thu)", "2026-10-29"), true)
	T.eq(on("- Club @repeat(monthly) @on(last thu)", "2026-10-22"), false)
	T.eq(on("- Club @on(first mon)", "2026-11-02"), true)
	T.eq(on("- Club @on(2nd tue)", "2026-11-10"), true)
	T.eq(on("- Club @on(2nd tue)", "2026-11-03"), false)
	T.eq(on("- Bills @on(last)", "2026-02-28"), true)
	T.eq(on("- Bills @on(last)", "2028-02-28"), false, "a leap year")
	T.eq(on("- Bills @on(last)", "2028-02-29"), true)
	T.eq(on("- Every other @repeat(2m) @on(last fri) @from(2026-10-01)", "2026-12-25"), true)
	T.eq(on("- Every other @repeat(2m) @on(last fri) @from(2026-10-01)", "2026-11-27"), false)
	T.eq(R.plain_line("- [ ] Taxes @repeat(yearly) @on(04-15) @at(09:00)"), "- [ ] Taxes @at(09:00)")
end)

T.test("templates by name, the most specific first; sections end at the first day", function()
	local lines = {
		"@@Calendar",
		"# Templates",
		"Weekend:",
		"- lazy",
		"Sat:",
		"  - [ ] Market",
		"  Notes:",
		"",
		"# Repeating",
		"- Sam @repeat(03-14)",
		"",
		"**2026-10-12:**",
		"- Not a rule @repeat(daily)",
	}
	T.eq(R.template(lines, "2026-10-17"), { "- [ ] Market", "Notes:" }) -- Saturday
	T.eq(R.template(lines, "2026-10-18"), { "- lazy" }) -- Sunday: weekend
	T.eq(R.template(lines, "2026-10-19"), {}) -- Monday: none
	local rules = R.rules(lines)
	T.eq(#rules, 1, "only rules above the first day")
	T.eq(rules[1].lnum, 10)
end)

T.test("the calendar shows the rules' occurrences; ticking one copies it into today", function()
	local fs = require("zortex.utils.filesystem")
	local workspace = require("zortex.core.workspace")
	local store = require("zortex.stores.calendar")
	local cal = fs.get_calendar_file()
	local before = vim.fn.readfile(cal)
	local ok, err = pcall(function()
		vim.fn.writefile(require("calendar_cases"), cal)
		require("zortex.core.document").invalidate(cal)
		store.load()
		local function texts(date)
			local out = {}
			for _, e in ipairs(store.get_day_entries(date)) do
				if e.rule then
					out[#out + 1] = e.text .. (e.completed and " ✓" or "")
				end
			end
			return out
		end
		-- 2026-10-13: Stretch is done on the day (its copy shows instead),
		-- Water plants was done the next day (@for)
		local on13 = texts("2026-10-13")
		table.sort(on13)
		T.eq(on13, { "Dad (65)", "Standup", "Water plants ✓", "Yoga" })
		local occ
		for _, e in ipairs(store.occurrences("2026-10-18")) do
			if e.text == "Weekly review" then
				occ = e
			end
		end
		T.ok(occ and occ.type == "task" and not occ.completed, "an open repeating task")
		-- ticked a day late: into today, @for the day it was due
		T.ok(store.complete_occurrence(occ, "2026-10-19"))
		local lines = workspace.get_lines(cal)
		local block = store.date_block("2026-10-19", lines)
		T.ok(block, "today made")
		T.ok(lines[block.last_lnum]:match("^12:00 %[x%] Weekly review @id%(%w+%) @done%(2026%-10%-19%) @for%(2026%-10%-18%)$"), lines[block.last_lnum])
		T.ok(vim.tbl_contains(texts("2026-10-18"), "Weekly review ✓"), vim.inspect(texts("2026-10-18")))
		-- ticking it again opens the copy
		for _, e in ipairs(store.occurrences("2026-10-18")) do
			if e.text == "Weekly review" then
				occ = e
			end
		end
		T.ok(occ.copy, "it has its copy")
		T.ok(store.complete_occurrence(occ, "2026-10-19"))
		T.ok(vim.tbl_contains(texts("2026-10-18"), "Weekly review"), vim.inspect(texts("2026-10-18")))
		-- the same day: the copy shows instead of the occurrence
		for _, e in ipairs(store.occurrences("2026-10-20")) do
			if e.text == "Bins out" then
				occ = e
			end
		end
		T.ok(store.complete_occurrence(occ, "2026-10-20"))
		local found = false
		for _, e in ipairs(store.get_day_entries("2026-10-20")) do
			T.ok(not (e.rule and e.text == "Bins out"), "no occurrence beside its copy")
			found = found or (e.text == "Bins out" and e.completed and e.lnum ~= nil)
		end
		T.ok(found, "the copy is on the day")
		-- a new day starts from its template
		T.eq(store.template("2026-10-18"), { "12:00 Weekly review" })
	end)
	vim.fn.writefile(before, cal)
	require("zortex.core.document").invalidate(cal)
	store.load()
	T.ok(ok, err)
end)

T.test("planning a day writes its repeating tasks into it, once", function()
	local fs = require("zortex.utils.filesystem")
	local store = require("zortex.stores.calendar")
	local workspace = require("zortex.core.workspace")
	local cal = fs.get_calendar_file()
	local before = vim.fn.readfile(cal)
	local ok, err = pcall(function()
		vim.fn.writefile(require("calendar_cases"), cal)
		require("zortex.core.document").invalidate(cal)
		store.load()
		-- 2026-10-18, a Sunday: the Sunday template already has the weekly
		-- review; Stretch (daily) is the one task left to write
		T.eq(store.add_repeating_tasks("2026-10-18"), 1)
		local block = store.date_block("2026-10-18")
		local lines = workspace.get_lines(cal)
		T.eq(vim.list_slice(lines, block.heading_lnum + 1, block.last_lnum), { "12:00 Weekly review", "- [ ] Stretch" })
		T.eq(store.add_repeating_tasks("2026-10-18"), 0, "already there")
		-- the copy stands for the occurrence: no second Stretch on the day
		local n = 0
		for _, e in ipairs(store.get_day_entries("2026-10-18")) do
			n = n + (e.text == "Stretch" and 1 or 0)
		end
		T.eq(n, 1)
		-- 2026-10-13: Stretch done, Water plants done for it on 10-14 (@for):
		-- nothing to write; a day with no repeating task isn't created
		T.eq(store.add_repeating_tasks("2026-10-13"), 0)
	end)
	vim.fn.writefile(before, cal)
	require("zortex.core.document").invalidate(cal)
	store.load()
	T.ok(ok, err)
end)

T.test("problems: a rule that can't work, @repeat or @on outside # Repeating", function()
	local lines = {
		"@@Calendar",
		"",
		"# Repeating",
		"- Bins @repeat(2w)", -- 4: no first day
		"- Typo @repeat(fortnightly)", -- 5
		"- Run @repeat(daily) @from(2026-10-21) @to(2026-10-01)", -- 6
		"- Old @repeat(2w) @since(2026-10-06)", -- 7
		"- Fine @repeat(2w tue) @from(2026-10-06) @to(2026-12-31)", -- 8
		"- Sam @repeat(03-14) @born(1990)", -- 9
		"- Gym @repeat(mon) @on(weekly)", -- 10: how often in @on
		"",
		"2026-10-20:",
		"- [ ] Water plants @repeat(daily)", -- 13
		"- Dentist @on(fri)", -- 14
	}
	local got = vim.tbl_map(function(p)
		return p.lnum .. " " .. p.message
	end, R.problems(lines))
	T.eq(got, {
		"4 Every n counts from a first day: add @from(YYYY-MM-DD)",
		"5 Not a repeat: daily, weekly, 2w, mon, weekdays, 03-14, 15th, 2nd tue, last",
		"6 @to is before @from: it never shows",
		"7 Every n counts from a first day: add @from(YYYY-MM-DD)",
		"10 @on takes days (mon, weekdays, 15th, 03-14, 2nd tue, last fri); how often goes in @repeat",
		"13 @repeat is read only in the # Repeating section",
		"14 @on is read only in the # Repeating section",
	})
	local p = R.problems(lines)[1]
	T.eq(lines[4]:sub(p.col + 1, p.end_col), "@repeat(2w)")
end)
