local T = require("helpers")
local P = require("zortex.services.projects")

T.test("sources: projects file + @P notes, archive excluded", function()
	local names = vim.tbl_map(function(p)
		return vim.fn.fnamemodify(p, ":t")
	end, P.sources())
	T.eq(names, { "projects.zortex", "flipping.zortex", "garden.zortex" })
end)

T.test("roots are articles with clean names", function()
	local names = vim.tbl_map(function(p)
		return p.name
	end, P.roots())
	T.eq(names, { "Projects", "Flipping", "Garden" })
end)

T.test("tree paths, keys and links", function()
	local p = P.get("Projects/1 Programming/1.4 - zortex")
	T.ok(p, "found by key")
	T.eq(p.path, { "Projects", "1 Programming", "1.4 - zortex" })
	T.eq(p.link, "[P/#1 Programming/#1.4 - zortex]")
	T.eq(p.depth, 2)
	T.eq(p.parent.name, "1 Programming")
	T.eq(vim.tbl_map(function(c)
		return c.name
	end, p.children), { "1.4.1 - zortex search" })
	T.eq(P.get("projects/1 programming/1.4 - ZORTEX"), p)
end)

T.test("attributes come from the heading, not the name", function()
	local p = P.get("Projects/1 Programming/1.4 - zortex")
	T.eq(p.name, "1.4 - zortex")
	T.eq(p.attributes.size, "lg")
	T.eq(p.attributes.area[1].definition, "Areas/#4.1")
	T.eq(P.get("Projects/1 Programming").attributes.p, "1")
end)

