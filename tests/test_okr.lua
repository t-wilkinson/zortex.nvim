local T = require("helpers")
local O = require("zortex.services.okr")
local P = require("zortex.services.projects")

local function approx(a, b)
	return math.abs(a - b) < 1e-6
end

T.test("objectives are entities with O/ links that resolve back", function()
	local objs = O.objectives()
	T.eq(#objs, 2)
	T.eq(objs[1].key, "Objectives/Current/3M-2026-Q1 Establish and maintain good habits/routine")
	-- "/" in a name: the link component stops before it (prefix match)
	T.eq(objs[1].link, "[O/#Current/#3M-2026-Q1 Establish and maintain good habits]")
	for _, o in ipairs(O.all()) do
		T.eq((O.resolve(o.link) or {}).key, o.key, o.link)
	end
	T.eq(O.get("Objectives/Current").is_objective, false) -- container heading
end)

T.test("KR projects come from the link index", function()
	local kr2 = O.objectives()[1].key_results[2]
	T.eq(kr2.id, "KR2")
	T.eq(vim.tbl_keys(kr2.projects), { "Projects/1 Personal/Habits" })
	T.eq(#O.objectives()[1]:projects(), 1)
end)

T.test("KR progress: checkbox, or points done across linked projects", function()
	local o1, o2 = unpack(O.objectives())
	T.ok(approx(o1.key_results[2]:progress(), 0.5), "Habits: 3 of 6 points")
	T.eq(o1.key_results[1]:progress(), 0) -- no links, unchecked
	T.eq(o2.key_results[1]:progress(), 1) -- checked
	T.eq(o2.key_results[2]:progress(), 0) -- 1.4.1 has no done tasks
	T.ok(approx(o1:progress(), 0.5 / 3), "objective = mean of KRs")
	T.ok(approx(o2:progress(), 0.5))
end)

T.test("open key results and objective areas", function()
	T.eq(#O.key_results(), 5)
	T.eq(#O.key_results({ open = true }), 4)
	local o2 = O.objectives()[2]
	T.eq(o2:areas()[1].name, "4.1 Education & Skills")
	T.eq(#O.objectives()[1]:areas(), 0) -- @a(2.1) doesn't exist
end)

T.test("get_key_results(project) still works for XP", function()
	local krs, objs = O.get_key_results(P.get("Projects/1 Personal/Habits"))
	T.eq(#krs, 1)
	T.eq(objs[1].title, "Establish and maintain good habits/routine")
end)

T.test("key results have explicit links that resolve to their line", function()
	local okr = require("zortex.services.okr")
	local resolver = require("zortex.core.link")
	for _, kr in ipairs(okr.key_results()) do
		T.ok(kr.link and kr.link:match("/%-KR%d+%]$"), tostring(kr.link))
		local r = resolver.resolve_first(kr.link)
		T.ok(r and r.lnum == kr.lnum, kr.link .. " -> " .. (r and r.lnum or "nil") .. " want " .. kr.lnum)
	end
	-- the key is not repeated in the text, with or without a checkbox
	local parse = okr.parse_key_result
	T.eq(parse("- KR1: Zortex").text, "Zortex")
	T.eq(parse("- KR1: [ ] Zortex").text, "Zortex")
end)

T.test("link text stops at link syntax, @ and |, and still resolves", function()
	local resolver = require("zortex.core.link")
	T.eq(resolver.component_text("Establish habits/routine"), "Establish habits")
	T.eq(resolver.component_text("4 Learning & Education"), "4 Learning & Education")
	T.eq(resolver.component_text("Don't break, ever?"), "Don't break, ever?")
	T.eq(resolver.component_text("Café crème"), "Café crème")
	T.eq(resolver.component_text("C# and F#; more"), "C# and F#; more")
	T.eq(resolver.component_text("Talk to Sam @p1"), "Talk to Sam")
	T.eq(resolver.component_text("a | b"), "a")
	T.eq(resolver.component_text("Items, "), "Items")
	T.eq(resolver.component_text("[Weird] [title]"), "Weird title")
	T.eq(resolver.component_text("Notes (draft v2.1)"), "Notes (draft v2.1)")
	T.eq(resolver.component_text("Notes (draft: v2)"), "Notes (draft: v2)")
	T.eq(resolver.component_text("6.3: Homelab"), "6.3: Homelab")
	T.eq(resolver.component_text("Async book: "), "Async book")
	T.eq(resolver.component_text("Notes (draft & v2)"), "Notes (draft & v2)")
	T.eq(resolver.component_text("Notes (draft [x]"), "Notes")
	T.eq(resolver.item_component("- [ ] Call the bank @p1"), "-Call the bank")
	T.eq(resolver.item_component("- KR2: [ ] Make list"), "-KR2")
	local r = resolver.resolve_first("[P/#1 Programming/#1.4 - zortex/-Improve website]")
	T.ok(r and r.doc.lines[r.lnum]:find("Improve website", 1, true), r and r.doc.lines[r.lnum])
end)

T.test("season headings: when they start, and how long they run", function()
	local obj = require("zortex.services.okr.objective")
	local function window(text)
		local s = obj.parse_season(text)
		return s and (s.start .. ".." .. s.natural_end) or nil
	end
	T.eq(window("2026-Q4 Season 10 Juniper"), "2026-10-01..2026-12-31")
	T.eq(window("2026-10 Season"), "2026-10-01..2026-12-29")
	T.eq(window("2026-October Season"), "2026-10-01..2026-12-29")
	T.eq(window("2026-oct"), "2026-10-01..2026-12-29")
	T.eq(window("2026-10-20 Season 11 Kapok"), "2026-10-20..2027-01-17")
	T.eq(obj.parse_season("2026-10-20 Season 11 Kapok").name, "Season 11 Kapok")
	for _, not_season in ipairs({ "3M-2026-Q4 Title", "Current", "2026-Q5", "2026-13", "2026-Ju x" }) do
		T.eq(obj.parse_season(not_season), nil, not_season)
	end
	-- a season ends the day before the next one starts
	local lines = { "@@OKR", "", "# 2026-11-15 Season 11", "", "# 2026-Q4 Season 10" }
	T.eq({ obj.season_window(lines, 5) }, { "2026-10-01", "2026-11-14" })
	T.eq({ obj.season_window(lines, 3) }, { "2026-11-15", "2027-02-12" })
end)

T.test("objectives under a season heading share its window; new seasons get a heading", function()
	local workspace = require("zortex.core.workspace")
	local fs = require("zortex.utils.filesystem")
	local file = fs.get_okr_file()
	local before = workspace.get_lines(file)
	local ok, err = pcall(function()
		local lines = vim.list_extend({ "@@OKR", "", "# 2026-Q4 Season 10 Juniper", "## Learn piano @a(4.1)", "- KR1: [x] Scales", "### Notes", "" }, vim.list_slice(before, 5))
		workspace.set_lines(file, 1, #before, lines)
		local objs = O.objectives()
		T.eq(objs[1].title, "Learn piano")
		T.eq({ objs[1]:window() }, { "2026-10-01", "2026-12-31" })
		T.eq(objs[1]:progress(), 1)
		T.eq(objs[1].section, "2026-Q4 Season 10 Juniper")
		T.eq(#objs, 3, "the prefixed objectives still count")
		T.eq(O.get("OKR/2026-Q4 Season 10 Juniper/Learn piano/Notes").is_objective, false)

		-- the next season: a number and its word, a heading on top
		T.eq(O.next_season_name(), "Season 11 Kapok")
		T.eq(O.season_token("2027-01-01", "2027-03-31"), "2027-Q1")
		T.eq(O.season_token("2026-10-20", "2027-01-17"), "2026-10-20")
		local stats = require("zortex.services.xp.stats")
		local lnum = stats.start_season(nil, "2027-02-12", "2026-11-15")
		T.eq(lnum, 3)
		local now = workspace.get_lines(file)
		T.eq(now[3], "# 2026-11-15 Season 11 Kapok")
		T.eq(now[5], "# 2026-Q4 Season 10 Juniper")
		T.eq(require("zortex.stores.xp").started_season().name, "Season 11 Kapok")
		-- the older season now stops where the new one starts
		T.eq({ O.objectives()[1]:window() }, { "2026-10-01", "2026-11-14" })
		-- starting it again doesn't add a second heading
		T.eq(require("zortex.services.okr").add_season_heading("Season 11 Kapok", "2026-11-15"), 3)
		T.eq(#workspace.get_lines(file), #now)
	end)
	require("zortex.stores.xp").reset_season()
	workspace.set_lines(file, 1, #workspace.get_lines(file), before)
	T.ok(ok, err)
end)
