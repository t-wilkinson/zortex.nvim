local T = require("helpers")
local Config = require("zortex.config")

-- XP config as the plugin ships it (Config.setup is skipped in tests)
Config.xp = vim.deepcopy(Config.defaults.xp)
require("zortex.services.xp.calculator").setup(Config.xp)
require("zortex.stores.xp").setup(Config.xp)

local ledger = require("zortex.services.xp.ledger")
local calculator = require("zortex.services.xp.calculator")
local store = require("zortex.stores.xp")
local stats = require("zortex.services.xp.stats")
local fs = require("zortex.utils.filesystem")
local Document = require("zortex.core.document")

local ZORTEX = "Projects/1 Programming/1.4 - zortex"
local AREA41 = "Areas/4 Learning & Education/4.1 Education & Skills"

local function approx(a, b)
	return math.abs(a - b) < 1e-6
end

local function edit(path, fn)
	local lines = fs.read_lines(path)
	local original = vim.deepcopy(lines)
	fn(lines)
	fs.write_lines(path, lines)
	Document.invalidate(path)
	return function()
		fs.write_lines(path, original)
		Document.invalidate(path)
		ledger.invalidate()
	end
end

T.test("curves pay out the whole pool when every task is done", function()
	for total = 1, 40 do
		local steps = calculator.curve_steps(100, total, total)
		local sum = 0
		for _, x in ipairs(steps) do
			sum = sum + x
		end
		T.ok(approx(sum, 100), string.format("%d tasks pay %.2f", total, sum))
	end
	-- the first task of a small project is the big one (initiation)
	local steps = calculator.curve_steps(100, 5, 5)
	T.ok(approx(steps[1], 40) and approx(steps[2], 20) and approx(steps[5], 10), vim.inspect(steps))
end)

T.test("@size is hours (xp.sizes) x xp_per_hour; unsized and unknown sizes count md", function()
	T.eq(calculator.calculate_task_xp({ attributes = { size = "xl" } }), 30)
	T.eq(calculator.calculate_task_xp({ attributes = { size = "5xl" } }), 200)
	T.eq(calculator.task_points("nonsense"), 1)
	T.eq(calculator.task_points(nil), 1)
	T.eq(calculator.calculate_task_xp({ attributes = { size = "md", p = "1" } }), 15)
	T.eq(calculator.calculate_project_total_xp({ attributes = { xp = 42 } }, {}), 42)
	T.eq(calculator.calculate_project_total_xp({ attributes = { size = "lg" } }, {}), 200)
	T.eq(calculator.hours("objective", "md"), 30)
	T.eq(
		{ calculator.alignment("key_result"), calculator.alignment("project_area"), calculator.alignment("task_area") },
		{ 1.0, 0.2, 0.1 }
	)
	T.eq(calculator.alignment("nothing"), 0)
end)

T.test("objective value: @size, else its key results' projects, else md", function()
	local okr = require("zortex.services.okr")
	local by_title = {}
	for _, o in ipairs(okr.objectives()) do
		by_title[o.title] = o
	end
	-- @sm: 10 hours, @p2 x1.2
	local habits = by_title["Establish and maintain good habits/routine"]
	T.eq({ calculator.objective_hours(habits) }, { 10, "size" })
	T.ok(approx(calculator.objective_value(habits), 120))
	-- no @size: 1.4 - zortex (@size(lg), 20h) + 1.4.1 (an sm task, 0.5h); @p1 x1.5
	local ship = by_title["Ship zortex projects"]
	T.eq({ calculator.objective_hours(ship) }, { 20.5, "projects" })
	T.ok(approx(calculator.objective_value(ship), 307.5))
	T.ok(approx(calculator.calculate_objective_xp(ship), 61.5)) -- the 20% completion bonus
	T.eq({ calculator.objective_hours({ attributes = {}, key_results = {} }) }, { 30, "default" })
end)

