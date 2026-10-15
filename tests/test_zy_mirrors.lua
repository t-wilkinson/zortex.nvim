-- Task copies (services/mirrors): a project task on the calendar with the
-- same @id is one task: its state, its XP and its time.
local T = require("helpers")
local Config = require("zortex.config")

Config.xp = vim.deepcopy(Config.defaults.xp)
require("zortex.services.xp.calculator").setup(Config.xp)
require("zortex.stores.xp").setup(Config.xp)

local fs = require("zortex.utils.filesystem")
local Document = require("zortex.core.document")
local mirrors = require("zortex.services.mirrors")
local ledger = require("zortex.services.xp.ledger")
local projects = require("zortex.services.projects")
local tasks = require("zortex.services.tasks")

local CAL = fs.get_calendar_file()
local PROJ = fs.get_projects_file()
local ZORTEX = "Projects/1 Programming/1.4 - zortex"

local function snapshot(paths)
	local saved = {}
	for _, p in ipairs(paths) do
		saved[p] = fs.read_lines(p)
	end
	return function()
		for p, lines in pairs(saved) do
			local b = vim.fn.bufnr(p)
			if b > 0 then
				vim.cmd("bwipeout! " .. b)
			end
			fs.write_lines(p, lines)
			Document.invalidate(p)
		end
		ledger.invalidate()
	end
end

local function set(path, fn)
	local lines = fs.read_lines(path)
	fn(lines)
	fs.write_lines(path, lines)
	Document.invalidate(path)
	ledger.invalidate()
end

local function find(lines, text)
	for i, l in ipairs(lines) do
		if l:find(text, 1, true) then
			return i, l
		end
	end
end

-- "- [ ] Improve website @p1 @size(xl)" gets @id(web01); the calendar a copy
local function with_copy(copy_line)
	set(PROJ, function(lines)
		local i = find(lines, "Improve website")
		lines[i] = lines[i] .. " @id(web01)"
	end)
	set(CAL, function(lines)
		vim.list_extend(lines, { "", "2026-10-14:", copy_line })
	end)
end

local function improve_website()
	for _, t in ipairs(projects.get(ZORTEX):tasks()) do
		if t.text:find("Improve website", 1, true) then
			return t
		end
	end
end

