local T = require("helpers")
local fs = require("zortex.utils.filesystem")
local link_index = require("zortex.core.link_index")
local link_resolver = require("zortex.core.link")
local P = require("zortex.services.projects")

local function short(path)
	return vim.fn.fnamemodify(path, ":t")
end

T.test("index is persisted under notes_dir/.z", function()
	link_index.rebuild()
	T.ok(fs.file_exists(T.fixture(".z/link_index.json")), "link_index.json written")
end)

T.test("backlinks of a project (own content vs subtree)", function()
	local zortex = P.get("Projects/1 Programming/1.4 - zortex")
	local own = vim.tbl_map(function(r)
		return short(r.file) .. ":" .. r.lnum
	end, zortex:backlinks())
	-- day-plan: "09:00 [P/#1.4 - zortex]" and its [./-Item] children
	T.eq(own, {
		"calendar.zortex:5",
		"calendar.zortex:11",
		"okr.zortex:14",
		"day-plan.zortex:3",
		"day-plan.zortex:4",
		"day-plan.zortex:8",
	})
	local all = zortex:backlinks({ descendants = true })
	T.eq(#all, 9) -- + KR2 -> 1.4.1, and day-plan's [./#1.4.1 ...] and its child
end)

T.test("backlinks of a section node", function()
	local Document = require("zortex.core.document")
	local doc = Document.get(T.fixture("projects.zortex"))
	local node = doc:node_starting_at(7) -- # 1 Programming
	local refs = link_index.backlinks({ doc = doc, node = node })
	T.eq(#refs, 1) -- "15:00 Reflect on [P/#1 Programming]"
	T.eq(refs[1].text, "[P/#1 Programming]")
end)

T.test("unresolved links", function()
	local broken = link_index.unresolved()
	T.eq(#broken, 1)
	T.eq(short(broken[1].file), "areas.zortex")
	T.eq(broken[1].text, "[P/#No such project]")
end)

T.test("a path link is broken only when its file is missing", function()
	local probe = T.fixture("z/paths.zortex")
	fs.write_lines(probe, { "@@Paths", "", "- [./garden.zortex] [../okr.zortex#x] [../z] [./gone.pdf]" })
	local broken = function()
		link_index.refresh(true)
		return vim.tbl_map(function(r)
			return r.text
		end, link_index.unresolved())
	end
	T.eq(broken(), { "[P/#No such project]", "[./gone.pdf]" })
	local gone = T.fixture("z/gone.pdf")
	fs.write_lines(gone, { "%PDF" })
	T.eq(broken(), { "[P/#No such project]" }) -- checked when queried
	os.remove(gone)
	os.remove(probe)
	link_index.refresh(true)
end)

T.test("incremental refresh re-resolves links affected by a change", function()
	local probe = T.fixture("probe.zortex")
	fs.write_lines(probe, { "@@Probe", "", "- compare [P/#1.4]" })
	link_index.refresh(true)
	local function probe_target()
		local refs = link_index.links_from(probe)
		local t = refs[1].target
		return fs.read_lines(t.file)[t.lnum]
	end
	T.eq(probe_target(), "## 1.4 - esp32")

	-- A new earlier "1.4" heading in the Projects file changes the canonical target
	local pfile = T.fixture("projects.zortex")
	local original = fs.read_lines(pfile)
	local edited = vim.list_slice(original)
	table.insert(edited, 10, "## 1.4 - abc")
	fs.write_lines(pfile, edited)
	link_index.refresh(true)
	T.eq(probe_target(), "## 1.4 - abc")

	fs.write_lines(pfile, original)
	os.remove(probe)
	link_index.refresh(true)
	T.eq(link_index.links_from(probe)[1], nil)
end)

T.test("nothing is re-resolved when no note changed (loaded from disk)", function()
	link_index.refresh(true)
	link_index.save() -- as on exit
	link_index._reset() -- drop memory; next refresh loads link_index.json
	local calls = 0
	local orig = link_resolver.resolve_first
	link_resolver.resolve_first = function(...)
		calls = calls + 1
		return orig(...)
	end
	link_index.refresh(true)
	link_resolver.resolve_first = orig
	T.eq(calls, 0)
	T.ok(#link_index.unresolved() == 1, "state restored from disk")
end)

T.test("broken links are diagnostics on their spans", function()
	local Config = require("zortex.config")
	local path = Config.notes_dir .. "diag.zortex"
	vim.fn.writefile({ "@@Diag", "", "- ok [P/#1.4 - zortex] and [Nope/#nothing]", "- file [./z/missing.pdf]", "- [/#Here]", "# Here" }, path)
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	local buf = vim.api.nvim_get_current_buf()
	local diag = require("zortex.features.diagnostics")
	diag.update(buf)
	local got = {}
	for _, d in ipairs(vim.diagnostic.get(buf, { namespace = diag.namespace })) do
		got[#got + 1] = { d.lnum, d.col, d.end_col, d.message }
	end
	table.sort(got, function(a, b)
		return a[1] < b[1]
	end)
	T.eq(got, {
		{ 2, 27, 42, "Link resolves nowhere: [Nope/#nothing]" },
		{ 3, 7, 24, "No such file: ./z/missing.pdf" },
	})
	-- fixed: the diagnostic goes
	vim.api.nvim_buf_set_lines(buf, 2, 4, false, { "- ok [P/#1.4 - zortex]" })
	diag.update(buf)
	T.eq(#vim.diagnostic.get(buf, { namespace = diag.namespace }), 0)
	vim.cmd("bwipeout!")
	os.remove(path)
end)
