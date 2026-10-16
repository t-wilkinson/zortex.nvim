-- services/move and :ZortexMove: a section or a line, with what is nested
-- under it, to a place picked in the structural search.
local T = require("helpers")
local Move = require("zortex.services.move")
local Document = require("zortex.core.document")
local Config = require("zortex.config")

local function note(name, lines)
	local path = Config.notes_dir .. name
	vim.fn.writefile(lines, path)
	Document.invalidate(path)
	return path
end

local function read(path)
	Document.invalidate(path)
	return vim.fn.readfile(path)
end

local function move(src_path, src_lnum, dst_path, dst_lnum, last)
	local src, err = Move.source(Document.get(src_path), src_lnum, last)
	assert(src, err)
	local dst, derr = Move.target(Document.get(dst_path), dst_lnum, src)
	if not dst then
		return nil, derr
	end
	local at, merr = Move.move(src_path, src, dst_path, dst)
	Document.invalidate(src_path)
	Document.invalidate(dst_path)
	return at, merr
end

local AREAS = {
	"@@Move areas", -- 1
	"", -- 2
	"# 6 Programming", -- 3
	"- loose idea", -- 4
	"  - with a note", -- 5
	"", -- 6
	"## 6.3 Tools", -- 7
	"- [ ] sharpen", -- 8
	"", -- 9
	"### 6.3: Homelab", -- 10
	"- [ ] rack", -- 11
	"", -- 12
	"### 6.3: Zortex", -- 13
	"- [ ] PWA", -- 14
	"", -- 15
	"# 7 Home", -- 16
	"Chores:", -- 17
	"- dishes", -- 18
}

T.test("a line with its nested lines goes to the end of a section's own lines", function()
	local p = note("move-areas.zortex", AREAS)
	local at = move(p, 4, p, 7) -- "- loose idea" under "## 6.3 Tools"
	local l = read(p)
	T.eq(vim.list_slice(l, 3, 9), { "# 6 Programming", "", "## 6.3 Tools", "- [ ] sharpen", "- loose idea", "  - with a note", "" })
	T.eq(l[at], "- loose idea")
	T.eq(l[10], "### 6.3: Homelab") -- before the sub-sections, not inside the last one
end)