T.test("a checked calendar copy completes its project task, which pays the XP once", function()
	local restore = snapshot({ CAL, PROJ })
	with_copy("- [x] [P/#1 Programming/#1.4 - zortex/-Improve website] @id(web01) @done(2026-10-14) @spent(25m)")
	local t = improve_website()
	T.ok(t.completed and t.done_on_calendar, "completed through the calendar")
	T.eq(ledger.date_string(t.attributes.done), "2026-10-14")
	T.eq(t.spent_total, 25)
	T.eq(projects.get(ZORTEX):stats().done, 3) -- the fixture has 2 done

	local awards = {}
	for _, e in ipairs(ledger.get({ force = true }).entries) do
		if e.title and e.title:find("Improve website", 1, true) then
			awards[#awards + 1] = e
		end
	end
	T.eq(#awards, 1, "paid once")
	T.eq(awards[1].source, "project_task")
	T.eq(awards[1].project, ZORTEX)
	T.eq(awards[1].date, "2026-10-14")
	T.ok(awards[1].areas["Areas/4 Learning & Education/4.1 Education & Skills"], "the project's area")
	restore()
	T.ok(not improve_website().completed, "unchecked again once the copy is gone")
end)

T.test("toggling a copy toggles its project task, and back", function()
	local restore = snapshot({ CAL, PROJ })
	with_copy("- [ ] [P/#1 Programming/#1.4 - zortex/-Improve website] @id(web01)")
	vim.cmd("edit " .. vim.fn.fnameescape(CAL))
	local row = find(vim.api.nvim_buf_get_lines(0, 0, -1, false), "@id(web01)")
	vim.api.nvim_win_set_cursor(0, { row, 0 })
	tasks.toggle_current_task()
	local today = os.date("%Y-%m-%d")
	local _, proj = find(fs.read_lines(PROJ), "Improve website")
	T.eq(proj, "- [x] Improve website @p1 @size(xl) @id(web01) @done(" .. today .. ")")
	tasks.toggle_current_task()
	_, proj = find(fs.read_lines(PROJ), "Improve website")
	T.eq(proj, "- [ ] Improve website @p1 @size(xl) @id(web01)")
	restore()
end)

T.test("toggling the project task ticks open copies; moved [>] ones stay", function()
	local restore = snapshot({ CAL, PROJ })
	with_copy("- [ ] [P/#1.4 - zortex/-Improve website] @id(web01)")
	set(CAL, function(lines)
		vim.list_extend(lines, { "", "2026-10-13:", "- [>] [P/#1.4 - zortex/-Improve website] @id(web01)" })
	end)
	vim.cmd("edit " .. vim.fn.fnameescape(PROJ))
	local row = find(vim.api.nvim_buf_get_lines(0, 0, -1, false), "@id(web01)")
	vim.api.nvim_win_set_cursor(0, { row, 0 })
	tasks.toggle_current_task()
	local cal = fs.read_lines(CAL)
	T.ok(select(2, find(cal, "- [x] [P/#1.4 - zortex/-Improve website] @id(web01) @done(")), "copy ticked")
	T.ok(find(cal, "- [>] [P/#1.4 - zortex/-Improve website] @id(web01)"), "moved copy untouched")
	restore()
end)

T.test("a calendar line without a checkbox stands for the task it links", function()
	local restore = snapshot({ CAL, PROJ })
	set(CAL, function(lines)
		vim.list_extend(lines, { "", "2026-10-14:", "09:00 [P/#1.4 - zortex]", "  - [./-Improve website]" })
	end)
	local agenda = require("zortex.services.agenda")
	local function ref_item()
		for _, item in ipairs(agenda.day("2026-10-14")) do
			if item.ref then
				return item
			end
		end
	end
	T.ok(ref_item() and not ref_item().done, "a reference, open")
	vim.cmd("edit " .. vim.fn.fnameescape(CAL))
	local row = find(vim.api.nvim_buf_get_lines(0, 0, -1, false), "[./-Improve website]")
	vim.api.nvim_win_set_cursor(0, { row, 0 })
	tasks.toggle_current_task()
	T.eq(vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1], "  - [./-Improve website]", "the reference is unchanged")
	local _, proj = find(fs.read_lines(PROJ), "Improve website")
	T.ok(proj:find("^%- %[x%] Improve website @p1 @size%(xl%) @id%(%w+%) @done%("), proj)
	vim.cmd("bwipeout!")
	T.ok(ref_item().done, "shows the task's state")
	restore()
end)

T.test("ids that don't line up are reported", function()
	local restore = snapshot({ CAL, PROJ })
	with_copy("- [ ] [P/#1.4 - zortex/-Change task sizes] @id(web01)")
	set(PROJ, function(lines)
		local i = find(lines, "Fix project search")
		lines[i] = lines[i] .. " @id(web01)"
	end)
	local problems = vim.tbl_map(function(x)
		return vim.fn.fnamemodify(x.file, ":t") .. ": " .. x.problem
	end, mirrors.issues())
	T.eq(#problems, 2, vim.inspect(problems))
	T.ok(problems[1]:find("calendar.zortex: @id(web01) is projects.zortex:16 but the link points at projects.zortex:17", 1, true), problems[1])
	T.ok(problems[2]:find("projects.zortex: @id(web01) is also on projects.zortex:16", 1, true), problems[2])
	restore()
	-- a copy under a project block with a ./ link lines up
	restore = snapshot({ CAL, PROJ })
	with_copy("09:00 [P/#1.4 - zortex]")
	set(CAL, function(lines)
		lines[#lines + 1] = "  - [ ] [./-Improve website] @id(web01)"
	end)
	T.eq(mirrors.issues(), {})
	restore()
end)

T.test("time spent adds up over the copies of a task", function()
	local dir = Config.notes_dir .. ".z/"
	vim.fn.mkdir(dir, "p")
	local path = dir .. "time_spent.json"
	local old = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
	vim.fn.writefile({
		vim.json.encode({
			version = 1,
			days = {
				["2026-10-13"] = { { rel = "calendar.zortex", lnum = 20, id = "web01", text = "Improve website", key = "calendar.zortex#web01", minutes = 30 } },
				["2026-10-14"] = { { rel = "projects.zortex", lnum = 16, id = "web01", text = "Improve website", key = "projects.zortex#web01", minutes = 45 } },
			},
		}),
	}, path)
	local r = require("zortex.services.time_spent").between("2026-10-13", "2026-10-14")
	T.eq(#r.tasks, 1)
	T.eq(r.tasks[1].minutes, 75)
	if old then
		vim.fn.writefile(old, path)
	else
		os.remove(path)
	end
end)