T.test("project awards: pool over live and archived tasks, areas via key result", function()
	ledger.invalidate()
	local entries, total = ledger.for_project(ZORTEX)
	-- @size(lg): 20 hours = 200 XP over 6 tasks (5 live + 1 archived) ->
	-- medium curve; 3 done = the initiation phase (25%)
	T.eq(#entries, 3)
	T.ok(approx(total, 200 * 0.25), tostring(total))
	-- a key result links the project, so its area gets the whole award
	local to_area = 0
	for _, e in ipairs(entries) do
		to_area = to_area + (e.areas[AREA41] or 0)
		T.eq(e.aligned, "kr")
		T.ok(approx(e.mastery, e.xp))
	end
	T.ok(approx(to_area, 200 * 0.25), tostring(to_area))
	-- plus the reached key result ("KR1: [x] Projects API"): 20% of the
	-- objective's 307.5 XP over its 2 key results, to the objective's area
	T.ok(approx(ledger.area_xp(AREA41), 200 * 0.25 + 30.75), tostring(ledger.area_xp(AREA41)))
	-- the parent gets 75% of it
	local parent = require("zortex.services.areas").get("Areas/4 Learning & Education")
	T.ok(approx(parent:total_xp(), 0.75 * (200 * 0.25 + 30.75)))
end)

T.test("key results: reached ones award their objective's areas", function()
	ledger.invalidate()
	local krs = {}
	for _, e in ipairs(ledger.get().entries) do
		if e.source == "key_result" then
			krs[#krs + 1] = e
		end
	end
	T.eq(#krs, 1, vim.inspect(vim.tbl_map(function(e)
		return e.title
	end, krs)))
	local projects_api
	for _, e in ipairs(krs) do
		if e.title:find("Projects API", 1, true) then
			projects_api = e
		end
	end
	T.ok(projects_api, "KR1 Projects API")
	T.ok(approx(projects_api.xp, 30.75), tostring(projects_api.xp))
	T.ok(approx(projects_api.areas[AREA41], 30.75))
end)

