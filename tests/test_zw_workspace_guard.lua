-- core/workspace: an edit is refused when the note changed around it since
-- it was read (the web app or Syncthing wrote it in between).
local T = require("helpers")
local Config = require("zortex.config")
local Document = require("zortex.core.document")
local workspace = require("zortex.core.workspace")

local function note(name, lines)
	local path = Config.notes_dir .. name
	vim.fn.writefile(lines, path)
	Document.invalidate(path)
	return path
end

T.test("a note that isn't open: a changed line refuses the edit, a change elsewhere doesn't", function()
	local p = note("ws-guard.zortex", { "@@Guard", "", "- [ ] one", "- [ ] two", "- [ ] three" })
	local lines = workspace.get_lines(p) -- read: the snapshot the edit is checked against
	T.eq(lines[4], "- [ ] two")
	-- the web app inserts a line above it
	vim.fn.writefile({ "@@Guard", "", "- [ ] new from the phone", "- [ ] one", "- [ ] two", "- [ ] three" }, p)
	local ok, err = workspace.set_line(p, 4, "- [x] two")
	T.eq(ok, false)
	T.ok(err:find("changed since it was read"), err)
	T.eq(vim.fn.readfile(p)[4], "- [ ] one") -- nothing written

	-- read again, then a change far away doesn't matter
	workspace.get_lines(p)
	local now = vim.fn.readfile(p)
	now[#now + 1] = "- [ ] appended"
	vim.fn.writefile(now, p)
	T.eq(workspace.set_line(p, 5, "- [x] two"), true)
	T.eq(vim.fn.readfile(p)[5], "- [x] two")
end)

T.test("an open, unsaved-free buffer is reloaded first; a shifted line refuses the edit", function()
	local p = note("ws-guard-buf.zortex", { "@@Guard buf", "", "- [ ] a", "- [ ] b" })
	vim.cmd("edit " .. vim.fn.fnameescape(p))
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].autoread = true
	-- changed on disk (a second later, so the mtime moves)
	vim.uv.sleep(1100)
	vim.fn.writefile({ "@@Guard buf", "", "- [ ] inserted", "- [ ] a", "- [ ] b" }, p)
	local ok, err = workspace.set_line(buf, 4, "- [x] b")
	T.eq(ok, false, "line 4 was '- [ ] b' when read")
	T.ok(err and err:find("changed since it was read"), err)
	T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[3], "- [ ] inserted", "the buffer was reloaded")
	vim.cmd("bwipeout! " .. buf)
end)
