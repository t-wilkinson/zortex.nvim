local T = require("helpers")
local A = require("zortex.services.agenda")

local TODAY = "2026-10-11"

local function texts(items)
	return vim.tbl_map(function(i)
		return (i.time and (i.time .. " ") or "") .. i.text
	end, items)
end

T.test("day: calendar entries in time order, linked to projects", function()
	local items = A.day("2026-10-09")
	T.eq(#items, 3)
	T.eq(items[1].time, "14:00")
	T.eq(items[1].kind, "event")
	T.eq(items[1].project.key, "Projects/1 Programming/1.4 - zortex")
	T.eq(items[3].project.key, "Flipping/Subaru outback")
end)

T.test("day: project tasks due that day", function()
	local items = A.day("2026-10-12")
	T.eq(#items, 1)
	T.eq(items[1].kind, "due")
	T.eq(items[1].text, "Change task sizes")
	T.eq(items[1].project.key, "Projects/1 Programming/1.4 - zortex")
end)

T.test("range skips empty days unless asked", function()
	T.eq(#A.range("2026-10-09", "2026-10-12"), 3)
	T.eq(#A.range("2026-10-09", "2026-10-12", { include_empty = true }), 4)
	local only_due = A.range("2026-10-09", "2026-10-12", { kinds = { due = true } })
	T.eq(#only_due, 1)
	T.eq(#A.upcoming(3, { today = "2026-10-09" }), 2)
end)

T.test("upcoming events: appointments and notes of the days after a date, not tasks or project work", function()
	local fs = require("zortex.utils.filesystem")
	local cal = T.fixture("calendar.zortex")
	local original = fs.read_lines(cal)
	local lines = vim.list_extend(vim.deepcopy(original), {
		"",
		"**2026-10-15:**",
		"Outcomes:",
		"- [ ] Ship the release",
		"- Feel rested",
		"",
		"14:00 - 15:00 Dentist",
		"- Mum's birthday",
		"- [ ] Untimed task",
		"16:00 [ ] Timed task",
		"10:00 [P/#1.4 - zortex]",
		"11:00 Launch [P/#1.4 - zortex] @event",
	})
	fs.write_lines(cal, lines)
	require("zortex.core.document").invalidate(cal)
	require("zortex.core.link_index").refresh(true)
	local ok, err = pcall(function()
		local days = A.upcoming_events({ date = "2026-10-12", days = 7 })
		-- 10-09 / 10-10 (before) and their project blocks: left out
		T.eq(#days, 1)
		T.eq(days[1].date, "2026-10-15")
		T.eq(texts(days[1].items), { "11:00 Launch [P/#1.4 - zortex]", "14:00 Dentist", "16:00 Timed task", "Mum's birthday" })
		T.eq(#A.upcoming_events({ date = "2026-10-12", days = 2 }), 0, "two days end on 10-14")
		-- the day's outcomes: what's under its Outcomes: label, not events
		T.eq(vim.tbl_map(function(e)
			return e.text
		end, require("zortex.stores.calendar").outcomes("2026-10-15")), { "Ship the release", "Feel rested" })
		T.eq(A.upcoming_events({ date = "2026-10-12", days = 0 }), {})
	end)
	fs.write_lines(cal, original)
	require("zortex.core.document").invalidate(cal)
	require("zortex.core.link_index").refresh(true)
	assert(ok, err)
end)

T.test("the inbox: open lines after the header, in both reviews", function()
	local path = vim.fn.tempname() .. ".zortex"
	vim.fn.writefile({ "@@Inbox", "@Ignore", "", "- [ ] Call the plumber", "- [x] Done already", "- [>] Carried", "Idea from the web", "" }, path)
	local items = A.inbox(path)
	T.eq(vim.tbl_map(function(x)
		return x.text
	end, items), { "- [ ] Call the plumber", "Idea from the web" })
	T.eq(items[1].lnum, 4)
	T.eq(#A.inbox(vim.fn.tempname()), 0) -- no inbox note: nothing
	local review = require("zortex.ui.review")
	for _, scope in ipairs({ "day", "week" }) do
		local r = A.review({ today = TODAY, scope = scope })
		r.inbox = items
		local lines, locations = review.render(r)
		local at = vim.fn.index(lines, "- Idea from the web") + 1
		T.ok(at > 0, scope .. ": inbox line listed")
		T.eq(locations[at], { file = path, lnum = 7 })
		T.ok(lines[3]:find("2 in the inbox", 1, true), scope .. ": counted in the summary")
	end
	os.remove(path)
end)

T.test("review findings", function()
	local r = A.review({ today = TODAY, days = 7 })
	T.eq(texts(r.overdue), { "Morning routine", "Call the mechanic" })
	T.eq(texts(r.due_soon), { "Change task sizes" })
	T.eq(texts(r.completed), { "Order parts", "Evening routine" })

	local keys = function(list)
		return vim.tbl_map(function(x)
			return x.key
		end, list)
	end
	-- 1.4 - zortex and Subaru outback had calendar time this week: not stale
	T.eq(keys(r.stale), {
		"Projects/1 Programming/1.4 - esp32",
		"Projects/1 Programming/1.4 - zortex/1.4.1 - zortex search",
		"Projects/1 Personal/Habits",
	})
	T.eq(#r.unscheduled, 6) -- nothing is scheduled next week ("1 Personal" groups, not a project)
	T.eq(#r.no_next_action, 0)
	T.eq(vim.tbl_map(function(kr)
		return kr.id
	end, r.krs_without_projects), { "KR1", "KR3" })
	T.eq(#r.objectives_without_krs, 0)
	T.eq(keys(r.areas_without_projects), {
		"Areas/1 Personal Foundation",
		"Areas/1 Personal Foundation/1.1 Core values",
		"Areas/1 Personal Foundation/1.2 Vitality",
		"Areas/1 Personal Foundation/1.2 Vitality/Fitness",
		"Areas/4 Learning & Education/4.2 Personal Interests",
	})
	T.eq(#r.broken_links, 1)
end)
