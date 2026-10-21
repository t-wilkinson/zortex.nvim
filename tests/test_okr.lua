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

T.test("spans: an objective's window, and the quarter's", function()
	T.eq(O.parse_span("3M-2026-Q4"), { span = "3M-2026-Q4", start_date = "2026-10-01", end_date = "2026-12-31" })
	T.eq(O.parse_span("1M-2026-11").end_date, "2026-11-30")
	T.eq(O.parse_span("6m-2026-h2").span, "6M-2026-H2")
	T.eq(O.parse_span("2026-Q4"), nil)
	T.eq(O.parse_span("Season 10"), nil)
	T.eq(O.quarter_span("2026-11-05"), "3M-2026-Q4")
end)

T.test("a new season: a 'Season N <word>' name and a heading in the OKR note, once", function()
	local workspace = require("zortex.core.workspace")
	local fs = require("zortex.utils.filesystem")
	local store = require("zortex.stores.xp")
	local stats = require("zortex.services.xp.stats")
	local file = fs.get_okr_file()
	local before = workspace.get_lines(file)
	local ok, err = pcall(function()
		T.eq(O.next_season_name(), "Season 1 Aspen", "no season heading yet, none ended")
		local season = stats.start_season("3M-2026-Q4")
		T.eq({ season.name, season.span, season.start_date, season.end_date }, { "Season 1 Aspen", "3M-2026-Q4", "2026-10-01", "2026-12-31" })
		local lines = workspace.get_lines(file)
		T.eq(lines[6], "# 3M-2026-Q4 Season 1 Aspen", "above the first top-level heading")
		T.eq(lines[8], "# Current")
		-- the heading is only for organizing: objectives keep their own windows
		T.eq(#O.objectives(), 2)
		T.eq({ O.objectives()[1]:window() }, { "2026-01-01", "2026-03-31" })
		-- the same span again: no second heading; the next name counts on
		T.eq(O.add_season_heading("3M-2026-Q4", "Again"), 6)
		T.eq(#workspace.get_lines(file), #lines)
		T.eq(O.next_season_name(), "Season 2 Birch")
		stats.start_season("1M-2027-01", "January sprint")
		T.eq(workspace.get_lines(file)[6], "# 1M-2027-01 January sprint")
		T.eq(select(2, stats.start_season("2027-Q1")) ~= nil, true, "not a span")
	end)
	store.reset_season()
	workspace.set_lines(file, 1, #workspace.get_lines(file), before)
	T.ok(ok, err)
end)

T.test("a key result with no project and no checkbox is stuck", function()
	local o2 = O.objectives()[2]
	T.eq(o2.key_results[2]:is_stuck(), false, "linked to a project")
	local kr = setmetatable(O.parse_key_result("- KR3: Read more"), O.KeyResult)
	kr.file, kr.lnum = "nowhere", 1
	T.eq(kr.has_box, false)
	T.eq(kr:is_stuck(), true)
	T.eq(O.parse_key_result("- KR3: [ ] Read more").has_box, true)
end)
