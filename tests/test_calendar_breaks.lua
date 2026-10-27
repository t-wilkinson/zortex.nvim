local T = require("helpers")
local breaks = require("zortex.services.calendar_breaks")

-- a day's lines as rows, the way stores/calendar reads them
local function day(lines, date)
	local entries = require("zortex.services.calendar_entry")
	local own = {}
	for i, l in ipairs(lines) do
		local e = entries.from_text(l, date or "2026-10-26")
		if e then
			e.lnum = i
			own[#own + 1] = e
		end
	end
	return breaks.rows(require("zortex.stores.calendar").day_layout(own))
end

local function resumes(lines)
	local out = {}
	for _, r in ipairs(breaks.resumes(day(lines))) do
		out[#out + 1] = { r.block.lnum, r.after.lnum, breaks.hhmm(r.from), r.to and breaks.hhmm(r.to) or "" }
	end
	return out
end

T.test("calendar.json resumes match calendar_breaks (regenerate with tests/gen_edits.lua)", function()
	local fixture = vim.json.decode(table.concat(vim.fn.readfile(T.root .. "/tests/fixtures/calendar.json"), "\n"))
	local store = require("zortex.stores.calendar")
	local n = 0
	for date, entries in pairs(store.parse_lines(require("calendar_cases"))) do
		local got = {}
		for _, r in ipairs(breaks.resumes(breaks.rows(store.day_layout(entries)))) do
			got[#got + 1] = { block = r.block.lnum, after = r.after.lnum, from = breaks.hhmm(r.from), to = r.to and breaks.hhmm(r.to) or "" }
		end
		T.eq(got, fixture.resumes[date] or {}, date)
		n = n + #got
	end
	T.ok(n >= 6, "the fixture has breaks")
end)

T.test("a line with a duration is a break; the block resumes until the next line", function()
	T.eq(resumes({ "10:00 Study", "12:00 Break @15m", "14:00 Gym" }), { { 1, 2, "12:15", "14:00" } })
	-- a range works the same; the day's end leaves it open
	T.eq(resumes({ "10:00 Study", "12:00 - 12:15 Break" }), { { 1, 2, "12:15", "" } })
	-- written out of order, it reads by time
	T.eq(resumes({ "12:00 Break @15m", "10:00 Study" }), { { 2, 1, "12:15", "" } })
	-- the next line starts as the break ends: a switch, nothing resumes
	T.eq(resumes({ "10:00 Study", "12:00 Lunch @1h", "13:00 Errands" }), {})
	-- without an end, a line starts something new
	T.eq(resumes({ "10:00 Study", "12:00 Lunch", "14:00 Gym" }), {})
	-- a ranged block ends where it says
	T.eq(resumes({ "10:00 - 12:30 Study", "12:00 Break @15m" }), { { 1, 2, "12:15", "12:30" } })
	-- a block that ends before the break does isn't interrupted
	T.eq(resumes({ "10:00 - 12:10 Study", "12:00 Break @15m" }), {})
	-- several breaks, each back to the same block
	T.eq(resumes({ "10:00 Study", "11:00 Coffee @10m", "12:00 Break @15m", "14:00 Gym" }), {
		{ 1, 2, "11:10", "12:00" },
		{ 1, 3, "12:15", "14:00" },
	})
end)

T.test("a break nested under a block resumes it; events and finished tasks don't hold", function()
	T.eq(resumes({ "10:00 - 14:00 Study", "  12:00 Break @15m", "  - [ ] Read" }), { { 1, 2, "12:15", "14:00" } })
	T.eq(resumes({ "10:00 Study", "  12:00 Break @15m", "  13:00 Tea @10m", "15:00 Gym" }), {
		{ 1, 2, "12:15", "13:00" },
		{ 1, 3, "13:10", "15:00" },
	})
	-- an @event without an end is a moment, not a block
	T.eq(resumes({ "10:00 Dentist @event", "10:30 Call @15m" }), {})
	T.eq(resumes({ "09:00 Study", "10:00 Dentist @event", "10:30 Call @15m", "12:00 Gym" }), { { 1, 3, "10:45", "12:00" } })
	-- a done (or carried) task isn't resumed
	T.eq(resumes({ "10:00 [x] Report @done(2026-10-26)", "11:00 Break @15m" }), {})
	T.eq(resumes({ "10:00 [ ] Report", "11:00 Break @15m" }), { { 1, 2, "11:15", "" } })
end)

T.test("now is the block again once the break is over", function()
	local ct = require("zortex.features.calendar_time")
	local lines = { "@@Calendar", "", "2026-10-26:", "10:00 Study", "12:00 Break @15m", "14:00 Gym" }
	T.eq(ct.line_for_time(lines, 3, "09:00", "2026-10-26"), nil)
	T.eq(ct.line_for_time(lines, 3, "11:00", "2026-10-26"), 4)
	T.eq(ct.line_for_time(lines, 3, "12:05", "2026-10-26"), 5)
	T.eq(ct.line_for_time(lines, 3, "12:15", "2026-10-26"), 4)
	T.eq(ct.line_for_time(lines, 3, "13:59", "2026-10-26"), 4)
	T.eq(ct.line_for_time(lines, 3, "15:00", "2026-10-26"), 6)
	-- a month heading ends the day
	local grouped = { "@@Calendar", "", "2026-10-26:", "10:00 Study", "", "# November 2026", "2026-11-01:", "09:00 Later" }
	T.eq(ct.line_for_time(grouped, 3, "23:00", "2026-10-26"), 4)
end)

T.test("notifications say Back to the block when a break ends", function()
	local fs = require("zortex.utils.filesystem")
	local store = require("zortex.stores.calendar")
	local cal = fs.get_calendar_file()
	local before = vim.fn.readfile(cal)
	local today = os.date("%Y-%m-%d")
	local ok, err = pcall(function()
		vim.fn.writefile({
			"@@Calendar",
			"",
			today .. ":",
			"10:00 Work on [P/#1.4 - zortex]",
			"12:00 Break @15m @n(0, end)",
			"14:00 Gym",
		}, cal)
		require("zortex.core.document").invalidate(cal)
		store.load()
		local t = os.date("*t")
		local morning = os.time({ year = t.year, month = t.month, day = t.day, hour = 6 })
		local list = require("zortex.notifications.calendar").collect(morning)
		local titles = {}
		for _, n in ipairs(list) do
			if os.date("%Y-%m-%d", n.trigger_time) == today then
				titles[#titles + 1] = os.date("%H:%M", n.trigger_time) .. " " .. n.title .. " | " .. n.message
			end
		end
		T.eq(titles, {
			"10:00 Work on 1.4 - zortex | 10:00",
			"12:00 Break | 12:00–12:15",
			"12:15 Back to Work on 1.4 - zortex | 12:15–14:00",
			"14:00 Gym | 14:00",
		})
	end)
	vim.fn.writefile(before, cal)
	require("zortex.core.document").invalidate(cal)
	store.load()
	T.ok(ok, err)
end)
