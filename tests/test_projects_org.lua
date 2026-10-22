-- Organizational headings: a heading of a project note with no task of its
-- own (done or not) and no project attribute only groups the projects under
-- it. It isn't a project unless something links it and it has projects
-- under it; it still names them.
local T = require("helpers")
local P = require("zortex.services.projects")

local function with_note(lines, extra, fn)
	local dir = require("zortex.config").notes_dir
	local path = dir .. "org-test.zortex"
	local link = dir .. "org-links.zortex"
	vim.fn.writefile(lines, path)
	vim.fn.writefile(extra or { "@@Org links", "" }, link)
	local function reset()
		require("zortex.core.notes").invalidate()
		require("zortex.core.document").invalidate()
		require("zortex.core.link_index").refresh(true)
	end
	reset()
	local ok, err = xpcall(function()
		fn(path)
	end, debug.traceback)
	os.remove(path)
	os.remove(link)
	reset()
	if not ok then
		error(err, 0)
	end
end

local NOTE = {
	"@@Org test", -- 1
	"@P", -- 2
	"", -- 3
	"# Car @cars", -- 4  organizational: a tag, no tasks
	"Notes about the car, no tasks.", -- 5
	"## Rebuild engine", -- 6
	"- [ ] Lap the valves", -- 7
	"## Fix brakes", -- 8
	"- [x] Order pads", -- 9
	"# Someday ideas @ideas", -- 10 organizational: a tag isn't a project attribute
	"## Empty idea", -- 11 organizational: nothing at all
	"# Learn piano @lg", -- 12 a project: an attribute
	"# Parked @someday", -- 13 a project
	"# Home", -- 14 a project: a task of its own
	"- [ ] Fix the gate", -- 15
	"## Garden", -- 16 organizational, inside a project
	"### Beds", -- 17
	"- [ ] Dig", -- 18
}

local function keys(list)
	return vim.tbl_map(function(p)
		return p.key
	end, list)
end

T.test("organizational headings aren't projects; they still name the ones under them", function()
	with_note(NOTE, nil, function(path)
		local all = keys(P.all({ filter = function(p)
			return p.file == vim.fn.fnamemodify(path, ":p")
		end }))
		T.eq(all, {
			"Org test",
			"Org test/Car/Rebuild engine",
			"Org test/Car/Fix brakes",
			"Org test/Learn piano",
			"Org test/Parked",
			"Org test/Home",
			"Org test/Home/Garden/Beds",
		})
		local engine = P.get("Org test/Car/Rebuild engine")
		T.eq(engine.link, "[P/Org test/#Car/#Rebuild engine]")
		T.eq(engine.parent.key, "Org test") -- the nearest project above
		T.eq(P.get("Org test/Home/Garden/Beds").parent.key, "Org test/Home")
		-- a project's own content stops at any sub-heading
		local home = P.get("Org test/Home")
		T.eq({ home:own_range() }, { 14, 15 })
		T.eq(#home:tasks(), 1)
		T.eq(home:rollup().total, 2) -- Beds' task under it
		-- the root's own content stops at "# Car": the car's notes aren't its
		T.eq({ P.get("Org test"):own_range() }, { 1, 3 })
		-- the cursor on an organizational heading is in the project around it
		T.eq(P.at(path, 4).key, "Org test")
		T.eq(P.for_target(path, 11), {}) -- links to it: no project
	end)
end)

T.test("a linked heading with projects under it is a project again", function()
	with_note(NOTE, { "@@Org links", "", "- [P/Org test/#Car] needs work", "- [P/Org test/#Someday ideas/#Empty idea]" }, function(path)
		local car = P.get("Org test/Car")
		T.ok(car, "Car is a project")
		T.eq(P.get("Org test/Car/Rebuild engine").parent, car)
		T.eq(car:rollup().total, 2)
		T.eq(keys(P.for_target(path, 4)), { "Org test/Car" })
		-- linked, but nothing under it is a project: still organizational
		T.eq(P.get("Org test/Someday ideas/Empty idea"), nil)
		T.eq(P.get("Org test/Someday ideas"), nil)
		T.eq(P.for_target(path, 11), {})
	end)
end)

T.test("a link from inside the heading doesn't count", function()
	local note = vim.deepcopy(NOTE)
	note[7] = "- [ ] Lap the valves, see [P/Org test/#Car]"
	with_note(note, nil, function()
		T.eq(P.get("Org test/Car"), nil)
	end)
end)

