-- Area XP and season XP apart: the default area for work without one, and
-- giving finished work an area (services/areas/assign, the daily review).
local T = require("helpers")
local Config = require("zortex.config")

Config.xp = vim.deepcopy(Config.defaults.xp)
require("zortex.services.xp.calculator").setup(Config.xp)
require("zortex.stores.xp").setup(Config.xp)

local ledger = require("zortex.services.xp.ledger")
local assign = require("zortex.services.areas.assign")
local A = require("zortex.services.areas")
local fs = require("zortex.utils.filesystem")
local Document = require("zortex.core.document")

local DEFAULT = "Areas/0 General/0.1 Unassigned"
local AREA41 = "Areas/4 Learning & Education/4.1 Education & Skills"

local function refresh()
	Document.invalidate()
	require("zortex.core.notes").invalidate()
	ledger.invalidate()
end

-- Run fn with notes changed (path -> function(lines)), restoring them after
local function with_notes(changes, fn)
	local saved = {}
	for path, change in pairs(changes) do
		saved[path] = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or false
		local lines = vim.deepcopy(saved[path] or {})
		change(lines)
		if saved[path] then
			vim.fn.writefile(lines, path)
		end
	end
	refresh()
	local ok, err = xpcall(fn, debug.traceback)
	for path, lines in pairs(saved) do
		if lines then
			vim.fn.writefile(lines, path)
		else
			vim.fn.delete(path)
		end
		local b = vim.fn.bufnr(path)
		if b > 0 then
			vim.cmd("silent! bwipeout! " .. b)
		end
	end
	refresh()
	assert(ok, err)
end

local function default_area(lines)
	table.insert(lines, 4, "# 0 General")
	table.insert(lines, 5, "## 0.1 Unassigned")
end

local function entry(title)
	for _, e in ipairs(ledger.get().entries) do
		if e.title == title then
			return e
		end
	end
end

T.test("work without an area: unassigned; with no 0.1 area, no area XP", function()
	refresh()
	T.eq(A.default_area(), nil)
	local e = entry("Order parts") -- a calendar task, no @a
	T.ok(e, "Order parts")
	T.eq(e.unassigned, true)
	T.eq(e.aligned, nil)
	T.eq(e.areas, {})
	T.eq(e.season, 0) -- no key result: no season XP
end)

