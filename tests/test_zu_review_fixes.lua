-- The reviews' one-key fixes and the weekly review's top-down plan: each
-- key edits the note behind the line, as one batch u takes back.
local T = require("helpers")
local Config = require("zortex.config")
local review = require("zortex.ui.review")
local fs = require("zortex.utils.filesystem")

local TODAY = "2026-10-11"

local function find(lines, text)
	for i, l in ipairs(lines) do
		if l:find(text, 1, true) then
			return i, l
		end
	end
end

-- Notes for these tests: a project note, a vision and an objective; the
-- fixture notes they touch are put back afterwards
local function with_notes(fn)
	local dir = Config.notes_dir
	local proj = dir .. "fix-proj.zortex"
	local saved = {}
	for _, f in ipairs({ fs.get_areas_file(), fs.get_okr_file(), fs.get_calendar_file(), fs.get_projects_file() }) do
		saved[f] = vim.fn.readfile(f)
	end
	vim.fn.writefile({
		"@@Fix proj",
		"@P",
		"",
		"# Garden @a(4.1)",
		"- [ ] Dig the beds",
		"# Shed @a(4.1)",
		"- [x] Build it @done(2026-10-10)",
		"# Loose",
		"- [x] Wash the car @done(2026-10-11)",
	}, proj)
	local areas = vim.deepcopy(saved[fs.get_areas_file()])
	-- a vision above the first area, and one for 4.1
	local first
	for i, l in ipairs(areas) do
		if l:match("^#") and not first then
			first = i
		end
	end
	table.insert(areas, first, "Vision: a life of steady, chosen work")
	table.insert(areas, first + 1, "")
	for i, l in ipairs(areas) do
		if l:match("^## 4%.1") then
			table.insert(areas, i + 1, "Vision: learn one hard thing a year")
			break
		end
	end
	vim.fn.writefile(areas, fs.get_areas_file())
	local okr = vim.deepcopy(saved[fs.get_okr_file()])
	vim.list_extend(okr, { "", "## 3M-2026-Q4 Grow food @a(4.1)", "- KR1: [ ] A harvest", "", "## 3M-2026-Q4 No key results yet @a(4.1)" })
	vim.fn.writefile(okr, fs.get_okr_file())
	-- the note list is cached for a moment: fix-proj.zortex comes and goes
	require("zortex.core.notes").invalidate()
	require("zortex.core.document").invalidate()
	require("zortex.core.link_index").refresh(true)
	local orig_input, orig_select = vim.ui.input, vim.ui.select
	local ok, err = xpcall(function()
		fn(proj)
	end, debug.traceback)
	vim.ui.input, vim.ui.select = orig_input, orig_select
	pcall(vim.cmd, "silent! bwipeout! zortex://review")
	for f, lines in pairs(saved) do
		vim.fn.writefile(lines, f)
		local b = vim.fn.bufnr(f)
		if b > 0 then
			vim.cmd("silent! bwipeout! " .. b)
		end
	end
	for _, f in ipairs({ proj, fs.joinpath(Config.notes_dir, "z/archive.fix-proj.zortex"), require("zortex.features.archive").tasks_archive_path() }) do
		local b = vim.fn.bufnr(f)
		if b > 0 then
			vim.cmd("silent! bwipeout! " .. b)
		end
		os.remove(f)
	end
	-- the note list is cached for a moment: fix-proj.zortex comes and goes
	require("zortex.core.notes").invalidate()
	require("zortex.core.document").invalidate()
	require("zortex.core.link_index").refresh(true)
	assert(ok, err)
end

local function press(key, line_text, answer)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local i = find(lines, line_text)
	assert(i, "no line " .. line_text .. "\n" .. table.concat(lines, "\n"))
	vim.api.nvim_win_set_cursor(0, { i, 0 })
	vim.ui.input = function(_, cb)
		cb(answer)
	end
	vim.ui.select = function(items, opts, cb)
		for _, it in ipairs(items) do
			if opts.format_item(it):find(answer, 1, true) then
				return cb(it)
			end
		end
		cb(nil)
	end
	vim.fn.maparg(key, "n", false, true).callback()
end

local function read(path)
	require("zortex.core.document").invalidate(path)
	return vim.fn.readfile(path)
end

T.test("weekly review: the plan top down, from the vision to the projects", function()
	with_notes(function()
		local r = require("zortex.services.agenda").review({ today = TODAY, days = 7 })
		local lines = review.render(r)
		local head = find(lines, "# Vision, areas, objectives, key results, projects")
		T.ok(head and head < find(lines, "# Plan"), "before the rest of the plan")
		T.ok(find(lines, "Vision: a life of steady, chosen work"), "the vision")
		local area = find(lines, "4.1 Education")
		local vision = find(lines, "Vision: learn one hard thing a year")
		local obj = find(lines, "Grow food")
		local kr = find(lines, "KR1: A harvest")
		T.ok(area and vision and obj and kr and area < vision and vision < obj and obj < kr, table.concat(lines, "\n"))
		T.ok(find(lines, "no project moves it: L links one"), "a key result with no project")
		T.ok(find(lines, "no key results: R adds one"), "an objective with no key results")
		T.ok(find(lines, "[P/Fix proj/#Garden]") and select(2, find(lines, "[P/Fix proj/#Garden]")):find("area only", 1, true), "area-only projects")
	end)
end)

