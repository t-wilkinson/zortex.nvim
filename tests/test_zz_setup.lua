-- Runs last: full plugin setup touches global state (autocmds, commands).
local T = require("helpers")

T.test("require('zortex').setup() succeeds with user overrides", function()
	local notes_dir = require("zortex.config").notes_dir
	local ok, err = pcall(require("zortex").setup, { notes_dir = notes_dir, ui = { search = { max_results = 9 } } })
	T.ok(ok, tostring(err))
	T.eq(require("zortex.services.search").config.max_results, 9)
	T.eq(require("zortex.services.search").config.default_mode, "section")
end)

T.test("a notes_dir reached through a symlink is resolved, so its buffers are recognized", function()
	local Config = require("zortex.config")
	local saved = Config.notes_dir
	local base = vim.fn.tempname()
	vim.fn.mkdir(base .. "/real", "p")
	vim.fn.system({ "ln", "-s", base .. "/real", base .. "/link" })
	local real = vim.uv.fs_realpath(base .. "/real") .. "/"
	vim.fn.writefile({ "@@Flipping", "@P", "", "# 2012 Subaru Outback", "- [ ] Install pistons @size(md)" }, real .. "flipping.zortex")
	vim.fn.writefile({ "@@Calendar", "", "2026-10-15:", "16:00 [P/Flipping/#2012 Subaru Outback]", "    - [./-Install pistons]" }, real .. "calendar.zortex")
	require("zortex").setup({ notes_dir = base .. "/link" })
	T.eq(Config.notes_dir, real)
	require("zortex.core.link_index").refresh(true)
	vim.cmd("edit " .. vim.fn.fnameescape(base .. "/link/calendar.zortex"))
	vim.api.nvim_win_set_cursor(0, { 5, 6 })
	require("zortex.services.tasks").toggle_current_task()
	T.eq(vim.api.nvim_get_current_line(), "    - [./-Install pistons]", "a reference: the line is unchanged")
	T.ok(vim.fn.readfile(real .. "flipping.zortex")[5]:find("^%- %[x%] Install pistons"), "the task is done")
	vim.cmd("bwipeout!")
	require("zortex").setup({ notes_dir = saved })
	require("zortex.core.link_index").refresh(true)
end)

T.test("calendar opens and every day can be selected", function()
	local view = require("zortex.ui.calendar.view")
	local ok, err = pcall(view.open)
	T.ok(ok, tostring(err))
	-- Walk the selection across ~two months with the "next day" key, so every
	-- cell is selected, including the ones with wide icons.
	local moved_ok, moved_err = pcall(function()
		for _ = 1, 62 do
			vim.cmd("normal l")
		end
		vim.cmd("normal t") -- back to today
	end)
	T.ok(moved_ok, tostring(moved_err))
	pcall(view.close)
end)

-- a day with an appointment after 2026-10-08, for the Coming up lists
local function with_event(fn)
	local fs = require("zortex.utils.filesystem")
	local cal = fs.get_calendar_file()
	local original = fs.read_lines(cal)
	fs.write_lines(cal, vim.list_extend(vim.deepcopy(original), { "", "2026-10-11:", "14:00 - 15:00 Dentist" }))
	require("zortex.core.document").invalidate(cal)
	require("zortex.core.link_index").refresh(true)
	local ok, err = pcall(fn)
	fs.write_lines(cal, original)
	require("zortex.core.document").invalidate(cal)
	require("zortex.core.link_index").refresh(true)
	assert(ok, err)
end

T.test("the calendar view lists the events coming up after the selected day", function()
	with_event(function()
		local view = require("zortex.ui.calendar.view")
		local datetime = require("zortex.utils.datetime")
		view.open()
		view.state.current_date = datetime.parse_date("2026-10-08")
		view.refresh()
		local text = table.concat(vim.api.nvim_buf_get_lines(view.state.bufnr, 0, -1, false), "\n")
		pcall(view.close)
		T.ok(text:find("Coming up %(next 7 days%)"), text)
		T.ok(text:find("Sun Oct 11", 1, true) and text:find("Dentist", 1, true), text)
	end)
end)

