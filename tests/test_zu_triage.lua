-- services/triage: @project(…) on an inbox line says where `m` moves it
local T = require("helpers")
local Document = require("zortex.core.document")
local Config = require("zortex.config")
local triage = require("zortex.services.triage")

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

T.test("@project values are project links", function()
	T.eq(triage.link("1.4"), "[P/#1.4]")
	T.eq(triage.link("1/1.4"), "[P/#1/#1.4]")
	T.eq(triage.link("Kitchen shelves"), "[P/#Kitchen shelves]")
	T.eq(triage.link("P/#Kitchen"), "[P/#Kitchen]")
	T.eq(triage.link("[Flipping/#Subaru outback]"), "[Flipping/#Subaru outback]")
	T.eq(triage.link(""), nil)
end)

T.test("m moves an inbox line and what is nested under it to its @project", function()
	local inbox = note("inbox.zortex", {
		"@@Inbox",
		"",
		"- [ ] Wire the shelf lights @project(Triage target) @p2",
		"  - check the transformer",
		"- loose thought",
	})
	local proj = note("triage-projects.zortex", {
		"@@Triage projects",
		"@P",
		"",
		"# Triage target",
		"- [ ] First step",
		"",
		"# Other",
		"- [ ] Something",
	})
	local old = Config.review
	Config.review = vim.tbl_extend("force", old or {}, { inbox_default = nil })
	local items = triage.items()
	local wire, loose
	for _, x in ipairs(items) do
		if x.text:find("Wire the shelf", 1, true) then
			wire = x
		elseif x.text == "- loose thought" then
			loose = x
		end
	end
	T.ok(wire and wire.project == "[P/#Triage target]", vim.inspect(items))
	T.eq(triage.destination(loose), nil) -- nowhere set: m asks

	local res = assert(triage.move(wire))
	T.eq(vim.fn.fnamemodify(res.file, ":p"), vim.fn.fnamemodify(proj, ":p"))
	local p = read(proj)
	T.eq(vim.list_slice(p, 4, 7), {
		"# Triage target",
		"- [ ] First step",
		"- [ ] Wire the shelf lights @p2",
		"  - check the transformer",
	})
	T.eq(read(inbox), { "@@Inbox", "", "- loose thought" })

	-- review.inbox_default: where lines without @project go
	Config.review.inbox_default = "Triage projects/#Other"
	local items2 = triage.items()
	local l2
	for _, x in ipairs(items2) do
		if x.text == "- loose thought" then
			l2 = x
		end
	end
	T.eq(triage.destination(l2), "[Triage projects/#Other]")
	assert(triage.move(l2))
	T.eq(read(proj)[#read(proj)], "- loose thought")
	Config.review = old
	os.remove(proj)
	os.remove(inbox)
end)

T.test("a task elsewhere with @project is listed too, done ones aren't", function()
	local p = note("triage-elsewhere.zortex", {
		"@@Triage elsewhere",
		"",
		"- [ ] Call the plumber @project(1.4)",
		"- [x] Done already @project(1.4)",
	})
	local found = {}
	for _, x in ipairs(triage.items()) do
		if vim.fn.fnamemodify(x.file, ":p") == vim.fn.fnamemodify(p, ":p") then
			found[#found + 1] = x.lnum
		end
	end
	T.eq(found, { 3 })
	os.remove(p)
end)

T.test("@project( completes the projects, inserting the shortest value that finds each", function()
	local C = require("zortex.features.completion")
	T.eq(C.project_context("- [ ] x @project(1.", #"- [ ] x @project(1."), { typing = "1.", typing_col = 17, project = true })
	T.eq(C.project_context("- [ ] x @project(1.4) y", 23), nil)
	local items = C.get_completions("- [ ] x @project(", #"- [ ] x @project(", {})
	local by = {}
	for _, it in ipairs(items) do
		by[vim.trim(it.label)] = it.area_value
	end
	T.ok(next(by), "projects offered")
	for name, value in pairs(by) do
		local r = require("zortex.core.link").resolve_first(triage.link(value))
		T.ok(r and r.doc.lines[r.lnum]:find(name, 1, true), name .. " <- " .. value)
	end
end)
