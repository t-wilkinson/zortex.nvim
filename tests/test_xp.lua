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

T.test("sizes come from xp.sources (unlisted ones count 1)", function()
	T.eq(calculator.calculate_task_xp({ attributes = { size = "xl" } }), 30)
	T.eq(calculator.calculate_task_xp({ attributes = { size = "5xl" } }), 180)
	T.eq(calculator.size_multiplier("task", "nonsense"), 1)
	T.eq(calculator.task_points(nil), 1)
	T.eq(calculator.calculate_task_xp({ attributes = { size = "md", p = "1" } }), 15)
	T.eq(calculator.calculate_project_total_xp({ attributes = { xp = 42 } }, {}), 42)
end)

T.test("project awards: pool over live and archived tasks, areas via key result", function()
	ledger.invalidate()
	local entries, total = ledger.for_project(ZORTEX)
	-- @size(lg): 70 × 1.5 = 105 over 6 tasks (5 live + 1 archived) -> medium
	-- curve; 3 done = the initiation phase (25%), 8.75 each
	T.eq(#entries, 3)
	T.ok(approx(total, 105 * 0.25), tostring(total))
	-- a key result links the project, so its area gets the whole award
	T.ok(approx(ledger.area_xp(AREA41), 105 * 0.25), tostring(ledger.area_xp(AREA41)))
	-- the parent gets 75% of it
	local parent = require("zortex.services.areas").get("Areas/4 Learning & Education")
	T.ok(approx(parent:total_xp(), 0.75 * 105 * 0.25))
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

T.test("seasons are date windows; unchecking removes XP; nothing double-counts", function()
	ledger.invalidate()
	store.start_season("Test", "2026-12-31", "2026-10-01")
	local before = stats.season_status().xp
	T.ok(before > 0, "Order parts (10-06) and Evening routine (10-08) are in the window")

	local cal = fs.get_calendar_file()
	local restore = edit(cal, function(lines)
		for i, l in ipairs(lines) do
			if l:find("Call the mechanic", 1, true) then
				lines[i] = "- [x] Call the mechanic @done(2026-10-12)"
			end
		end
	end)
	T.eq(stats.season_status().xp, before + 10)
	-- end and restart the season: the same completions, the same XP
	local record = stats.end_season()
	T.eq(record.final_xp, before + 10)
	store.start_season("Again", "2026-12-31", "2026-10-01")
	T.eq(stats.season_status().xp, before + 10)
	-- unchecking takes it back
	restore()
	T.eq(stats.season_status().xp, before)
	-- a season that starts later excludes older completions
	store.start_season("Later", "2026-12-31", "2026-10-09")
	T.eq(stats.season_status().xp, 0)
	store.reset_season()
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
	-- 20 × Q (3M) 1.5 × p1 1.5 = 45, all to 4.1
	T.ok(approx(obj.xp, 45), tostring(obj.xp))
	T.ok(approx(obj.areas[AREA41], 45))
	T.eq(obj.season_xp, 0)
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

T.test("migration from the transaction log keeps seasons only", function()
	local State = require("zortex.core.state")
	local path = State.path("xp_state")
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	vim.fn.writefile({
		vim.json.encode({
			version = 1,
			season_xp = 99,
			season_level = 3,
			area_xp = { x = 5 },
			xp_transactions = { a = { base_xp = 5 } },
			current_season = { name = "Q", start_date = "2026-10-01", end_date = "2026-12-31" },
			season_history = { { name = "P", start_date = "2026-07-01", end_date = "2026-09-30", final_xp = 3, final_level = 1, xp_transactions = { b = {} } } },
		}),
	}, path)
	store.reload()
	T.eq(store.current_season().name, "Q")
	T.eq(store.season_history()[1].name, "P")
	T.eq(store.season_history()[1].xp_transactions, nil)
	T.eq(store.seen().season_level, 3)
	store.save()
	local raw = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	T.eq(raw.version, 2)
	T.eq(raw.area_xp, nil)
	store.reset_season()
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
	T.eq(s.version, 1)
	T.eq(s.season.name, "Pub")
	T.eq(#s.daily, 14)
	T.eq(s.areas[1].key, AREA41)
	T.ok(s.areas[1].progress >= 0 and s.areas[1].progress <= 1)
	T.eq(math.floor(s.season.xp_to_next), s.season.xp_to_next)
	T.ok(publish.publish(), "first publish writes")
	local path = require("zortex.core.state").path("xp_summary")
	local written = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	T.eq(written.season.name, "Pub")
	T.ok(written.generated:match("^%d%d%d%d%-%d%d%-%d%dT"), written.generated)
	T.eq(publish.publish(), false) -- unchanged: nothing written
	store.reset_season()
	T.ok(publish.publish(), "season ended: changed")
	T.eq(vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).season, nil)
end)