T.test("the planner lists the events coming up after the day", function()
	with_event(function()
		local lines = require("zortex.ui.planner").render({
			upcoming = require("zortex.services.agenda").upcoming_events({ date = "2026-10-08" }),
		}, "2026-10-08")
		local i = vim.fn.index(lines, "# Coming up (next 7 days)")
		T.ok(i >= 0, vim.inspect(lines))
		T.eq(lines[i + 2], "Sun 10-11  14:00–15:00 Dentist")
	end)
end)

T.test("calendar / picks an entry and jumps to its line", function()
	local view = require("zortex.ui.calendar.view")
	local cal = require("zortex.utils.filesystem").get_calendar_file()
	local Config = require("zortex.config")
	local picker = Config.ui.picker
	Config.ui.picker = "select"
	view.open()
	local orig, offered = vim.ui.select, nil
	vim.ui.select = function(items, opts, on_choice)
		offered = vim.tbl_map(opts.format_item, items)
		for _, item in ipairs(items) do
			if item.entry.lnum then
				return on_choice(item)
			end
		end
	end
	local ok, err = pcall(vim.cmd, "normal /")
	vim.ui.select = orig
	Config.ui.picker = picker
	T.ok(ok, tostring(err))
	T.ok(offered and #offered > 0, "no entries offered")
	T.ok(offered[1]:match("^%d%d%d%d%-%d%d%-%d%d  "), offered[1])
	T.eq(vim.api.nvim_buf_get_name(0), vim.fn.fnamemodify(cal, ":p"))
	T.ok(vim.api.nvim_get_current_line():match("%S"))
end)

T.test("a project block lists the project's next tasks in the calendar view, and x ticks them", function()
	local mirrors = require("zortex.services.mirrors")
	local workspace = require("zortex.core.workspace")
	local cal = require("zortex.utils.filesystem").get_calendar_file()
	local doc = workspace.document(cal)
	local lnum
	for l, line in ipairs(doc.lines) do
		if line == "14:00 [P/#1.4 - zortex]" then
			lnum = l
		end
	end
	T.ok(lnum, "fixture block")
	local p, tasks = mirrors.project_block(doc.lines, lnum, doc)
	T.ok(p and p.name == "1.4 - zortex", p and p.name)
	T.eq(vim.tbl_map(function(t)
		return t.text
	end, tasks), { "Add research-ready references", "Improve website", "Change task sizes" })
	-- a line with words besides the link, or with lines under it, is no block
	T.eq(mirrors.project_block({ "15:00 Reflect on [P/#1 Programming]" }, 1, doc), nil)
	T.eq(mirrors.project_block({ "14:00 [P/#1.4 - zortex]", "  - [ ] a task" }, 1, doc), nil)

	local view = require("zortex.ui.calendar.view")
	view.open()
	local keys = require("zortex.ui.calendar.keys")
	keys.move_to_date({ year = 2026, month = 10, day = 9 })
	local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
	T.ok(text:find("Improve website", 1, true), text)
	-- 2x ticks "Improve website" in the projects note
	local proj = require("zortex.utils.filesystem").get_projects_file()
	vim.cmd("normal 2x")
	local line = workspace.get_lines(proj)[vim.fn.match(workspace.get_lines(proj), "Improve website") + 1]
	T.ok(line:match("^%- %[x%] Improve website"), line)
	vim.cmd("normal 2x") -- the list moved on: task 2 is now the next open one
	pcall(view.close)
	-- reopen what was ticked
	local lines = workspace.get_lines(proj)
	for l, t in ipairs(lines) do
		if t:match("^%- %[x%] Improve website") or t:match("^%- %[x%] Change task sizes") then
			require("zortex.services.tasks").toggle_at(proj, l)
		end
	end
end)