T.test("objective areas come first for work on a key result", function()
	local task = { attributes = { area = { { definition = "Areas/#4.2" } } } }
	local p_areas = { objective = { "Areas/obj" }, own = { "Areas/own" } }
	local list = ledger._award_areas(task, p_areas)
	T.eq({ list[1], list[2] }, { "Areas/obj", "Areas/own" })
	-- no key result: the task's own area, then the project's
	list = ledger._award_areas(task, { objective = {}, own = { "Areas/own" } })
	T.eq(list[#list], "Areas/own")
	T.ok(#list == 2 and list[1] ~= "Areas/own", vim.inspect(list))
	-- and the first gets the larger share
	local shares = require("zortex.services.xp.calculator").area_shares(30, { "Areas/obj", "Areas/own" }, 1.0)
	T.ok(shares["Areas/obj"] > shares["Areas/own"])
end)

T.test("standalone tasks (calendar) count, dated by @done", function()
	ledger.invalidate()
	local found
	for _, e in ipairs(ledger.get().entries) do
		if e.source == "task" and e.title == "Order parts" then
			found = e
		end
	end
	T.ok(found, "calendar task in the ledger")
	T.eq(found.xp, 10)
	T.eq(found.date, "2026-10-06")
end)

T.test("a season is progress on its objectives; tiers are thresholds on it", function()
	local season = require("zortex.services.xp.season")
	ledger.invalidate()
	-- the fixture's objectives are 3M-2026-Q1
	store.start_season("Test", "2026-03-31", "2026-01-01")
	local s = season.status(store.started_season())
	T.eq(#s.objectives, 2)
	-- largest value first: Ship zortex (307.5, KR1 done, KR2 open: 50%),
	-- habits (120: KR2 half its project's points, the others 0: 1/6)
	T.eq(s.objectives[1].objective.title, "Ship zortex projects")
	T.ok(approx(s.objectives[1].share, 307.5 / 427.5))
	local expected = (307.5 * 0.5 + 120 / 6) / 427.5
	T.ok(approx(s.progress, expected), tostring(s.progress))
	T.eq(s.tier.name, "Bronze")
	T.eq(s.next_tier.name, "Silver")

	-- reaching KR2 finishes the objective: Gold
	local okr = fs.get_okr_file()
	local restore = edit(okr, function(lines)
		for i, l in ipairs(lines) do
			if l:find("KR2: [ ] Search works", 1, true) then
				lines[i] = l:gsub("%[ %]", "[x]", 1)
			end
		end
	end)
	s = season.status(store.started_season())
	T.ok(approx(s.progress, (307.5 + 20) / 427.5), tostring(s.progress))
	T.eq(s.tier.name, "Gold")
	local record = stats.end_season()
	T.eq(record.final_tier, "Gold")
	T.ok(approx(record.final_progress, (307.5 + 20) / 427.5))
	restore()

	-- a season without objectives in its window has none to make progress on
	store.start_season("Later", "2026-12-31", "2026-10-01")
	s = season.status(store.started_season())
	T.eq(#s.objectives, 0)
	T.eq(s.progress, 0)
	T.eq(s.tier, nil)
	store.reset_season()
end)

T.test("unchecking removes XP; nothing double-counts", function()
	ledger.invalidate()
	local before = ledger.window_totals("2026-10-01", "2026-12-31").xp
	T.ok(before > 0, "Order parts (10-06) and Evening routine (10-08) are in the window")
	local cal = fs.get_calendar_file()
	local restore = edit(cal, function(lines)
		for i, l in ipairs(lines) do
			if l:find("Call the mechanic", 1, true) then
				lines[i] = "- [x] Call the mechanic @done(2026-10-12)"
			end
		end
	end)
	T.eq(ledger.window_totals("2026-10-01", "2026-12-31").xp, before + 10)
	T.eq(ledger.window_totals("2026-10-01", "2026-12-31").xp, before + 10)
	restore()
	T.eq(ledger.window_totals("2026-10-01", "2026-12-31").xp, before)
	T.eq(ledger.window_totals("2026-10-09", "2026-12-31").xp, 0)
end)

T.test("a project marked @done pays out the rest of its pool", function()
	local path = fs.get_projects_file()
	local restore = edit(path, function(lines)
		for i, l in ipairs(lines) do
			if l:match("^## Habits") then
				lines[i] = "## Habits @done(2026-10-10)"
			end
		end
	end)
	ledger.invalidate()
	local entries, total = ledger.for_project("Projects/1 Personal/Habits")
	T.eq(total, 20) -- two md tasks: the whole pool
	T.eq(entries[#entries].source, "project_done")
	T.eq(entries[#entries].date, "2026-10-10")
	restore()
end)

T.test("objectives marked @done earn area XP", function()
	local path = fs.get_okr_file()
	local restore = edit(path, function(lines)
		for i, l in ipairs(lines) do
			if l:find("Ship zortex projects", 1, true) then
				lines[i] = l .. " @done(2026-10-11)"
			end
		end
	end)
	ledger.invalidate()
	local obj
	for _, e in ipairs(ledger.get().entries) do
		if e.source == "objective" then
			obj = e
		end
	end
	T.ok(obj, "objective award")
	-- 20% of the objective's 307.5 XP, all to 4.1
	T.ok(approx(obj.xp, 61.5), tostring(obj.xp))
	T.ok(approx(obj.areas[AREA41], 61.5))
	T.eq(obj.aligned, "kr")
	restore()
end)

T.test("tasks checked by hand get @done on save", function()
	local cal = fs.get_calendar_file()
	vim.cmd("edit! " .. vim.fn.fnameescape(cal))
	local buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local target
	for i, l in ipairs(lines) do
		if l:find("Call the mechanic", 1, true) then
			target = i
		end
	end
	vim.api.nvim_buf_set_lines(buf, target - 1, target, false, { "- [x] Call the mechanic" })
	T.eq(require("zortex.services.xp.core").stamp_done(buf), 1)
	T.eq(vim.api.nvim_buf_get_lines(buf, target - 1, target, false)[1], "- [x] Call the mechanic @done(" .. os.date("%Y-%m-%d") .. ")")
	-- an old checked task (identical on disk) is left alone
	T.ok(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[target + 1]:match("@done%(2026%-10%-06%)"))
	vim.cmd("bwipeout!")
end)

T.test("area awards go to the most specific area first (deterministic)", function()
	local shares = calculator.area_shares(30, { "A", "B", "C" }, 1)
	T.ok(shares.A > shares.B and shares.B > shares.C)
	T.ok(approx(shares.A + shares.B + shares.C, 30))
end)

T.test("query.xp is plain data", function()
	store.start_season("Q", "2026-12-31", "2026-10-01")
	local q = require("zortex.query").xp({ days = 3650 })
	T.eq(q.season.name, "Q")
	T.ok(#q.awards > 0 and q.awards[1].rel, vim.inspect(q.awards[1]))
	T.eq(q.areas[1].key, AREA41)
	T.eq(#q.daily, 14)
	T.ok(vim.json.encode(q))
	store.reset_season()
end)

T.test("publish: summary for the web app, written only when it changes", function()
	local publish = require("zortex.services.xp.publish")
	publish._reset()
	store.start_season("Pub", "2026-12-31", "2026-10-01")
	local s = publish.summary()
	T.eq(s.version, 2)
	T.eq(s.season.name, "Pub")
	T.ok(s.season.progress >= 0 and s.season.progress <= 1)
	T.eq(#s.season.tiers, 5)
	T.eq(#s.daily, 14)
	T.eq(s.areas[1].key, AREA41)
	T.ok(s.areas[1].progress >= 0 and s.areas[1].progress <= 1)
	T.ok(publish.publish(), "first publish writes")
	local path = require("zortex.core.state").path("xp_summary")
	local written = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	T.eq(written.season.name, "Pub")
	T.ok(written.generated:match("^%d%d%d%d%-%d%d%-%d%dT"), written.generated)
	T.eq(publish.publish(), false) -- unchanged: nothing written
	store.reset_season()
	T.ok(publish.publish(), "season ended: changed")
	-- with no season started by hand, the calendar quarter is the season
	local q = require("zortex.services.okr.objective").quarter()
	T.eq(vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).season.name, q.name)
end)

T.test("seasons follow the calendar quarter unless one was started", function()
	store.reset_season()
	local s = store.current_season("2026-11-05")
	T.eq({ s.name, s.start_date, s.end_date, s.auto }, { "2026 Q4", "2026-10-01", "2026-12-31", true })
	store.start_season("Sprint", "2026-11-30", "2026-11-01")
	T.eq(store.current_season("2026-11-05").name, "Sprint")
	-- past its end date: back to the quarter
	T.eq(store.current_season("2026-12-05").name, "2026 Q4")
	store.reset_season()
end)

T.test(":ZortexXPGuide spells out the calibration from the config", function()
	local guide = require("zortex.ui.xp_guide")
	T.eq(guide.format_hours(0.25), "15m")
	T.eq(guide.format_hours(1.5), "1h30m")
	T.eq(guide.format_hours(2500), "2,500h")
	local lines = guide.lines()
	local text = table.concat(lines, "\n")
	T.ok(text:find("10 XP = 1 hour", 1, true), text)
	-- one row per size: tasks, projects, objectives side by side
	T.ok(text:find("  xs            15m     2.5   xs             2h      20   xs             5h      50\n", 1, true), text)
	T.ok(text:find("  lg             2h      20   lg            20h     200   lg            60h     600\n", 1, true), text)
	T.ok(text:find("  5xl           20h     200   ultimate   2,500h  25,000\n", 1, true), text)
	T.ok(text:find("10: 9,993h", 1, true), text)
	T.ok(text:find("@p1 ×1.5", 1, true), text)
	T.ok(text:find("×0.2", 1, true) and text:find("×0.1", 1, true), text)
	T.ok(text:find("earns 420 Mastery XP", 1, true), text)
	T.ok(text:find("Bronze 25%", 1, true), text)

	-- at the cursor: a project task and its project
	vim.cmd("edit! " .. vim.fn.fnameescape(fs.get_projects_file()))
	local buf = vim.api.nvim_get_current_buf()
	local lnum
	for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if l:find("Improve website", 1, true) then
			lnum = i
		end
	end
	local ctx = table.concat(guide.context(buf, lnum), "\n")
	T.ok(ctx:find("Task (@xl): 3h → 30 XP ×1.5 = 45 XP", 1, true), ctx)
	T.ok(ctx:find("Project 1.4 - zortex: 200 XP, 20h of estimated work (@lg: 20h)", 1, true), ctx)
	T.ok(ctx:find("linked from a key result", 1, true), ctx)
	local _, win = guide.show()
	T.ok(vim.api.nvim_win_is_valid(win))
	vim.api.nvim_win_close(win, true)
	vim.cmd("bwipeout!")

	-- and on an objective
	vim.cmd("edit! " .. vim.fn.fnameescape(fs.get_okr_file()))
	buf = vim.api.nvim_get_current_buf()
	for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if l:find("Projects API", 1, true) then
			lnum = i
		end
	end
	ctx = table.concat(guide.context(buf, lnum), "\n")
	T.ok(not ctx:find("Task", 1, true), ctx)
	T.ok(ctx:find("Objective Ship zortex projects: 21h (its key results' projects) → 308 XP · 50% done", 1, true), ctx)
	vim.cmd("bwipeout!")
end)

T.test("xp.area_split: each area gets the ratio of the one before", function()
	local c = require("zortex.services.xp.calculator")
	local half = c._distribute_on_curve(70, 3, 0.5)
	T.ok(approx(half[1], 40) and approx(half[2], 20) and approx(half[3], 10), vim.inspect(half))
	local even = c._distribute_on_curve(30, 3, 1)
	T.ok(approx(even[1], 10) and approx(even[3], 10), vim.inspect(even))
	local gentle = c._distribute_on_curve(100, 2, 0.7)
	T.ok(approx(gentle[1] + gentle[2], 100) and approx(gentle[2] / gentle[1], 0.7), vim.inspect(gentle))
end)

T.test(":ZortexXP: season, the last two weeks, projects, recent awards and areas in one view", function()
	local ui = require("zortex.ui.xp")
	local lines, _, where = ui.render()
	for _, heading in ipairs({ "^## Season", "^## Last 14 days", "^## Projects in progress", "^## Recent", "^## Areas" }) do
		T.ok(vim.iter(lines):any(function(l)
			return l:match(heading) ~= nil
		end), heading .. "\n" .. table.concat(lines, "\n"))
	end
	-- a project line knows where it is written, for <CR> and e
	local found
	for lnum, loc in pairs(where) do
		if loc.project then
			found = lines[lnum]
		end
	end
	T.ok(found and found:find("XP %(", 1) ~= nil, tostring(found))
	-- the split of the work done adds up
	local work = ui.recent_work(14)
	T.eq(#work.days, 14)
	T.ok(math.abs(work.kr + work.area + work.none - work.total) < 1e-6)
end)
