-- keys.lua - The keys of zortex's own buffers and pickers, in one table
--
-- Each buffer maps its keys from here (M.map with its handlers by action),
-- "?" lists them (ui/keyhelp), the pickers put them in their titles
-- (ui/picker), and tests/gen_docs.lua writes them into the README and
-- :help zortex-keys. Changing a key here changes all of them.
--
-- An entry: { lhs, action, desc, label? }. `label` is the short word a
-- picker title shows ("<M-s> sort"). Keys a user can change come from the
-- config instead (`config` names the table: action -> lhs or { lhs... }).
local M = {}

M.BUFFERS = {
	{
		id = "plan",
		name = "Plan",
		where = ":ZortexPlan",
		keys = {
			{ "<CR>", "put", "put at the calendar cursor" },
			{ "i", "place_current", "put on the current calendar line, then type a time" },
			{ "o", "place_next", "put on a new line below, then type a time" },
			{ "O", "place_previous", "put on a new line above, then type a time" },
			{ "p", "append", "add to the day (a task as a copy, under its project's block if there is one)" },
			{ "P", "append_project", "add the project with its next open tasks (a count: how many)" },
			{ "<C-n>", "calendar_down", "calendar cursor down" },
			{ "<C-p>", "calendar_up", "calendar cursor up" },
			{ "<Tab>", "calendar", "go to the calendar" },
			{ "gx", "follow", "follow link" },
			{ "K", "preview", "preview link" },
			{ "r", "refresh", "refresh" },
			{ "q", "close", "close" },
			{ "?", "help", "these keys" },
		},
	},
	{
		id = "review",
		name = "Review",
		where = ":ZortexReview",
		keys = {
			{ "<CR>", "jump", "jump to source" },
			{ "f", "focus", "add the project to the week's focus (or take it out)" },
			{ "m", "triage", "move the inbox line to its @project (or pick a place)" },
			{ "u", "undo", "take the last change back (:ZortexUndo)" },
			{ "t", "next_day", "a task left undone: same time tomorrow" },
			{ "a", "archive", "archive it: a finished task to z/archive.tasks.zortex, a done project to its archive" },
			{ "x", "complete", "tick the task" },
			{ "d", "due", "set or move the task's @due" },
			{ "s", "schedule", "put the task, or a block of the project, on a day" },
			{ "n", "next_action", "add a next action to the project" },
			{ "z", "someday", "park the project (@someday: not stale) or bring it back" },
			{ "L", "link_project", "link a project to the key result" },
			{ "R", "add_kr", "add a key result to the objective" },
			{ "p", "new_project", "start a project for the area" },
			{ "F", "fix_link", "fix the broken link from the search" },
			{ "<Tab>", "note", "go to the reviews note" },
			{ "gx", "follow", "follow link" },
			{ "K", "preview", "preview link" },
			{ "r", "refresh", "refresh" },
			{ "q", "close", "close" },
			{ "?", "help", "these keys" },
		},
	},
	{
		id = "calendar",
		name = "Calendar view",
		where = ":ZortexCalendar",
		config = "ui.calendar.keymaps",
		keys = {
			{ nil, "prev_day", "previous day" },
			{ nil, "next_day", "next day" },
			{ nil, "prev_week", "previous week" },
			{ nil, "next_week", "next week" },
			{ nil, "prev_month", "previous month" },
			{ nil, "next_month", "next month" },
			{ nil, "prev_year", "previous year" },
			{ nil, "next_year", "next year" },
			{ nil, "today", "today" },
			{ nil, "add_entry", "add an entry to the day" },
			{ nil, "view_entries", "open the day in the calendar note" },
			{ nil, "toggle_task", "tick a task of the day (2x: task 2)" },
			{ nil, "search", "search the entries" },
			{ nil, "go_to_file", "open the calendar note" },
			{ nil, "sync_notifications", "send the notifications to the server" },
			{ nil, "refresh", "refresh" },
			{ nil, "help", "these keys" },
			{ nil, "close", "close" },
		},
	},
	{
		id = "toc",
		name = "Table of contents",
		where = ":ZortexTOC",
		keys = {
			{ "<CR>", "jump", "jump to the section" },
			{ "q", "close", "close" },
			{ "<Esc>", "close", "close" },
		},
	},
	{
		id = "xp",
		name = "XP",
		where = ":ZortexXP",
		keys = {
			{ "<CR>", "open", "open the project, award, objective or area on the line" },
			{ "e", "explain", "how the project on the line earned its XP" },
			{ "g", "guide", "how XP is calibrated (:ZortexXPGuide)" },
			{ "r", "refresh", "refresh" },
			{ "q", "close", "close" },
			{ "<Esc>", "close", "close" },
			{ "?", "help", "these keys" },
		},
	},
	{
		id = "xp_guide",
		name = "XP guide",
		where = ":ZortexXPGuide",
		keys = {
			{ "g", "overview", "back to the XP overview (:ZortexXP)" },
			{ "q", "close", "close" },
			{ "<Esc>", "close", "close" },
			{ "?", "help", "these keys" },
		},
	},
	{
		id = "preview",
		name = "Link preview",
		where = "<leader>zK",
		keys = {
			{ "<CR>", "open", "open the target" },
			{ "q", "close", "close" },
			{ "<Esc>", "close", "close" },
		},
	},
}