T.test("work without an area earns for the default area (xp.default_area)", function()
	with_notes({ [fs.get_areas_file()] = default_area }, function()
		T.eq(A.default_area().key, DEFAULT)
		T.eq(A.value(A.default_area()), "0.1")
		local e = entry("Order parts")
		T.eq(e.unassigned, true)
		T.eq(e.aligned, nil, "the default area is not an area someone chose")
		T.ok(math.abs(e.areas[DEFAULT] - e.xp) < 1e-9, vim.inspect(e.areas))
		-- a task on a key result whose objective names no area that resolves:
		-- season XP, and its area XP to the default area
		local habits = entry("Evening routine")
		T.eq(habits.aligned, "kr")
		T.eq(habits.unassigned, true)
		T.ok(habits.season > 0 and math.abs(habits.season - habits.xp) < 1e-9)
		-- the reviews don't ask for objectives or projects there
		local agenda = require("zortex.services.agenda")
		T.ok(agenda.default_only(A.get(DEFAULT)))
		T.ok(agenda.default_only(A.get("Areas/0 General")))
		T.ok(not agenda.default_only(A.get(AREA41)))
		-- a project with only the default area is still "neither" to the planner
		T.eq(#A.chosen({ A.default_area(), A.get(AREA41) }), 1)
	end)
end)

T.test("xp.default_area = false: no area XP for work without one", function()
	Config.xp.default_area = false
	local ok, err = pcall(function()
		with_notes({ [fs.get_areas_file()] = default_area }, function()
			T.eq(A.default_area(), nil)
			T.eq(entry("Order parts").areas, {})
		end)
	end)
	Config.xp.default_area = "0.1"
	ledger.invalidate()
	assert(ok, err)
end)

T.test("unassigned(): a project's tasks together, loose tasks one by one", function()
	refresh()
	local items = assign.unassigned("2026-10-01", "2026-10-31")
	local by = {}
	for _, it in ipairs(items) do
		by[it.title] = it
	end
	T.eq(by["Order parts"].kind, "task")
	T.eq(by["Habits"].kind, "project")
	T.eq(by["Habits"].count, 1)
	T.ok(by["Habits"].kr, "on a key result")
	T.ok(not by["Highlight OKR ids"], "1.4 - zortex has @a(4.1)")
end)

T.test("set(): @a on the project's heading or the task; stamp(): the default on the rest", function()
	with_notes({
		[fs.get_areas_file()] = default_area,
		[fs.get_projects_file()] = function() end,
		[fs.get_calendar_file()] = function() end,
	}, function()
		local items = assign.unassigned("2026-10-01", "2026-10-31")
		local habits, order
		for _, it in ipairs(items) do
			if it.title == "Habits" then
				habits = it
			elseif it.title == "Order parts" then
				order = it
			end
		end
		T.ok(assign.set(habits, "4.1"))
		local plines = vim.fn.readfile(fs.get_projects_file())
		T.eq(plines[habits.lnum], "## Habits @a(4.1)")
		refresh()
		local e = entry("Evening routine")
		T.eq(e.unassigned, nil)
		T.ok(e.areas[AREA41] and e.areas[AREA41] > 0, vim.inspect(e.areas))
		-- the rest: the calendar task gets the default area written
		T.eq(assign.stamp({ order }), 1)
		local cal = vim.fn.readfile(fs.get_calendar_file())
		T.eq(cal[order.lnum], "- [x] Order parts @done(2026-10-06) @a(0.1)")
		refresh()
		e = entry("Order parts")
		T.eq(e.unassigned, nil)
		T.ok(e.areas[DEFAULT] ~= nil)
		T.eq(#assign.unassigned("2026-10-01", "2026-10-31"), 0)
		-- an @a that names nothing is replaced, not added to
		T.eq(assign._with_area("- [x] X @area(9.9) @done(2026-10-06)", "4.1"), "- [x] X @done(2026-10-06) @a(4.1)")
	end)
end)

T.test("stamp() writes nothing while @a(0.1) names no area", function()
	refresh()
	local items = assign.unassigned("2026-10-01", "2026-10-31")
	T.ok(#items > 0)
	local n, err = assign.stamp(items)
	T.eq(n, nil)
	T.ok(err:find("areas.zortex", 1, true), err)
end)

T.test("the daily review lists work without an area; A gives it one; closing stamps the rest", function()
	with_notes({
		[fs.get_areas_file()] = default_area,
		[fs.get_projects_file()] = function() end,
		[fs.get_calendar_file()] = function(lines)
			vim.list_extend(lines, { "", "2026-10-08:", "- [x] Water the plants @done(2026-10-08)" })
		end,
		[fs.get_reviews_file()] = function() end,
	}, function()
		local ui = require("zortex.ui.review")
		local buf = ui.open({ scope = "day", today = "2026-10-08", note = false })
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = table.concat(lines, "\n")
		T.ok(text:find("Done without an area", 1, true), text)
		T.ok(text:find("the rest get @a(0.1) when you close this", 1, true), text)
		-- A on the Habits line: pick 4.1
		local row
		for i, l in ipairs(lines) do
			if l:find("Habits", 1, true) and l:find("task", 1, true) then
				row = i
			end
		end
		T.ok(row, text)
		vim.api.nvim_win_set_cursor(0, { row, 0 })
		local select = vim.ui.select
		vim.ui.select = function(list, _, cb)
			for _, a in ipairs(list) do
				if a.key == AREA41 then
					return cb(a)
				end
			end
		end
		ui.assign_area()
		vim.ui.select = select
		local plines = vim.fn.readfile(fs.get_projects_file())
		T.ok(vim.iter(plines):any(function(l)
			return l == "## Habits @a(4.1)"
		end), table.concat(plines, "\n"))
		-- closing: what is still without an area gets @a(0.1)
		ui.close()
		local cal = vim.fn.readfile(fs.get_calendar_file())
		T.eq(cal[#cal], "- [x] Water the plants @done(2026-10-08) @a(0.1)")
	end)
end)
