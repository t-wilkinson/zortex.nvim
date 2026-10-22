-- Tasks nested under a task (services/task_groups): the group's @size is
-- shared by its tasks, progress and XP count the leaves, and checking
-- cascades.
local T = require("helpers")
local Groups = require("zortex.services.task_groups")
local Document = require("zortex.core.document")
local Config = require("zortex.config")

local function annotated(lines)
	local doc = Document.from_lines(lines)
	local tasks = doc:items(1, #lines, { tasks = true })
	Groups.annotate(tasks, require("zortex.services.projects.project").group_opts(doc))
	local by = {}
	for _, t in ipairs(tasks) do
		by[t.text] = t
	end
	return by, tasks
end

local AUDIT = {
	"- [ ] Security audit @id(DxqoT) @md",
	"    - [./z/generated/nixos-config-security-audit.md]",
	"    - [ ] Cloudflare tunnel @id(HQUY1)",
	"    - [x] Cloudflare cert @done(2026-10-11)",
	"    - [ ] Google app password",
	"    - [ ] Wi-Fi password",
	"    - [ ] Nextcloud admin password",
	"    - [ ] Raspbery pi SSH host key",
}

T.test("a group's @size is shared by its tasks; the group adds nothing of its own", function()
	local by, tasks = annotated(AUDIT)
	local audit = by["Security audit"]
	T.eq(audit.leaf, false)
	T.eq(audit.hours, 1)
	T.eq(#audit.children_tasks, 6) -- the link line isn't a task
	for _, t in ipairs(audit.children_tasks) do
		T.ok(math.abs(t.hours - 1 / 6) < 1e-9, t.text .. " " .. t.hours)
		T.eq(t.parent_task, audit)
	end
	T.eq(#Groups.leaves(tasks), 6)
	T.eq(audit.open_leaves, 5)
	T.ok(math.abs(audit.open_hours - 5 / 6) < 1e-9)
end)

T.test("sized tasks share in proportion (the group's size wins); unsized groups add up", function()
	local by = annotated({
		"- [ ] Move @lg", -- 2h
		"  - [ ] Pack @xl", -- 3h
		"  - [ ] Clean @md", -- 1h
		"  Notes:", -- a label between doesn't break the nesting
		"    - [ ] Keys", -- md: 1h
		"- [ ] Garden", -- no size: its tasks add up
		"  - [ ] Weed @sm",
		"  - [ ] Plant", -- no size, a group: its task's 15 min
		"    - [ ] Buy seeds @xs",
		"## Next",
		"  - [ ] Not nested", -- a heading ends the nesting
	})
	T.ok(math.abs(by["Pack"].hours - 2 * 3 / 5) < 1e-9, by["Pack"].hours)
	T.ok(math.abs(by["Clean"].hours - 2 * 1 / 5) < 1e-9)
	T.ok(math.abs(by["Keys"].hours - 2 * 1 / 5) < 1e-9)
	T.eq(by["Garden"].hours, 0.5 + 0.25)
	T.eq(by["Plant"].leaf, false)
	T.eq(by["Buy seeds"].hours, 0.25)
	T.eq(by["Not nested"].parent_task, nil)
	-- priority and importance come down from the group
	by = annotated({ "- [ ] Big @p1 @md", "  - [ ] Small", "  - [ ] Other @p3" })
	T.eq(by["Small"].xp_attrs.p, "1")
	T.eq(by["Other"].xp_attrs.p, "3")
end)

T.test("a checked group's tasks count as done, dated by the group", function()
	local by = annotated({
		"- [x] Trip @done(2026-10-01) @md",
		"  - [ ] Book",
		"  - [x] Pack @done(2026-09-30)",
	})
	T.eq(by["Book"].done_effective, true)
	T.eq(by["Book"].done_date, by["Trip"].attributes.done) -- 2026-10-01
	T.eq(by["Pack"].done_date, by["Pack"].attributes.done)
	T.eq(by["Trip"].open_leaves, 0)
end)

-- =============================================================================
-- Projects, XP, the planner
-- =============================================================================

local function with_project(lines, fn)
	local path = Config.notes_dir .. "groups-test.zortex"
	vim.fn.writefile(vim.list_extend({ "@@Groups test", "@P", "" }, lines), path)
	Document.invalidate()
	local notes = require("zortex.core.notes")
	notes.index({ fresh = true })
	notes.index({ include_archived = true, fresh = true })
	local ok, err = xpcall(fn, debug.traceback, path)
	vim.fn.delete(path)
	Document.invalidate()
	assert(ok, err)
end

T.test("project progress and XP count the leaves at their share", function()
	with_project(vim.list_extend({ "# Homelab" }, AUDIT), function(path)
		local p = require("zortex.services.projects").get("Groups test/Homelab")
		T.ok(p, "the project")
		local r = p:rollup()
		T.eq({ r.total, r.done, r.open }, { 6, 1, 5 })
		T.ok(math.abs(r.points - 1) < 1e-9, r.points) -- the audit is 1h, not 7
		local calc = require("zortex.services.xp.calculator")
		T.ok(math.abs(calc.calculate_project_total_xp(p, p:leaf_tasks()) - calc.xp_per_hour()) < 1e-6)
		local L = require("zortex.services.xp.ledger")
		L.invalidate()
		local paid = 0
		for _, e in ipairs(L.get().entries) do
			if e.project == p.key then
				paid = paid + 1
				T.eq(e.title, "Cloudflare cert")
			end
		end
		T.eq(paid, 1)
	end)
end)

T.test("the planner offers the group, not its tasks", function()
	local audit = vim.deepcopy(AUDIT)
	audit[1] = audit[1] .. " @p1"
	audit[3] = audit[3] .. " @p1" -- a task in the group, however important, isn't offered alone
	with_project(vim.list_extend({ "# Homelab" }, audit), function()
		local c = require("zortex.services.planner").candidates({ today = "2026-10-16" })
		local texts = {}
		for _, t in ipairs(c.tasks) do
			if t.project_name == "Homelab" then
				texts[#texts + 1] = t.title
				if t.text:find("Security audit", 1, true) then
					T.ok(vim.tbl_contains(t.badges, "5 of 6 tasks open"), vim.inspect(t.badges))
				end
			end
		end
		T.eq(texts, { "Security audit" })
	end)
end)

-- =============================================================================
-- Checking cascades
-- =============================================================================

T.test("checking a group checks its tasks; the last task checks the group; reopening reopens above", function()
	local tasks = require("zortex.services.tasks")
	local today = os.date("%Y-%m-%d")
	vim.cmd("enew!")
	local path = Config.notes_dir .. "groups-cascade.zortex"
	vim.fn.writefile({ "@@Cascade", "", "- [ ] Audit @md", "  - [ ] One", "  - [x] Two @done(2026-10-01)", "  - [ ] Three" }, path)
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local buf = vim.api.nvim_get_current_buf()
	local function lines()
		return vim.api.nvim_buf_get_lines(buf, 2, 6, false)
	end
	local function strip(l)
		return (l:gsub(" @id%(%w+%)", ""))
	end
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	tasks.toggle_current_task()
	T.eq(vim.tbl_map(strip, lines()), {
		"- [x] Audit @md @done(" .. today .. ")",
		"  - [x] One @done(" .. today .. ")",
		"  - [x] Two @done(2026-10-01)", -- already done: kept
		"  - [x] Three @done(" .. today .. ")",
	})
	-- reopening a task reopens the group above it
	vim.api.nvim_win_set_cursor(0, { 4, 0 })
	tasks.toggle_current_task()
	T.eq(vim.tbl_map(strip, lines())[1], "- [ ] Audit @md")
	T.eq(vim.tbl_map(strip, lines())[2], "  - [ ] One")
	-- checking it again, the last open one, checks the group
	tasks.toggle_current_task()
	T.eq(vim.tbl_map(strip, lines())[1], "- [x] Audit @md @done(" .. today .. ")")
	-- reopening the group leaves its tasks as they are
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	tasks.toggle_current_task()
	T.eq(vim.tbl_map(strip, lines()), {
		"- [ ] Audit @md",
		"  - [x] One @done(" .. today .. ")",
		"  - [x] Two @done(2026-10-01)",
		"  - [x] Three @done(" .. today .. ")",
	})
	vim.cmd("silent! bwipeout! " .. buf)
	vim.fn.delete(path)
end)

T.test("checking a group's copy on the calendar checks its tasks in the project", function()
	local fs = require("zortex.utils.filesystem")
	local cal, proj = fs.get_calendar_file(), fs.get_projects_file()
	local cal0, proj0 = vim.fn.readfile(cal), vim.fn.readfile(proj)
	local p = vim.deepcopy(proj0)
	vim.list_extend(p, { "", "# Groups", "- [ ] Audit @id(grp01) @md", "  - [ ] One", "  - [ ] Two" })
	vim.fn.writefile(p, proj)
	local c = vim.deepcopy(cal0)
	vim.list_extend(c, { "", "2026-11-20:", "- [ ] [P/#Groups/-Audit] @id(grp01)" })
	vim.fn.writefile(c, cal)
	Document.invalidate()
	local ok, err = pcall(function()
		vim.cmd("edit! " .. vim.fn.fnameescape(cal))
		vim.api.nvim_win_set_cursor(0, { #c, 0 })
		require("zortex.services.tasks").toggle_current_task()
		local after = vim.fn.readfile(proj) -- not loaded: written to the file
		local n = #after
		T.ok(after[n - 2]:match("^%- %[x%] Audit"), after[n - 2])
		T.ok(after[n - 1]:match("^  %- %[x%] One @done"), after[n - 1])
		T.ok(after[n]:match("^  %- %[x%] Two @done"), after[n])
		-- the copy doesn't pay: the project pays through the group's tasks
		vim.cmd("silent write")
		require("zortex.core.notes").index({ include_archived = true, fresh = true })
		local L = require("zortex.services.xp.ledger")
		L.invalidate()
		local titles = {}
		for _, e in ipairs(L.get().entries) do
			if e.title == "Audit" or e.title == "One" or e.title == "Two" then
				titles[#titles + 1] = e.source .. " " .. e.title
			end
		end
		table.sort(titles)
		T.eq(titles, { "project_task One", "project_task Two" })
	end)
	vim.cmd("silent! %bwipeout!")
	vim.fn.writefile(cal0, cal)
	vim.fn.writefile(proj0, proj)
	Document.invalidate()
	assert(ok, err)
end)

T.test("outside projects: a checked task in a group pays its share", function()
	local path = Config.notes_dir .. "groups-note.zortex"
	vim.fn.writefile({ "@@Chores", "", "- [ ] Spring clean @lg", "  - [x] Windows @done(2026-10-10)", "  - [ ] Garage" }, path)
	Document.invalidate()
	require("zortex.core.notes").index({ include_archived = true, fresh = true })
	local L = require("zortex.services.xp.ledger")
	L.invalidate()
	local calc = require("zortex.services.xp.calculator")
	local found
	for _, e in ipairs(L.get().entries) do
		if e.file and e.file:find("groups%-note") then
			found = e
		end
	end
	vim.fn.delete(path)
	Document.invalidate()
	L.invalidate()
	T.ok(found and found.title == "Windows", vim.inspect(found))
	T.ok(math.abs(found.xp - 1 * calc.xp_per_hour()) < 1e-6, found.xp) -- half of lg (2h)
end)
