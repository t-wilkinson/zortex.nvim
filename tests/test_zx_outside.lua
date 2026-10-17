-- Notes outside notes_dir (a repository's doc/Roadmap.zortex): their links
-- resolve in their own folder, and [~/…] reaches notes_dir.
local T = require("helpers")
local link = require("zortex.core.link")
local notes = require("zortex.core.notes")
local Document = require("zortex.core.document")

T.test("a note outside notes_dir resolves its links in its own folder; ~/ is notes_dir", function()
	local repo = vim.fn.tempname()
	vim.fn.mkdir(repo .. "/doc", "p")
	vim.fn.mkdir(repo .. "/.z", "p")
	vim.fn.writefile({ "@@Roadmap", "", "# Release", "- see [Design/#Goals] and [~/P/#1.4 - zortex]" }, repo .. "/doc/Roadmap.zortex")
	vim.fn.writefile({ "@@Design", "", "# Goals", "- fast" }, repo .. "/doc/Design.zortex")
	vim.fn.writefile({ "@@Notes at the root", "", "# Here" }, repo .. "/top.zortex")

	-- the nearest folder above with a .z/
	T.eq(notes.root_of(repo .. "/doc/Roadmap.zortex"), vim.fn.fnamemodify(repo, ":p"):gsub("/$", ""))
	T.eq(notes.root_of(require("zortex.config").notes_dir .. "projects.zortex"), nil)

	local doc = Document.get(repo .. "/doc/Roadmap.zortex")
	local r = link.resolve_first("[Design/#Goals]", { doc = doc })
	T.ok(r and r.file:find("Design.zortex", 1, true), r and r.file)
	T.ok(link.resolve_first("[Notes at the root/#Here]", { doc = doc }), "the root's other folders too")
	-- notes_dir's notes aren't reachable without ~/
	T.eq(link.resolve_first("[P/#1.4 - zortex]", { doc = doc }), nil)
	local home = link.resolve_first("[~/P/#1.4 - zortex]", { doc = doc })
	T.ok(home and home.file:find("projects.zortex", 1, true), home and home.file)
	-- in notes_dir, ~/ changes nothing
	T.eq(link.resolve_first("[~/P/#1.4 - zortex]").lnum, link.resolve_first("[P/#1.4 - zortex]").lnum)
	vim.fn.delete(repo, "rf")
end)

T.test("without a .z/ above it, a note's own folder is its root", function()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	vim.fn.writefile({ "@@Alone", "", "- [Other]" }, dir .. "/alone.zortex")
	vim.fn.writefile({ "@@Other" }, dir .. "/other.zortex")
	T.eq(notes.root_of(dir .. "/alone.zortex"), vim.fn.fnamemodify(dir, ":p"):gsub("/$", ""))
	local r = link.resolve_first("[Other]", { doc = Document.get(dir .. "/alone.zortex") })
	T.ok(r and r.file:find("other.zortex", 1, true), r and r.file)
	vim.fn.delete(dir, "rf")
end)
