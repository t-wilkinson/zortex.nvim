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
