-- features/rename (:ZortexRename): a heading or label renamed, and every
-- link through it rewritten where it no longer finds it.
local T = require("helpers")
local Document = require("zortex.core.document")
local Config = require("zortex.config")
local Rename = require("zortex.features.rename")

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

T.test("rename a heading: links through it follow, prefixes that still match stay", function()
	local p = note("rn-projects.zortex", {
		"@@Rn projects", -- 1
		"", -- 2
		"# 3 Home", -- 3
		"## 3.1 Kitchen shelves @size(md)", -- 4
		"- [ ] Buy brackets", -- 5
		"Notes:", -- 6
		"- see [/#3.1 Kitchen shelves/:Notes]", -- 7
		"## 3.2 Garden", -- 8
	})
	local o = note("rn-other.zortex", {
		"@@Rn other",
		"",
		"- [Rn projects/#3.1 Kitchen shelves] and [Rn projects/#3.1/-Buy brackets]",
		"- [Rn projects/#3.1 Kitchen shelves/:Notes] @p1",
		"- [Rn projects/#3.2 Garden] stays",
	})
	require("zortex.core.link_index").refresh(true)

	local plan = assert(Rename.plan(p, 4, "4.1 Kitchen shelves & hooks"))
	T.eq(plan.title.line, "## 4.1 Kitchen shelves & hooks @size(md)")
	T.eq(plan.count, 4)
	Rename.apply(plan)

	local l = read(p)
	T.eq(l[4], "## 4.1 Kitchen shelves & hooks @size(md)")
	T.eq(l[7], "- see [/#4.1 Kitchen shelves & hooks/:Notes]")
	local other = read(o)
	T.eq(other[3], "- [Rn projects/#4.1 Kitchen shelves & hooks] and [Rn projects/#4.1 Kitchen shelves & hooks/-Buy brackets]")
	T.eq(other[4], "- [Rn projects/#4.1 Kitchen shelves & hooks/:Notes] @p1")
	T.eq(other[5], "- [Rn projects/#3.2 Garden] stays")

	-- a longer title: "#4.1 Kitchen" links still find it and are left alone
	require("zortex.core.link_index").refresh(true)
	plan = assert(Rename.plan(p, 4, "4.1 Kitchen shelves & hooks (done)"))
	T.eq(plan.count, 0)
	T.eq(plan.links, {})
end)

T.test("rename a label; only headings, bold headings and labels can be renamed", function()
	local p = note("rn-labels.zortex", { "@@Rn labels", "", "Reading list:", "- a book", "- [/:Reading list/-a book]" })
	require("zortex.core.link_index").refresh(true)
	local plan = assert(Rename.plan(p, 3, "Books"))
	T.eq(plan.title.line, "Books:")
	Rename.apply(plan)
	T.eq(read(p)[5], "- [/:Books/-a book]")
	local none, err = Rename.plan(p, 4, "x")
	T.eq(none, nil)
	T.ok(err:find("not on a heading"), err)
end)