T.test("own tasks stop at the first sub-project; containers have tasks", function()
	local programming = P.get("Projects/1 Programming")
	T.eq(#programming:tasks(), 2)
	local root = P.roots()[1]
	T.eq(vim.tbl_map(function(t)
		return t.text
	end, root:tasks()), { "Weekly review" })
	local zortex = P.get("Projects/1 Programming/1.4 - zortex")
	T.eq(#zortex:tasks(), 5)
	T.eq(zortex:tasks()[1].lnum, 15)
	T.eq(zortex:tasks()[1].project, zortex)
end)

T.test("stats, rollup and points", function()
	local zortex = P.get("Projects/1 Programming/1.4 - zortex")
	local s = zortex:stats()
	T.eq({ s.total, s.done, s.open }, { 5, 2, 3 })
	-- effort points are the tasks' estimated hours (xp.sizes.task):
	-- md(1) + xl(3) + unsized->md(1) + xs(0.25) + unsized->md(1)
	local function near(a, b)
		return math.abs(a - b) < 1e-9
	end
	T.ok(near(s.points, 6.25), tostring(s.points))
	T.ok(near(s.points_open, 5), tostring(s.points_open))
	local r = zortex:rollup()
	T.eq({ r.total, r.open }, { 6, 4 })
	T.ok(near(r.points, 6.75), tostring(r.points)) -- + the sub-project's sm task
	T.ok(near(zortex:points(), 20), "explicit @size(lg) wins: 20 hours (xp.sizes.project)")
	T.ok(near(P.get("Projects/1 Programming/1.4 - esp32"):points(), 0.5))
	T.eq(P.roots()[1]:rollup().total, 1 + 2 + 1 + 6 + 2)
end)

T.test("standalone @P article: own tasks and sub-projects", function()
	local flipping = P.get("Flipping")
	T.eq(flipping.kind, "article")
	T.eq(flipping.aliases, { "Flipping", "Car maintenance" })
	T.eq(flipping.tags, { "Cars", "P" })
	T.eq(#flipping:tasks(), 1)
	T.eq(flipping.children[1].key, "Flipping/Subaru outback")
	T.eq(flipping.children[1].link, "[P/Flipping/#Subaru outback]")
	T.eq(flipping.link, "[P/Flipping]")
end)

T.test("resolve uses link semantics (prefix, case, skipping levels, @P)", function()
	T.eq(P.resolve("[P/#1.4 - Zortex]").key, "Projects/1 Programming/1.4 - zortex")
	T.eq(P.resolve("[P/#1.4]").key, "Projects/1 Programming/1.4 - esp32")
	T.eq(P.resolve("[@P/#Subaru outback]").key, "Flipping/Subaru outback")
	T.eq(P.resolve("[Car maintenance]").key, "Flipping")
	T.eq(P.resolve("[P/#1.4 - zortex/%Improve website]").key, "Projects/1 Programming/1.4 - zortex")
	T.ok(not P.resolve("[Areas/#4.1]"), "areas are not projects")
end)

T.test("at(): innermost project for a line", function()
	local file = T.fixture("projects.zortex")
	T.eq(P.at(file, 24).key, "Projects/1 Programming/1.4 - zortex") -- inside the Notes: label
	T.eq(P.at(file, 27).key, "Projects/1 Programming/1.4 - zortex/1.4.1 - zortex search")
	T.eq(P.at(file, 5).key, "Projects")
	T.eq(P.at(T.fixture("areas.zortex"), 5), nil)
end)

T.test("all() filters", function()
	local leaves = vim.tbl_map(function(p)
		return p.key
	end, P.all({ leaf = true }))
	T.eq(leaves, {
		"Projects/1 Programming/1.4 - esp32",
		"Projects/1 Programming/1.4 - zortex/1.4.1 - zortex search",
		"Projects/1 Personal/Habits",
		"Flipping/Subaru outback",
		"Garden",
	})
	T.eq(#P.all({ include_roots = false }), 7) -- every heading project
end)

T.test("query sorts", function()
	local by_size = P.query({ sort = "size", leaf = true })
	T.eq(by_size[1].key, "Flipping/Subaru outback") -- xl + md = 11 points
	local by_priority = P.query({ sort = "priority", include_roots = false })
	T.eq(by_priority[1].key, "Projects/1 Programming")
	local by_name = P.query({ sort = "name", leaf = true, limit = 2 })
	T.eq(#by_name, 2)
	T.eq(by_name[1].name, "1.4 - esp32")
end)

T.test("schedule: calendar entries resolve to projects", function()
	local zortex = P.get("Projects/1 Programming/1.4 - zortex")
	local items = zortex:schedule()
	T.eq(vim.tbl_map(function(i)
		return i.date .. " " .. i.time
	end, items), { "2026-10-09 14:00", "2026-10-10 10:00" })
	local programming = P.get("Projects/1 Programming")
	T.eq(#programming:schedule(), 1)
	T.eq(#programming:schedule({ descendants = true }), 3)
	T.eq(#P.get("Flipping/Subaru outback"):schedule(), 1)
	T.eq(#P.get("Flipping"):schedule({ from = "2026-10-10" }), 1)
end)

T.test("key results link to projects by key", function()
	local habits = P.get("Projects/1 Personal/Habits")
	local krs = habits:key_results()
	T.eq(#krs, 1)
	T.eq(krs[1].id, "KR2")
	T.eq(krs[1].objective.title, "Establish and maintain good habits/routine")
	local zortex = P.get("Projects/1 Programming/1.4 - zortex")
	T.eq(#zortex:key_results(), 1)
	local search = P.get("Projects/1 Programming/1.4 - zortex/1.4.1 - zortex search")
	T.eq(#search:key_results(), 1)
	T.eq(#search:key_results({ inherit = true }), 2)
end)

T.test("areas resolve through the link resolver", function()
	local zortex = P.get("Projects/1 Programming/1.4 - zortex")
	local areas = zortex:areas()
	T.eq(#areas, 1)
	T.eq(areas[1].key, "Areas/4 Learning & Education/4.1 Education & Skills")
	T.eq(areas[1].link, "[A/#4 Learning & Education/#4.1 Education & Skills]")
	local search = P.get("Projects/1 Programming/1.4 - zortex/1.4.1 - zortex search")
	T.eq(#search:areas(), 0)
	T.eq(search:areas({ inherit = true })[1].name, "4.1 Education & Skills")
end)

T.test("okr objectives parse new heading format", function()
	local okr = require("zortex.services.okr")
	local objs = okr.objectives()
	T.eq(#objs, 2)
	T.eq(objs[1].span, "3M")
	T.eq(objs[1].period, "Q1")
	T.eq(objs[1].section, "Current")
	T.eq(objs[1].attributes.p, "2")
	T.eq(#objs[1].key_results, 3)
	T.eq(objs[2].key_results[1].completed, true)
end)

T.test("every project link starts with P/ and resolves back to its project", function()
	for _, p in ipairs(P.all()) do
		T.ok(p.link:match("^%[P[/%]]"), p.link)
		local back = P.resolve(p.link)
		T.eq(back and back.key, p.key, p.link)
	end
end)

T.test("[P/...] reaches standalone projects after the Projects article", function()
	T.eq(P.resolve("[P/#Subaru outback]").key, "Flipping/Subaru outback")
	T.eq(P.resolve("[P/Garden]").key, "Garden")
	T.eq(P.resolve("[P/#1.4]").key, "Projects/1 Programming/1.4 - esp32")
	T.eq(P.lookup("Flipping/Subaru outback").link, "[P/Flipping/#Subaru outback]")
end)

T.test("OKR-linked projects score higher", function()
	local score = require("zortex.services.projects.score")
	local habits = P.get("Projects/1 Personal/Habits")
	local esp = P.get("Projects/1 Programming/1.4 - esp32")
	T.eq(score.okr_count(habits), 1) -- KR2 links it (KR1 of the other objective is done)
	T.eq(score.okr_count(esp), 0)
	T.eq(score.okr_bonus(habits), score.weights.okr)
	T.ok(vim.tbl_contains(score.indicators(habits), "OKR"), "OKR indicator")
	local list = P.query({ sort = "okr" })
	T.eq(score.okr_count(list[1]) > 0, true)
end)
