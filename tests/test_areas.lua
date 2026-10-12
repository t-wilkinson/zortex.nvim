local T = require("helpers")
local A = require("zortex.services.areas")
local P = require("zortex.services.projects")

T.test("area tree: headings and labels, clean keys, A/ links", function()
	local keys = vim.tbl_map(function(a)
		return a.key
	end, A.all())
	T.eq(keys, {
		"Areas",
		"Areas/1 Personal Foundation",
		"Areas/1 Personal Foundation/1.1 Core values",
		"Areas/1 Personal Foundation/1.2 Vitality",
		"Areas/1 Personal Foundation/1.2 Vitality/Fitness",
		"Areas/4 Learning & Education",
		"Areas/4 Learning & Education/4.1 Education & Skills",
		"Areas/4 Learning & Education/4.2 Personal Interests",
	})
	T.eq(A.get("Areas/1 Personal Foundation/1.2 Vitality/Fitness").link, "[A/#1 Personal Foundation/#1.2 Vitality/:Fitness]")
end)

T.test("every area link resolves back to its area", function()
	for _, a in ipairs(A.all()) do
		T.eq((A.resolve(a.link) or {}).key, a.key, a.link)
	end
end)

T.test("resolve short and attribute-style links", function()
	T.eq(A.resolve("[A/#1.2]").name, "1.2 Vitality")
	T.eq(A.resolve("Areas/#4.1").name, "4.1 Education & Skills")
	T.eq(A.resolve("[A/#1.2/:Fitness]").name, "Fitness")
	T.ok(not A.resolve("[P/#1.4 - zortex]"), "projects are not areas")
end)

T.test("area:projects() uses inherited project areas", function()
	local skills = A.get("Areas/4 Learning & Education/4.1 Education & Skills")
	local keys = vim.tbl_map(function(p)
		return p.key
	end, skills:projects())
	T.eq(keys, {
		"Projects/1 Programming/1.4 - zortex",
		"Projects/1 Programming/1.4 - zortex/1.4.1 - zortex search",
	})
	T.eq(#A.get("Areas/4 Learning & Education"):projects(), 0)
	T.eq(#A.get("Areas/4 Learning & Education"):projects({ descendants = true }), 2)
end)

T.test("area:objectives()", function()
	local skills = A.get("Areas/4 Learning & Education/4.1 Education & Skills")
	local objs = skills:objectives()
	T.eq(#objs, 1)
	T.eq(objs[1].title, "Ship zortex projects")
end)

T.test("keys_for: XP area keys from tasks, projects (inherited) and objectives", function()
	local task = { attributes = require("zortex.utils.attributes").parse_task_attributes("x @a(1.2/Fitness)") }
	local search = P.get("Projects/1 Programming/1.4 - zortex/1.4.1 - zortex search")
	local okr = require("zortex.services.okr").get_objectives()
	T.eq(A.keys_for(task, search, okr[2]), {
		"Areas/1 Personal Foundation/1.2 Vitality/Fitness",
		"Areas/4 Learning & Education/4.1 Education & Skills",
	})
end)

T.test("project:area_links() reports unresolved links", function()
	local p = P.get("Projects/1 Programming/1.4 - zortex")
	local links = p:area_links()
	T.eq(#links, 1)
	T.ok(links[1].area, "4.1 resolves")
end)

T.test("xp_data: areas without linked work have none", function()
	local data = A.get("Areas/1 Personal Foundation"):xp_data()
	T.eq(data.xp, 0)
	T.eq(data.total_xp, 0)
	-- 4.1 is linked from the zortex project (which has completed tasks)
	T.eq(A.top(5)[1].key, "Areas/4 Learning & Education/4.1 Education & Skills")
end)
