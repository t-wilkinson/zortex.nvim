-- core/starter: key notes for a new folder
local T = require("helpers")
local starter = require("zortex.core.starter")
local Config = require("zortex.config")

local function with_dir(fn)
	local saved = Config.notes_dir
	local dir = vim.fn.tempname() .. "/"
	vim.fn.mkdir(dir .. ".z", "p")
	Config.notes_dir = dir
	local ok, err = pcall(fn, dir)
	Config.notes_dir = saved
	require("zortex.core.state").open("starter", { version = 1, default = function() return { reported = {} } end }):reload()
	if not ok then
		error(err, 0)
	end
end

local function read(path)
	return vim.fn.readfile(path)
end

T.test("a new folder gets every key note", function()
	with_dir(function(dir)
		T.ok(starter.is_new_folder())
		starter.setup(true)
		for _, name in ipairs(starter.order) do
			T.ok(vim.fn.filereadable(dir .. name) == 1, name)
		end
		T.eq(read(dir .. "inbox.zortex"), { "@@Inbox", "" })
		T.eq(#starter.missing(), 0)
	end)
end)

T.test("a folder with notes is left alone; :ZortexInit fills the gaps", function()
	with_dir(function(dir)
		vim.fn.writefile({ "@@Calendar", "", "2026-01-01:", "- mine" }, dir .. "calendar.zortex")
		T.ok(not starter.is_new_folder())
		starter.setup(true)
		T.eq(vim.fn.filereadable(dir .. "projects.zortex"), 0, "not created on setup")
		T.eq(#starter.missing(), 5)
		starter.init_command()
		T.eq(#starter.missing(), 0)
		T.eq(read(dir .. "calendar.zortex")[4], "- mine", "existing notes untouched")
	end)
end)

T.test("init_files = false creates nothing", function()
	with_dir(function(dir)
		starter.setup(false)
		T.eq(vim.fn.filereadable(dir .. "calendar.zortex"), 0)
	end)
end)

T.test("templates use the syntax and link to each other", function()
	local syntax = require("zortex.core.syntax")
	local all = {}
	for name, make in pairs(starter.templates) do
		all[name] = make()
		T.eq(syntax.parse_header(all[name]).names[1] ~= nil, true, name .. " has an article name")
	end
	local function has(name, line)
		return vim.tbl_contains(all[name], line)
	end
	T.ok(has("projects.zortex", "# 1 Example project @a(1.1)"))
	T.ok(has("areas.zortex", "## 1.1 Health"), "@a(1.1) resolves")
	T.ok(all["okr.zortex"][4]:match("^# %d%d%d%d%-Q[1-4] Season 1 "), "a season heading")
	T.ok(require("zortex.services.okr.objective").parse_season(all["okr.zortex"][4]:sub(3)), "it parses as one")
	T.eq(all["okr.zortex"][5], "## An objective @a(1.1)")
	local cal = all["calendar.zortex"]
	T.eq(syntax.classify(cal[4]).kind, "bold_heading", "a day is a bold label")
	T.eq(syntax.classify(cal[5]).kind, "label", "Outcomes: nests under it")
	T.eq(syntax.classify(cal[6]).kind, "item")
	for _, link in ipairs({ "Projects", "Areas", "Objectives", "Calendar", "Inbox" }) do
		T.ok(has("structure.zortex", "- [" .. link .. "]"), link)
	end
end)
