-- core/starter.lua - The notes Zortex expects, created when missing
--
-- calendar, projects, areas, okr, structure and inbox each get a short
-- template that shows the syntax and links them together.
--
-- Nothing is written on its own: setup() says, once, which are missing
-- (all of them in a new notes folder), and `:Zortex init` creates them. In a
-- folder that already has notes a missing file may simply not have synced
-- yet, so writing one there is your call. The server never creates notes.
local M = {}

local constants = require("zortex.constants")

local function today()
	return os.date("%Y-%m-%d")
end

-- The calendar quarter now, as objectives write it: "3M-2026-Q4"
local function quarter()
	local t = os.date("*t")
	return string.format("3M-%d-Q%d", t.year, math.floor((t.month - 1) / 3) + 1)
end

-- name -> function returning the lines
M.templates = {
	[constants.FILES.CALENDAR] = function()
		return {
			"@@Calendar",
			"@@C",
			"",
			"# Templates",
			"## Weekday",
			"Outcomes:",
			"- [ ] ",
			"",
			"# Repeating",
			"## Birthdays",
			"- A friend's birthday @on(03-14) @born(1990) @notify",
			"## Routines",
			"- [ ] Weekly review @repeat(weekly) @on(sun) @at(12:00)",
			"",
			"# Days",
			"",
			"**" .. today() .. ":**",
			"Outcomes:",
			"- [ ] The one thing that makes today a success",
			"",
			"09:00 - 10:00 Work on [P/#1 Example project]",
			"- [ ] A task for today",
		}
	end,
	[constants.FILES.PROJECTS] = function()
		return {
			"@@Projects",
			"@@P",
			"",
			"# 1 Example project @area(1.1)",
			"- [ ] A first task @size(sm)",
			"- [ ] A second task",
		}
	end,
	[constants.FILES.AREAS] = function()
		return {
			"@@Areas",
			"@@A",
			"",
			"# 0 General",
			"## 0.1 Unassigned",
			"# 1 Personal",
			"## 1.1 Health",
			"## 1.2 Learning",
		}
	end,
	[constants.FILES.OKR] = function()
		return {
			"@@Objectives",
			"@@OKR",
			"",
			"# " .. quarter() .. " Season 1 Aspen",
			"## " .. quarter() .. " An objective @area(1.1)",
			"- KR1: [ ] A key result [P/#1 Example project]",
		}
	end,
	[constants.FILES.STRUCTURE] = function()
		return {
			"@@Structure",
			"@@S",
			"",
			"# Main",
			"- [Projects]",
			"- [Areas]",
			"- [Objectives]",
			"- [Calendar]",
			"- [Inbox]",
		}
	end,
	[constants.FILES.INBOX] = function()
		return { "@@Inbox", "" }
	end,
}

M.order = {
	constants.FILES.CALENDAR,
	constants.FILES.PROJECTS,
	constants.FILES.AREAS,
	constants.FILES.OKR,
	constants.FILES.STRUCTURE,
	constants.FILES.INBOX,
}

local function fs()
	return require("zortex.utils.filesystem")
end

--- Key notes that don't exist (file names).
function M.missing()
	local out = {}
	for _, name in ipairs(M.order) do
		if not fs().file_exists(fs().get_file_path(name)) then
			out[#out + 1] = name
		end
	end
	return out
end

--- A notes folder without any note at its top level.
function M.is_new_folder()
	local dir = require("zortex.config").notes_dir
	local ext = require("zortex.config").extension or ".zortex"
	local handle = vim.uv.fs_scandir(dir)
	if not handle then
		return true
	end
	while true do
		local name, kind = vim.uv.fs_scandir_next(handle)
		if not name then
			return true
		end
		if kind == "file" and name:sub(-#ext) == ext then
			return false
		end
	end
end

--- Create the missing key notes. Returns the names created.
function M.create(names)
	local created = {}
	for _, name in ipairs(names or M.missing()) do
		local path = fs().get_file_path(name)
		local template = M.templates[name]
		if template and not fs().file_exists(path) and fs().write_lines(path, template()) then
			created[#created + 1] = name
		end
	end
	return created
end

local function state()
	return require("zortex.core.state").open("starter", {
		version = 1,
		device = true,
		default = function()
			return { reported = {} }
		end,
	})
end

--- setup(): say once (per set of names) which key notes are missing.
function M.setup()
	local missing = M.missing()
	if #missing == 0 then
		return
	end
	local key = table.concat(missing, ",")
	local st = state()
	if st:get().reported[key] then
		return
	end
	st:get().reported = { [key] = os.date("%Y-%m-%d") }
	st:save()
	local msg = M.is_new_folder()
			and ("No notes in " .. require("zortex.config").notes_dir .. " yet: `:Zortex init` creates the key notes (" .. table.concat(missing, ", ") .. "), from short templates that link to each other.")
		or ("Missing " .. table.concat(missing, ", ") .. ": `:Zortex init` creates them from short templates.")
	vim.schedule(function()
		vim.notify(msg, vim.log.levels.INFO, { title = "Zortex" })
	end)
end

--- :Zortex init
function M.init_command()
	local created = M.create()
	if #created == 0 then
		vim.notify("All key notes exist", vim.log.levels.INFO, { title = "Zortex" })
	else
		vim.notify("Created " .. table.concat(created, ", "), vim.log.levels.INFO, { title = "Zortex" })
	end
end

return M
