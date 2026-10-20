-- core/starter.lua - The notes Zortex expects, created when missing
--
-- calendar, projects, areas, okr, structure and inbox each get a short
-- template that shows the syntax and links them together.
--
-- setup() writes them only into a new notes folder (no .zortex note at its
-- top level yet). In a folder that already has notes, a missing file may
-- simply not have synced yet: writing a template there could win a Syncthing
-- conflict against the real note. There Zortex says which are missing, once,
-- and :ZortexInit creates them. The server never creates notes.
local M = {}

local constants = require("zortex.constants")

local function today()
	return os.date("%Y-%m-%d")
end

local function season()
	local t = os.date("*t")
	return string.format("%d-Q%d", t.year, math.floor((t.month - 1) / 3) + 1)
end

-- name -> function returning the lines
M.templates = {
	[constants.FILES.CALENDAR] = function()
		return {
			"@@Calendar",
			"@@C",
			"",
			"# Templates",
			"Weekday:",
			"Outcomes:",
			"- [ ] ",
			"",
			"# Repeating",
			"## Birthdays",
			"- A friend's birthday @repeat(03-14) @born(1990)",
			"## Routines",
			"12:00 [ ] Weekly review @repeat(weekly, Sunday)",
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
			"# 1 Example project @a(1.1)",
			"- [ ] A first task @size(sm)",
			"- [ ] A second task",
		}
	end,
	[constants.FILES.AREAS] = function()
		return {
			"@@Areas",
			"@@A",
			"",
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
			"# " .. season() .. " Season 1 Aspen",
			"## An objective @a(1.1)",
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
		default = function()
			return { reported = {} }
		end,
	})
end

--- setup(): create the key notes in a new folder; otherwise report missing
--- ones once (per set of names).
function M.setup(opts)
	if opts == false then
		return
	end
	local missing = M.missing()
	if #missing == 0 then
		return
	end
	if M.is_new_folder() then
		local created = M.create(missing)
		if #created > 0 then
			vim.schedule(function()
				vim.notify("Created " .. table.concat(created, ", "), vim.log.levels.INFO, { title = "Zortex" })
			end)
		end
		return
	end
	local key = table.concat(missing, ",")
	local st = state()
	if st:get().reported[key] then
		return
	end
	st:get().reported = { [key] = os.date("%Y-%m-%d") }
	st:save()
	vim.schedule(function()
		vim.notify(
			"Missing " .. table.concat(missing, ", ") .. ". :ZortexInit creates them from a short template.",
			vim.log.levels.INFO,
			{ title = "Zortex" }
		)
	end)
end

--- :ZortexInit
function M.init_command()
	local created = M.create()
	if #created == 0 then
		vim.notify("All key notes exist", vim.log.levels.INFO, { title = "Zortex" })
	else
		vim.notify("Created " .. table.concat(created, ", "), vim.log.levels.INFO, { title = "Zortex" })
	end
end

return M
