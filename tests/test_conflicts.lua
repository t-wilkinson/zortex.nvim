-- features/conflicts: a sync tool's conflict copy merged in a diff
local T = require("helpers")
local C = require("zortex.features.conflicts")
local Config = require("zortex.config")

T.test("conflicts: the copy's note, its device and time", function()
	local note, info = C.original("/n/z/garden.sync-conflict-20261024-101530-ABCDEFG.zortex")
	T.eq(note, "/n/z/garden.zortex")
	T.eq(info, { device = "ABCDEFG", time = "2026-10-24 10:15" })
	T.eq((C.original("/n/projects (Sam's conflicted copy 2026-10-24).zortex")), "/n/projects.zortex")
end)

T.test("conflicts: listed, opened in a diff beside the note, done deletes the copy", function()
	local dir = Config.notes_dir
	local note = dir .. "conflict-demo.zortex"
	local copy = dir .. "conflict-demo.sync-conflict-20261024-101530-ABCDEFG.zortex"
	vim.fn.writefile({ "@@Demo", "", "- one", "- two" }, note)
	vim.fn.writefile({ "@@Demo", "", "- one", "- two", "- three (from the phone)" }, copy)
	local ok, err = pcall(function()
		local list = C.list()
		local mine = vim.tbl_filter(function(c)
			return c.copy == copy
		end, list)
		T.eq(#mine, 1)
		T.eq(mine[1].original, note)
		local note_win, copy_win = C.open(mine[1])
		T.ok(vim.wo[note_win].diff and vim.wo[copy_win].diff, "both in diff mode")
		T.eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(note_win)), note)
		-- take the copy's line into the note, then finish
		vim.api.nvim_set_current_win(copy_win)
		vim.cmd("5")
		vim.cmd("diffput")
		vim.api.nvim_set_current_win(note_win)
		T.ok(C.done({ force = true }))
		T.eq(vim.fn.readfile(note), { "@@Demo", "", "- one", "- two", "- three (from the phone)" })
		T.eq(vim.fn.filereadable(copy), 0, "the copy is gone")
	end)
	vim.cmd("silent! tabonly")
	vim.cmd("silent! %bwipeout!")
	vim.fn.delete(note)
	vim.fn.delete(copy)
	assert(ok, err)
end)
