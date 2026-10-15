local T = require("helpers")
local syntax = require("zortex.core.syntax")
local Document = require("zortex.core.document")
local notes = require("zortex.core.notes")

T.test("header: names and tags", function()
	local h = syntax.parse_header({ "@@Flipping", "@@Car maintenance", "@Cars", "@P", "", "body" })
	T.eq(h.names, { "Flipping", "Car maintenance" })
	T.eq(h.tags, { "Cars", "P" })
	T.eq(h.name_lnum, 1)
	T.eq(h.last_lnum, 4)
end)

T.test("strip_attributes", function()
	T.eq(syntax.strip_attributes("1.4 - zortex @size(lg) @a(4.1) @p1"), "1.4 - zortex")
	T.eq(syntax.strip_attributes("mail me@example.com"), "mail me@example.com")
end)

T.test("article aliases collapse into one article node", function()
	local doc = Document.from_file(T.fixture("projects.zortex"))
	T.eq(#doc.tree.children, 1)
	local article = doc:article()
	T.eq(article.text, "Projects")
	T.eq(article.names, { "Projects", "P" })
	T.eq(doc:name(), "Projects")
end)

T.test("heading text has no attributes; paths are clean", function()
	local doc = Document.from_file(T.fixture("projects.zortex"))
	local node = doc.tree:find(function(n)
		return n.text == "1.4 - zortex"
	end)
	T.ok(node, "heading found")
	T.eq(node:path_texts(), { "Projects", "1 Programming", "1.4 - zortex" })
	T.eq(node:get_breadcrumb(" › "), "Projects › 1 Programming › 1.4 - zortex")
end)

T.test("labels nest inside headings; headings never nest inside labels", function()
	local doc = Document.from_file(T.fixture("projects.zortex"))
	local zortex = doc.tree:find(function(n)
		return n.text == "1.4 - zortex"
	end)
	local kinds = vim.tbl_map(function(c)
		return c.type .. ":" .. c.text
	end, zortex.children)
	T.eq(kinds, { "label:Notes", "heading:1.4.1 - zortex search" })
end)

T.test("notes index skips archives and orders top-level first", function()
	local files = vim.tbl_map(function(p)
		return vim.fn.fnamemodify(p, ":t")
	end, notes.files())
	T.eq(files, { "areas.zortex", "calendar.zortex", "flipping.zortex", "okr.zortex", "projects.zortex", "day-plan.zortex", "garden.zortex", "resources.zortex" })
	T.eq(#notes.files({ include_archived = true }), 9)
	T.eq(#notes.find_by_tag("p"), 2)
end)

T.test("fold aggregates bottom-up", function()
	local doc = Document.from_file(T.fixture("projects.zortex"))
	local count = doc.tree:fold(function(_, kids)
		local n = 1
		for _, k in ipairs(kids) do
			n = n + k
		end
		return n
	end)
	T.eq(count, 1 + #doc.tree:get_descendants())
end)