M.PICKERS = {
	{
		id = "search",
		name = "Search",
		where = ":ZortexSearch",
		config = "ui.search.keys",
		-- the search service's own copy of ui.search (services/search.setup)
		get = function()
			local search = require("zortex.services.search")
			return ((search.config or search.setup()) or {}).keys
		end,
		keys = {
			{ nil, "new_note", "a new note named after the query", "new note" },
			{ nil, "cycle_mode", "cycle section / article / text search", "mode" },
			{ nil, "narrow", "search inside the section under the cursor (every line, no cap); type on after the prompt", "narrow" },
			{ nil, "widen", "back out of the last narrowing", "widen" },
		},
	},
	{
		id = "projects",
		name = "Projects",
		where = ":ZortexProjects",
		keys = {
			{ "<C-l>", "insert_link", "insert the project's link", "link" },
			{ "<C-y>", "yank_link", "yank the project's link", "yank" },
			{ "<M-s>", "sort", "cycle the sort order", "sort" },
			{ "<M-d>", "done", "show / hide done projects", "done" },
			{ "<M-e>", "leaf", "leaf projects only / all", "leaf" },
		},
	},
	{
		id = "follow",
		name = "Follow link",
		where = "gx on a link that finds several",
		keys = {
			{ "<C-l>", "goto_line", "go to the link's line", "line" },
		},
	},
}

--- Each picker backend's own key for its help (its keys, and ours).
M.PICKER_HELP = {
	telescope = "<C-/>",
	snacks = "?",
	fzf_lua = "<F1>",
}
M.PICKER_HELP_TEXT = "telescope `<C-/>` (insert mode; `?` in normal mode), snacks.picker `?` (normal mode), fzf-lua `<F1>`"

local function find(list, id)
	for _, x in ipairs(list) do
		if x.id == id then
			return x
		end
	end
end

local function config_table(path, defaults)
	local Config = require("zortex.config")
	local t = defaults and Config.defaults or Config
	for part in path:gmatch("[^.]+") do
		t = type(t) == "table" and t[part] or nil
	end
	if t == nil and not defaults then
		return config_table(path, true)
	end
	return t or {}
end

--- The keys of buffer or picker `id` as { lhs, action, desc, label }, one
--- per lhs, with configurable keys read from the config (`defaults`: the
--- built-in defaults, for the docs). Keys set to false are left out.
function M.of(id, defaults)
	local def = find(M.BUFFERS, id) or find(M.PICKERS, id)
	if not def then
		return {}
	end
	local cfg
	if def.get and not defaults then
		cfg = def.get() or config_table(def.config, true)
	elseif def.config then
		cfg = config_table(def.config, defaults)
	end
	local out = {}
	for _, k in ipairs(def.keys) do
		local lhs = k[1]
		if cfg then
			lhs = cfg[k[2]]
		end
		for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
			if l and l ~= "" then
				out[#out + 1] = { lhs = l, action = k[2], desc = k[3], label = k[4] }
			end
		end
	end
	return out
end

--- The definition (name, where, ...) of a buffer or picker.
function M.def(id)
	return find(M.BUFFERS, id) or find(M.PICKERS, id)
end

--- Map buffer `id`'s keys in `buf` to `handlers[action]` (normal mode); the
--- description is "Zortex <name>: <desc>".
function M.map(buf, id, handlers)
	local def = M.def(id)
	for _, k in ipairs(M.of(id)) do
		local fn = handlers[k.action]
		if fn then
			vim.keymap.set("n", k.lhs, fn, {
				buffer = buf,
				nowait = true,
				silent = true,
				desc = "Zortex " .. def.name:lower() .. ": " .. k.desc,
			})
		end
	end
end

--- The keys of `id` as aligned lines ("  <CR>  put at the calendar cursor"),
--- keys sharing an action on one line ("q <Esc>").
function M.lines(id, defaults)
	local rows, by_action, width = {}, {}, 0
	for _, k in ipairs(M.of(id, defaults)) do
		local row = by_action[k.action]
		if row then
			row[1] = row[1] .. " " .. k.lhs
		else
			row = { k.lhs, k.desc }
			by_action[k.action] = row
			rows[#rows + 1] = row
		end
	end
	for _, r in ipairs(rows) do
		width = math.max(width, vim.fn.strdisplaywidth(r[1]))
	end
	local out = {}
	for _, r in ipairs(rows) do
		out[#out + 1] = "  " .. r[1] .. string.rep(" ", width - vim.fn.strdisplaywidth(r[1]) + 2) .. r[2]
	end
	return out
end

--- Picker keys for a spec: { [lhs] = { desc, label, fn, close?, refresh? } }
--- from `handlers[action] = { fn, close?, refresh? }`.
function M.picker_keys(id, handlers)
	local out = {}
	for _, k in ipairs(M.of(id)) do
		local h = handlers[k.action]
		if h then
			out[k.lhs] = { desc = k.desc:sub(1, 1):upper() .. k.desc:sub(2), label = k.label, fn = h.fn, close = h.close, refresh = h.refresh }
		end
	end
	return out
end

return M
