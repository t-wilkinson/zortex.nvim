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
		"Projects/1 Personal",
		"Projects/1 Personal/Habits",
	})
	T.eq(#r.unscheduled, 7) -- nothing is scheduled next week
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
