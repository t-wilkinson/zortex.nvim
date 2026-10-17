local T = require("helpers")
local tasks = require("zortex.services.tasks")
local Events = require("zortex.core.event_bus")

T.test("toggle a task in a standalone @P note, keeping unsaved edits", function()
	vim.cmd("edit! " .. vim.fn.fnameescape(T.fixture("flipping.zortex")))
	local bufnr = vim.api.nvim_get_current_buf()

	-- Unsaved edit elsewhere in the buffer
	vim.api.nvim_buf_set_lines(bufnr, 6, 7, false, { "- lkqonline (edited)" })

	local completed
	Events.on("task:completed", function(data)
		completed = data
	end)

	vim.api.nvim_win_set_cursor(0, { 12, 0 }) -- "- [ ] Pull engine @size(xl)"
	local task, err = tasks.toggle_current_task()
	T.ok(task, err)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	T.eq(lines[7], "- lkqonline (edited)", "unsaved edit kept")
	T.ok(lines[12]:match("^%- %[x%] Pull engine"), lines[12])
	T.ok(lines[12]:match("@done%(%d%d%d%d%-%d%d%-%d%d%)"), "done date added")
	T.ok(lines[12]:match("@id%(%w+%)"), "id added")
	vim.wait(1000, function()
		return completed ~= nil
	end) -- handlers run via vim.schedule
	T.ok(completed and completed.doc_context, "task:completed emitted")

	-- the XP ledger reads the standalone project from the live buffer
	local entries = require("zortex.services.xp.ledger").for_project("Flipping/Subaru outback")
	T.eq(#entries, 2)
	T.eq(entries[#entries].title, "Pull engine")
	T.eq(entries[#entries].date, os.date("%Y-%m-%d"))

	vim.cmd("bwipeout!")
end)

T.test("find_task_by_id searches project sources", function()
	local task, doc, lnum = tasks.find_task_by_id("nope")
	T.eq(task, nil)
end)

T.test("toggling edits the checkbox and @done only, keeping other attributes", function()
	local Item = require("zortex.core.item")
	local line = "  - [ ] Call mom @home @p1 @a(1.2) @id(abc12)"
	local task = Item.task(line)
	task.completed = true
	local done = tasks.build_task_line(task)
	T.eq(done, "  - [x] Call mom @home @p1 @a(1.2) @id(abc12) @done(" .. os.date("%Y-%m-%d") .. ")")
	local undone = Item.task(done)
	undone.completed = false
	T.eq(tasks.build_task_line(undone), line)
end)

T.test("toggling never turns structure into a task", function()
	local tasks = require("zortex.services.tasks")
	for _, line in ipairs({ "# 1 Example project @a(1.1)", "**Next steps:**", "@@Note" }) do
		local result, err = tasks.change_task_completion({ doc = {}, line = line, bufnr = 0, lnum = 1 }, nil)
		T.eq(result, nil, line)
		T.ok(err and err:find("not a task"), tostring(err))
	end
end)

T.test("toggle on a project heading marks the project done; open tasks ask first", function()
	vim.cmd("edit! " .. vim.fn.fnameescape(T.fixture("projects.zortex")))
	local bufnr = vim.api.nvim_get_current_buf()
	local today = os.date("%Y-%m-%d")
	local select, asked = vim.ui.select, nil
	local answer = "Cancel"
	vim.ui.select = function(items, opts, on_choice)
		asked = opts.prompt
		on_choice(answer)
	end
	local ok, err = pcall(function()
		vim.api.nvim_win_set_cursor(0, { 14, 0 }) -- "## 1.4 - zortex @size(lg) @a(4.1)", open tasks
		local p = tasks.toggle_current_task()
		T.ok(p and p.name == "1.4 - zortex", "the project")
		T.ok(asked and asked:find("open task"), asked)
		T.eq(vim.api.nvim_buf_get_lines(bufnr, 13, 14, false)[1], "## 1.4 - zortex @size(lg) @a(4.1)") -- declined
		answer = "Mark it done"
		tasks.toggle_current_task()
		T.eq(vim.api.nvim_buf_get_lines(bufnr, 13, 14, false)[1], "## 1.4 - zortex @size(lg) @a(4.1) @done(" .. today .. ")")
		-- again: reopened, no question
		asked = nil
		tasks.toggle_current_task()
		T.eq(asked, nil)
		T.eq(vim.api.nvim_buf_get_lines(bufnr, 13, 14, false)[1], "## 1.4 - zortex @size(lg) @a(4.1)")
		-- a heading that isn't a project (the note's own title) is still refused
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		local t, e = tasks.toggle_current_task()
		T.ok(t == nil and e, "not a task")
	end)
	vim.ui.select = select
	vim.cmd("silent! bwipeout! " .. bufnr)
	assert(ok, err)
end)

T.test("the only task of a calendar block gets the block's size when ticked", function()
	package.path = vim.fn.getcwd() .. "/tests/?.lua;" .. package.path
	local sizes = require("zortex.config").defaults.xp.sizes.task
	for _, c in ipairs(require("autosize_cases")) do
		T.eq(tasks.calendar_size(c.lines, c.lnum, sizes), c.size, c.name)
	end
	local fixture = vim.json.decode(table.concat(vim.fn.readfile(T.root .. "/tests/fixtures/autosize.json"), "\n"))
	T.eq(#fixture.cases, #require("autosize_cases"), "regenerate with tests/gen_edits.lua")

	-- ticking it in a buffer writes the size
	local path = vim.fn.tempname() .. ".zortex"
	vim.fn.writefile({ "@@Day", "", "2026-10-16:", "16:00 Report", "  - [ ] Task 1 @id(aut01)", "17:00 Next" }, path)
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local bufnr = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(0, { 5, 0 })
	T.ok(tasks.toggle_current_task())
	T.eq(vim.api.nvim_buf_get_lines(bufnr, 4, 5, false)[1], "  - [x] Task 1 @id(aut01) @done(" .. os.date("%Y-%m-%d") .. ") @md")
	-- reopening keeps it (a size written by hand looks the same)
	T.ok(tasks.toggle_current_task())
	T.eq(vim.api.nvim_buf_get_lines(bufnr, 4, 5, false)[1], "  - [ ] Task 1 @id(aut01) @md")
	vim.cmd("bwipeout!")
end)
