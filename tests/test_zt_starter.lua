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

T.test("setup writes nothing; it says once what's missing, and :Zortex init creates it", function()
	with_dir(function(dir)
		T.ok(starter.is_new_folder())
		local said = {}
		local orig = vim.notify
		vim.notify = function(msg)
			said[#said + 1] = msg
		end
		local ok, err = pcall(function()
			starter.setup()
			vim.wait(50)
			starter.setup() -- the same set again: nothing more
			vim.wait(50)
		end)
		vim.notify = orig
		assert(ok, err)
		T.eq(#said, 1)
		T.ok(said[1]:find(":Zortex init", 1, true), said[1])
		T.eq(#starter.missing(), #starter.order, "nothing created on setup")
		starter.init_command()
		for _, name in ipairs(starter.order) do
			T.ok(vim.fn.filereadable(dir .. name) == 1, name)
		end
		T.eq(read(dir .. "inbox.zortex"), { "@@Inbox", "" })
		T.eq(#starter.missing(), 0)
	end)
end)

T.test(":Zortex init fills the gaps and leaves existing notes alone", function()
	with_dir(function(dir)
		vim.fn.writefile({ "@@Calendar", "", "2026-01-01:", "- mine" }, dir .. "calendar.zortex")
		T.ok(not starter.is_new_folder())
		T.eq(#starter.missing(), 5)
		starter.init_command()
		T.eq(#starter.missing(), 0)
		T.eq(read(dir .. "calendar.zortex")[4], "- mine", "existing notes untouched")
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
	T.ok(has("projects.zortex", "# 1 Example project @area(1.1)"))
	T.ok(has("areas.zortex", "## 1.1 Health"), "@area(1.1) resolves")
	T.ok(all["okr.zortex"][4]:match("^# 3M%-%d%d%d%d%-Q[1-4] Season 1 Aspen$"), "a season heading")
	T.ok(all["okr.zortex"][5]:match("^## 3M%-%d%d%d%d%-Q[1-4] An objective @area%(1%.1%)$"), "an objective")
	local cal = all["calendar.zortex"]
	local day = 1
	while not require("zortex.utils.datetime").date_heading(cal[day]) do
		day = day + 1
	end
	T.eq(syntax.classify(cal[day]).kind, "bold_heading", "a day is a bold label")
	T.eq(syntax.classify(cal[day + 1]).kind, "label", "Outcomes: nests under it")
	T.eq(syntax.classify(cal[day + 2]).kind, "item")
	local rules = require("zortex.services.calendar_rules")
	T.eq(#rules.rules(cal), 2, "two repeating rules")
	T.eq(rules.template(cal, "2026-10-20"), { "Outcomes:", "- [ ] " })
	for _, link in ipairs({ "Projects", "Areas", "Objectives", "Calendar", "Inbox" }) do
		T.ok(has("structure.zortex", "- [" .. link .. "]"), link)
	end
end)