T.test("weekly review keys: L, R, n, z, a, p", function()
	with_notes(function(proj)
		review.open({ today = TODAY })
		local okr = fs.get_okr_file()

		press("L", "KR1: A harvest", "[P/Fix proj/#Garden]")
		T.ok(vim.iter(read(okr)):any(function(l)
			return l == "- KR1: [ ] A harvest [P/Fix proj/#Garden]"
		end), table.concat(read(okr), "\n"))

		press("R", "No key results yet", "Plant three beds")
		T.ok(vim.tbl_contains(read(okr), "- KR1: [ ] Plant three beds"), table.concat(read(okr), "\n"))
		-- u takes the last one back
		vim.fn.maparg("u", "n", false, true).callback()
		T.ok(not vim.tbl_contains(read(okr), "- KR1: [ ] Plant three beds"), "undone")

		press("n", "- [P/Fix proj/#Garden]", "Buy seeds")
		T.eq(vim.list_slice(read(proj), 4, 6), { "# Garden @a(4.1)", "- [ ] Dig the beds", "- [ ] Buy seeds" })

		press("z", "- [P/Fix proj/#Garden]", "")
		T.eq(read(proj)[4], "# Garden @a(4.1) @someday")
		local r = require("zortex.services.agenda").review({ today = TODAY, days = 7 })
		for _, p in ipairs(r.stale) do
			T.ok(p.key ~= "Fix proj/Garden", "@someday isn't stale")
		end

		-- a: a done project goes to its archive; an open one stays
		press("a", "- [P/Fix proj/#Garden]", "")
		T.ok(vim.tbl_contains(read(proj), "# Garden @a(4.1) @someday"), "open: kept")
		press("a", "- [P/Fix proj/#Shed]", "")
		T.ok(not vim.tbl_contains(read(proj), "# Shed @a(4.1)"), "done: archived")
		T.ok(vim.tbl_contains(read(fs.joinpath(Config.notes_dir, "z/archive.fix-proj.zortex")), "# Shed @a(4.1)"))

		press("p", "Areas without active projects", "")
		local area_line = find(vim.api.nvim_buf_get_lines(0, 0, -1, false), "Areas without active projects")
		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		local target = lines[area_line + 1]
		press("p", target, "Pick up running")
		local projects = read(fs.get_projects_file())
		T.ok(vim.iter(projects):any(function(l)
			return l:match("^# Pick up running @area%(") ~= nil
		end), table.concat(projects, "\n"))
	end)
end)

T.test("daily review keys: x, d, t, a", function()
	with_notes(function(proj)
		local cal = fs.get_calendar_file()
		local c = read(cal)
		vim.list_extend(c, { "", "**" .. TODAY .. ":**", "14:00 [ ] Write the notes" })
		-- a project task due today: listed under "Due today and tomorrow"
		local p = read(proj)
		p[5] = "- [ ] Dig the beds @due(" .. TODAY .. ")"
		vim.fn.writefile(p, proj)
		vim.fn.writefile(c, cal)
		require("zortex.core.document").invalidate()
		require("zortex.core.link_index").refresh(true)
		require("zortex.services.agenda").mark_day_reviewed("2000-01-01", "2000-01-01")
		review.open({ today = TODAY, scope = "day" })
		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		T.ok(find(lines, "Work done: "), "the alignment line")

		-- d: a new @due; x ticks it (both on the project task)
		press("d", "Dig the beds", "2026-10-20")
		T.eq(read(proj)[5], "- [ ] Dig the beds @due(2026-10-20)")

		-- t: same time tomorrow, [>] on today's line
		press("t", "Write the notes", "")
		local after = read(cal)
		T.ok(vim.iter(after):any(function(l)
			return l:match("^14:00 %[>%] Write the notes @id%(") ~= nil
		end), table.concat(after, "\n"))
		local tomorrow = vim.fn.index(after, "**2026-10-12:**") + 1
		T.ok(tomorrow > 0 and after[tomorrow + 1]:match("^14:00 %[ %] Write the notes @id%("), table.concat(after, "\n"))

		-- a: a finished task on neither a key result nor an area goes to
		-- z/archive.tasks.zortex
		lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		local i = find(lines, "Done on neither a key result nor an area")
		T.ok(i, table.concat(lines, "\n"))
		press("a", "Wash the car (", "") -- the line under "Done on neither…"
		local archive = read(require("zortex.features.archive").tasks_archive_path())
		T.ok(vim.tbl_contains(archive, "# Fix proj"), table.concat(archive, "\n"))
		T.ok(vim.iter(archive):any(function(l)
			return l:find("Wash the car", 1, true) ~= nil
		end))
		T.ok(not vim.iter(read(proj)):any(function(l)
			return l:find("Wash the car", 1, true) ~= nil
		end), "gone from the project")
		vim.fn.maparg("u", "n", false, true).callback()
		T.ok(vim.iter(read(proj)):any(function(l)
			return l:find("Wash the car", 1, true) ~= nil
		end), "u brings it back")

		press("x", "Call the mechanic", "")
		T.ok(vim.iter(read(cal)):any(function(l)
			return l:match("^%- %[x%] Call the mechanic") ~= nil
		end), table.concat(read(cal), "\n"))
	end)
end)

T.test("the review keeps h j k l for moving the cursor", function()
	for _, k in ipairs(require("zortex.keys").of("review")) do
		T.ok(not ({ h = true, j = true, k = true, l = true })[k.lhs], k.lhs .. " is mapped to " .. k.action)
	end
end)
