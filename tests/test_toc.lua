-- features/toc: the table of contents follows the note as it changes
local T = require("helpers")
local toc = require("zortex.features.toc")

local function toc_lines(buf)
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

T.test("TOC: rebuilt as the note changes, following the cursor, and the note shown in the window", function()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local a, b = dir .. "/a.zortex", dir .. "/b.zortex"
	vim.fn.writefile({ "@@A", "", "# One", "text", "# Two", "more" }, a)
	vim.fn.writefile({ "@@B", "", "# Bee" }, b)
	vim.cmd("edit " .. a)
	vim.bo.filetype = "zortex"
	local note_win = vim.api.nvim_get_current_win()
	local buf, win = toc.show_toc()
	T.eq(toc_lines(buf), { "[# One]", "[# Two]" })

	-- an edit: rebuilt after a short pause
	vim.api.nvim_set_current_win(note_win)
	vim.api.nvim_buf_set_lines(0, 6, 6, false, { "## Two and a half" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
	T.ok(vim.wait(1000, function()
		return #toc_lines(buf) == 3
	end), vim.inspect(toc_lines(buf)))
	T.eq(toc_lines(buf), { "[# One]", "[# Two]", "  [## Two and a half]" })

	-- the cursor in the note moves the TOC's
	vim.api.nvim_win_set_cursor(note_win, { 4, 0 })
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
	T.eq(vim.api.nvim_win_get_cursor(win)[1], 1)
	vim.api.nvim_win_set_cursor(note_win, { 7, 0 })
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
	T.eq(vim.api.nvim_win_get_cursor(win)[1], 3)

	-- another note in the window: the TOC becomes its
	vim.cmd("edit " .. b)
	vim.bo.filetype = "zortex"
	vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0 })
	T.eq(toc_lines(buf), { "[# Bee]" })

	vim.api.nvim_win_close(win, true)
	vim.cmd("silent! %bwipeout!")
	vim.fn.delete(dir, "rf")
end)
