local T = require("helpers")
local q = require("zortex.query")

-- Plain data: survives a JSON round trip unchanged
local function plain(value, what)
	local ok, json = pcall(vim.json.encode, value)
	T.ok(ok, what .. " encodes: " .. tostring(json))
	T.eq(vim.json.decode(json, { luanil = { object = true, array = true } }), vim.json.decode(json), what)
	return vim.json.decode(json)
end

T.test("tree lists folders and notes", function()
	local tree = plain(q.tree(), "tree")
	local names = vim.tbl_map(function(n)
		return n.rel
	end, tree.notes)
	T.ok(vim.tbl_contains(names, "projects.zortex"), vim.inspect(names))
	T.eq(tree.dirs[1].name, "z")
	local z = plain(q.tree("z"), "tree z")
	local archive = vim.tbl_filter(function(n)
		return n.rel == "z/archive.projects.zortex"
	end, z.notes)[1]
	T.ok(archive and archive.archived, "archived note listed and marked")
end)

T.test("note: header, outline and syntax", function()
	local note = plain(q.note("projects.zortex"), "note")
	T.eq(note.title, "Projects")
	T.eq(note.outline[1].type, "article")
	T.eq(note.outline[1].children[1].text, "1 Programming")
	T.eq(#note.syntax.lines, #note.lines)
	T.eq(note.syntax.lines[5].item.mark, " ")
end)

T.test("search, resolve, backlinks", function()
	local results = plain(q.search("zortex search", { limit = 3 }), "search")
	T.eq(results[1].breadcrumb, "Projects › 1 Programming › 1.4 - zortex › 1.4.1 - zortex search")
	local hits = plain(q.resolve("[P/#1.4 - zortex]"), "resolve")
	T.eq(hits[1].rel, "projects.zortex")
	local refs = plain(q.backlinks("projects.zortex", hits[1].lnum), "backlinks")
	T.ok(#refs >= 3, "references from calendar and okr: " .. #refs)
end)

T.test("projects, areas, objectives, agenda, review", function()
	local projects = plain(q.projects(), "projects")
	local zortex = vim.tbl_filter(function(p)
		return p.key == "Projects/1 Programming/1.4 - zortex"
	end, projects)[1]
	T.eq(zortex.attributes.size, "lg")
	T.eq(zortex.tasks[3].attributes.due, "2026-10-12")
	plain(q.areas(), "areas")
	local objectives = plain(q.objectives(), "objectives")
	T.eq(objectives[1].key_results[2].projects, { "Projects/1 Personal/Habits" })
	local days = plain(q.agenda("2026-10-09", "2026-10-12"), "agenda")
	T.eq(days[1].items[1].project, "Projects/1 Programming/1.4 - zortex")
	local review = plain(q.review({ today = "2026-10-11" }), "review")
	T.eq(#review.overdue, 2)
end)

T.test("export writes index and notes", function()
	local dir = vim.fn.tempname()
	local out, count = q.export(dir)
	T.eq(out, dir)
	T.ok(count >= 6, "notes exported: " .. count)
	local index = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/index.json"), "\n"))
	T.eq(index.version, 1)
	T.ok(vim.fn.filereadable(dir .. "/notes/projects.json") == 1, "note file")
	vim.fn.delete(dir, "rf")
end)