T.test("a heading section goes last under its new parent, levels and blank lines adjusted", function()
	local p = note("move-areas.zortex", AREAS)
	local at = move(p, 10, p, 16) -- "### 6.3: Homelab" under "# 7 Home"
	local l = read(p)
	T.eq(l[at], "## 6.3: Homelab")
	T.eq(vim.list_slice(l, at - 3, #l), { "Chores:", "- dishes", "", "## 6.3: Homelab", "- [ ] rack" })
	-- the old place closes up: no doubled blank line
	T.eq(vim.list_slice(l, 7, 12), { "## 6.3 Tools", "- [ ] sharpen", "", "### 6.3: Zortex", "- [ ] PWA", "" })
	-- under the note itself: a top-level heading
	p = note("move-areas.zortex", AREAS)
	at = move(p, 13, p, 1)
	l = read(p)
	T.eq(l[at], "# 6.3: Zortex")
	T.eq(l[#l], "- [ ] PWA")
end)

T.test("under a label: its indent; under a line: nested one step deeper", function()
	local p = note("move-areas.zortex", AREAS)
	move(p, 8, p, 17) -- "- [ ] sharpen" under "Chores:"
	local l = read(p)
	T.eq(vim.list_slice(l, #l - 2, #l), { "Chores:", "- dishes", "- [ ] sharpen" })
	p = note("move-areas.zortex", AREAS)
	move(p, 14, p, 18) -- "- [ ] PWA" under "- dishes"
	l = read(p)
	T.eq(vim.list_slice(l, #l - 1, #l), { "- dishes", "  - [ ] PWA" })
	-- and back out: nested lines lose the indent they don't need
	p = note("move-areas.zortex", AREAS)
	move(p, 5, p, 16) -- under "# 7 Home": before its "Chores:" label
	l = read(p)
	T.eq(vim.list_slice(l, 15, 17), { "# 7 Home", "- with a note", "Chores:" })
end)

T.test("refused: a heading under a label or a line, a section into itself", function()
	local p = note("move-areas.zortex", AREAS)
	local at, err = move(p, 10, p, 17)
	T.ok(not at and err:find("heading"), err)
	at, err = move(p, 10, p, 18)
	T.ok(not at and err:find("heading"), err)
	local src = Move.source(Document.get(p), 7)
	local dst = Move.target(Document.get(p), 10, src)
	at, err = Move.move(p, src, p, dst)
	T.ok(not at and err:find("itself"), err)
	T.eq(read(p), AREAS)
	local _, herr = Move.source(Document.get(p), 1)
	T.ok(herr and herr:find("header"), herr)
	local c = note("move-code.zortex", { "@@Move code", "", "```", "- not a list", "```" })
	_, err = Move.target(Document.get(c), 4, { kind = "lines" })
	T.ok(err and err:find("code"), err)
	vim.fn.delete(c)
end)

T.test("to another note, loaded in a buffer or not; a selected range moves as is", function()
	local a = note("move-areas.zortex", AREAS)
	local b = note("move-other.zortex", { "@@Move other", "", "# Inbox", "- first" })
	vim.cmd("edit! " .. vim.fn.fnameescape(a))
	local bufnr = vim.api.nvim_get_current_buf()
	move(a, 13, b, 3) -- "### 6.3: Zortex" (and its task) under "# Inbox"
	T.eq(read(b), { "@@Move other", "", "# Inbox", "- first", "", "## 6.3: Zortex", "- [ ] PWA" })
	local l = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) -- the buffer was edited, not the file
	T.ok(not vim.tbl_contains(l, "### 6.3: Zortex"), vim.inspect(l))
	T.eq(read(a), AREAS)
	vim.cmd("silent! bwipeout! " .. bufnr)
	-- lines 17-18 as selected: the label and its item, under "# Inbox"
	a = note("move-areas.zortex", AREAS)
	move(a, 17, b, 3, 18)
	T.eq(vim.list_slice(read(b), 3, 6), { "# Inbox", "- first", "Chores:", "- dishes" })
end)

T.test(":ZortexMove picks the place in the structural search", function()
	local p = note("move-areas.zortex", AREAS)
	require("zortex.core.notes").refresh = require("zortex.core.notes").refresh
	vim.cmd("edit! " .. vim.fn.fnameescape(p))
	local bufnr = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(0, { 8, 0 }) -- "- [ ] sharpen"
	local Picker = require("zortex.ui.picker")
	local pick, spec = Picker.pick, nil
	Picker.pick = function(s)
		spec = s
	end
	local ok, err = pcall(require("zortex.features.move").move_current)
	Picker.pick = pick
	assert(ok, err)
	T.ok(spec and spec.title():find('^Move "%- %[ %] sharpen" to'), spec and spec.title())
	for _, k in pairs(spec.keys) do
		T.ok(not k.desc:find("New note"), "no new-note key")
	end
	T.ok(not spec.title():find("new note", 1, true), spec.title())
	local hit
	for _, r in ipairs(spec.query("homelab")) do -- one word: still any depth
		if r.result_type == "section" and r.node.text == "6.3: Homelab" then
			hit = r
		end
	end
	T.ok(hit, "the search finds the heading")
	spec.open(hit)
	local l = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	T.eq(vim.list_slice(l, 7, 11), { "## 6.3 Tools", "", "### 6.3: Homelab", "- [ ] rack", "- [ ] sharpen" })
	vim.cmd("silent! bwipeout! " .. bufnr)
	vim.fn.delete(p)
	vim.fn.delete(Config.notes_dir .. "move-other.zortex")
end)
