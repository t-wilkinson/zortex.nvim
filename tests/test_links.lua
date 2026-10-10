local T = require("helpers")
local links = require("zortex.utils.link_resolver")

local function target(link)
	local r, err = links.resolve_first(link)
	T.ok(r, err)
	return vim.fn.fnamemodify(r.file, ":t") .. ":" .. r.lnum
end

T.test("alias + heading prefix, skipping levels, case-insensitive", function()
	T.eq(target("[P/#1.4 - zortex]"), "projects.zortex:14")
	T.eq(target("[P/#1.4 - Zortex]"), "projects.zortex:14")
	T.eq(target("[Projects/#1 Programming/#1.4 - zortex]"), "projects.zortex:14")
end)

T.test("first match is canonical (parent before children sharing a prefix)", function()
	local results = links.resolve("[P/#1.4]")
	T.eq(#results, 3)
	T.eq(results[1].lnum, 11) -- 1.4 - esp32 comes first in the file
	T.eq(target("[P/#1]"), "projects.zortex:7")
end)

T.test("archived notes are skipped unless asked for", function()
	for _, r in ipairs(links.resolve("[P/#1.4 - zortex]")) do
		T.ok(not r.file:find("archive"), "archive leaked into results")
	end
	T.eq(target("[@Archive/#1.4 - zortex]"), "archive.projects.zortex:6")
end)

T.test("[@P/...] reaches standalone project notes", function()
	T.eq(target("[@P/#Subaru outback]"), "flipping.zortex:11")
	T.eq(target("[@P/Flipping/#Subaru]"), "flipping.zortex:11")
	local tagged = links.resolve("[@P]")
	T.eq(#tagged, 2)
end)

T.test("article link resolves to the article line", function()
	T.eq(target("[Car maintenance]"), "flipping.zortex:1")
end)

T.test("nested path narrows to the section", function()
	T.eq(target("[P/#1 Personal/#Habits]"), "projects.zortex:30")
	local r = links.resolve("[P/#1 Personal/#1.4]")
	T.eq(#r, 0)
end)

T.test("link_for_node round-trips", function()
	local Document = require("zortex.core.document")
	local doc = Document.from_file(require("helpers").fixture("projects.zortex"))
	doc.tree:walk(function(n)
		if n.type == "heading" then
			local link = links.link_for_node(doc, n)
			local node = links.resolve_node(link)
			T.eq(node and node.start_line, n.start_line, link)
		end
	end)
end)

T.test("build_result_link uses clean section paths", function()
	local r = links.resolve_first("[P/#1.4 - zortex/%website]")
	T.eq(links.build_result_link(r), "[Projects/#1 Programming/#1.4 - zortex/%Improve website]")
end)

T.test("article component: alias files first, then tagged files", function()
	local results = links.resolve("[P]")
	T.eq(vim.tbl_map(function(r)
		return vim.fn.fnamemodify(r.file, ":t")
	end, results), { "projects.zortex", "flipping.zortex", "garden.zortex" })
	T.eq(target("[P/Flipping/#Subaru]"), "flipping.zortex:11")
end)
