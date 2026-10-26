-- actions.lua - Every user-facing action, defined once
--
-- Commands (:Zortex<Command>), keymaps (<prefix><key>) and require("zortex")
-- .actions.<id>() are all generated from this list, so names, descriptions
-- and behaviour can't drift apart.
--
-- An action:
--   id        snake_case name: Config.keymaps.mappings key, api.actions.<id>
--   command   command suffix (":Zortex" .. command; "" for :Zortex itself),
--             nil for keymap-only
--   key       default key(s) after Config.keymaps.prefix, nil for none
--   desc      one line, used for the command and the keymap
--   group     heading for docs and `:Zortex help`
--   run       function(args) where args = { args = string, fargs = {...} },
--             or call(module, fn, ...) for a plain module function
--   nargs, complete, bang   passed to nvim_create_user_command
--   range     true: the command takes a range and the key works on a
--             visual selection too; run gets { range, line1, line2 }
local M = {}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Zortex" })
end

-- The key notes by name, for :ZortexOpen (any other name is <name>.zortex)
local KEY_NOTES = {
	calendar = "get_calendar_file",
	projects = "get_projects_file",
	areas = "get_areas_file",
	okr = "get_okr_file",
	structure = "get_structure_file",
	inbox = "get_inbox_file",
	reviews = "get_reviews_file",
}

--- :ZortexOpen [note]: a note by its file name, without the extension
--- (projects, calendar, z/garden); the structure note without one.
local function open_note(name)
	local fs = require("zortex.utils.filesystem")
	local Config = require("zortex.config")
	name = vim.trim(name or "")
	if name == "" then
		name = "structure"
	end
	local getter = KEY_NOTES[name:lower()]
	local path = getter and fs[getter]()
		or fs.joinpath(
			Config.notes_dir,
			name:sub(-#Config.extension) == Config.extension and name or (name .. Config.extension)
		)
	vim.cmd("edit " .. vim.fn.fnameescape(path))
end

-- Completion for :ZortexOpen: every note's file name, without the extension
local function note_names(lead)
	local Config = require("zortex.config")
	local root = vim.fn.fnamemodify(Config.notes_dir, ":p")
	local seen, out = {}, {}
	local function add(n)
		if not seen[n] and n:sub(1, #lead) == lead then
			seen[n] = true
			out[#out + 1] = n
		end
	end
	for name in pairs(KEY_NOTES) do
		add(name)
	end
	for _, path in ipairs(require("zortex.core.notes").files()) do
		add(path:sub(#root + 1):gsub("%" .. Config.extension .. "$", ""))
	end
	table.sort(out)
	return out
end

-- Subcommands: { name = { desc, run(rest_fargs, args) } } -> run(args) and
-- complete(lead, cmdline) for an action. The first one is the default.
local function subcommands(list)
	local by = {}
	for _, s in ipairs(list) do
		by[s[1]] = s
	end
	local function run(args)
		local fargs = vim.deepcopy(args and args.fargs or {})
		local name = table.remove(fargs, 1) or list[1][1]
		local s = by[name]
		if not s then
			local names = vim.tbl_map(function(x)
				return x[1]
			end, list)
			return notify("Unknown: " .. name .. " (" .. table.concat(names, ", ") .. ")", vim.log.levels.WARN)
		end
		return s[3](fargs, args or {})
	end
	local function complete(lead, cmdline)
		local words = vim.split(vim.trim(cmdline), "%s+")
		if #words > 2 or (#words == 2 and lead == "") then
			local s = by[words[2]]
			return s and s[4] and s[4](lead) or {}
		end
		return vim.tbl_filter(
			function(c)
				return c:sub(1, #lead) == lead
			end,
			vim.tbl_map(function(x)
				return x[1]
			end, list)
		)
	end
	local descs = vim.tbl_map(function(x)
		return "`" .. x[1] .. "` " .. x[2]
	end, list)
	return run, complete, table.concat(descs, ", ")
end

-- run = call(module, fn, ...): calls require(module)[fn](...). The target is
-- kept on the action (action.target) so tests can check it exists.
local function call(module, fn, ...)
	return { module = module, fn = fn, args = { ... } }
end

-- =============================================================================
-- Implementations that are more than one call
-- =============================================================================

-- Links into the section under the cursor -> quickfix
local function backlinks()
	local doc = require("zortex.core.document").from_buffer(0)
	if not doc or not doc.filepath then
		return notify("Not a note buffer", vim.log.levels.WARN)
	end
	local node = doc:node_at(vim.api.nvim_win_get_cursor(0)[1])
	local s, e = 1, #doc.lines
	if not node:is_root() then
		s, e = node.start_line, node.end_line
	end
	local refs = require("zortex.core.link_index").references(doc.filepath, s, e)
	if #refs == 0 then
		return notify("No links point here")
	end
	local items = {}
	for _, ref in ipairs(refs) do
		items[#items + 1] = { filename = ref.file, lnum = ref.lnum, col = ref.col, text = ref.text }
	end
	local title = node:is_root() and vim.fn.fnamemodify(doc.filepath, ":t") or node:get_breadcrumb(" › ")
	vim.fn.setqflist({}, "r", { title = "Backlinks: " .. title, items = items })
	vim.cmd("copen")
end

-- :ZortexSeason start [span] [name…]: prompts without a span. The span
-- may start in the past: completions dated from its start on count.
local function season_start(args)
	local fargs = args and args.fargs or {}
	local stats = require("zortex.services.xp.stats")
	if #fargs == 0 then
		return stats.prompt_start_season()
	end
	local season, err = stats.start_season(fargs[1], table.concat(vim.list_slice(fargs, 2), " "))
	if not season then
		return notify(err, vim.log.levels.WARN)
	end
	notify(string.format("%s started: %s to %s", season.name, season.start_date, season.end_date))
end

local function season_status()
	local status = require("zortex.services.xp.stats").season_status()
	if not status then
		return notify("No active season")
	end
	notify(
		string.format(
			"%s: %.0f%% of its %d objectives%s%s%s",
			status.season.name,
			status.progress * 100,
			#status.objectives,
			status.tier and (", " .. status.tier.name) or "",
			status.next_tier and string.format(", %s at %.0f%%", status.next_tier.name, status.next_tier.at * 100) or "",
			status.days_left and string.format(", %d days left", status.days_left) or ""
		)
	)
end

local function season_end()
	local result, why = require("zortex.services.xp.stats").end_season()
	notify(result and ("Ended season: " .. result.name) or ("Nothing to end: " .. (why or "no season")))
end

local function export(args)
	local dir, count = require("zortex.query").export(args and args.args ~= "" and vim.fn.expand(args.args) or nil)
	notify(string.format("Exported %d notes to %s", count, dir))
end

local function status()
	local Config = require("zortex.config")
	local function count(fn)
		local ok, list = pcall(fn)
		return ok and #list or "?"
	end
	local lines = {
		"Zortex status",
		"",
		"notes_dir     " .. Config.notes_dir,
		"notes         " .. count(require("zortex.core.notes").files),
		"projects      " .. count(require("zortex.services.projects").all),
		"areas         " .. count(require("zortex.services.areas").all),
		"objectives    " .. count(require("zortex.services.okr").objectives),
		"broken links  " .. count(require("zortex.core.link_index").unresolved),
		"state         " .. require("zortex.core.state").path(""):gsub("%.json$", ""),
		"device state  " .. require("zortex.core.state").device_dir(),
		"",
		"events (count, avg ms):",
	}
	for event, s in pairs(require("zortex.core.event_bus").get_performance_report()) do
		lines[#lines + 1] = string.format("  %-28s %5d %8.2f", event, s.count, s.avg_time)
	end
	notify(table.concat(lines, "\n"))
end

-- :ZortexDebug [status|logs [n]|level LEVEL|timers|clear]
local function debug_cmd(args)
	local words = vim.split(vim.trim(args and args.args or ""), "%s+", { trimempty = true })
	local sub, rest = words[1] or "status", words[2]
	local logger = require("zortex.core.logger")
	if sub == "status" then
		status()
	elseif sub == "logs" then
		logger.show_logs(tonumber(rest) or 50)
	elseif sub == "level" then
		logger.set_level((rest or "INFO"):upper())
	elseif sub == "timers" then
		logger.show_performance_report()
	elseif sub == "clear" then
		logger.clear_logs()
	else
		notify("ZortexDebug: status, logs [n], level LEVEL, timers or clear", vim.log.levels.WARN)
	end
end

-- :ZortexPomodoro [toggle|skip|restart|stop|status|settings key=value…]
local POMODORO_RUN, POMODORO_COMPLETE, POMODORO_DESC = subcommands({
	{
		"toggle",
		"start, pause or resume (default)",
		function()
			require("zortex.notifications.pomodoro").toggle()
		end,
	},
	{
		"skip",
		"end the phase now",
		function()
			require("zortex.notifications.pomodoro").skip()
		end,
	},
	{
		"restart",
		"begin a new cycle",
		function()
			require("zortex.notifications.pomodoro").restart()
		end,
	},
	{
		"stop",
		"stop it",
		function()
			require("zortex.notifications.pomodoro").stop()
		end,
	},
	{
		"status",
		"where it is",
		function()
			require("zortex.notifications.pomodoro").show_status()
		end,
	},
	{
		"settings",
		"show or change them: work=25 short=5 long=15 every=4 auto_break=yes auto_work=no",
		function(fargs)
			require("zortex.notifications.pomodoro").settings(fargs)
		end,
		function()
			return { "work=", "short=", "long=", "every=", "auto_break=", "auto_work=" }
		end,
	},
})

-- :ZortexNotifications [list|sync [force]|send <title> <message>]
local NOTIFICATIONS_RUN, NOTIFICATIONS_COMPLETE, NOTIFICATIONS_DESC = subcommands({
	{
		"list",
		"the ones the server will send (default)",
		function()
			require("zortex.notifications").show_list()
		end,
	},
	{
		"sync",
		"send the calendar's to the server now (`force` resends unchanged)",
		function(fargs)
			require("zortex.notifications").sync_now(fargs[1] == "force")
		end,
		function()
			return { "force" }
		end,
	},
	{
		"send",
		"<title> <message>: one now, through the server",
		function(fargs)
			require("zortex.notifications").send(fargs[1], table.concat(vim.list_slice(fargs, 2), " "))
		end,
	},
})

-- :Zortex [help|attributes|init|reindex|refold]
local ZORTEX_RUN, ZORTEX_COMPLETE, ZORTEX_DESC = subcommands({
	{
		"help",
		"list commands and keys (default)",
		function()
			M.show_help()
		end,
	},
	{
		"attributes",
		"what each @attribute means and how it is written",
		function()
			require("zortex.attributes_help").show()
		end,
	},
	{
		"init",
		"create the key notes that are missing (calendar, projects, areas, okr, structure, inbox)",
		function()
			require("zortex.core.starter").init_command()
		end,
	},
	{
		"reindex",
		"rebuild the link index from scratch",
		function()
			require("zortex.core.link_index").rebuild()
			notify("Link index rebuilt")
		end,
	},
	{
		"refold",
		"recompute the folds of this note",
		function()
			require("zortex.features.folding").update_folds(0)
		end,
	},
})

-- =============================================================================
-- The list
-- =============================================================================

M.list = {
	-- Find ---------------------------------------------------------------------
	{
		id = "search",
		command = "Search",
		key = "z",
		group = "Find",
		desc = "Search sections and lines (structural search)",
		run = call("zortex.ui.picker.search", "open"),
	},
	{
		id = "search_articles",
		command = "SearchArticles",
		key = "Z",
		group = "Find",
		desc = "Search article names",
		run = call("zortex.ui.picker.search", "open", { mode = "article" }),
	},
	{
		id = "search_text",
		command = "SearchText",
		key = "/",
		group = "Find",
		desc = "Search plain text in every line (smart case)",
		run = call("zortex.ui.picker.search", "open", { mode = "text" }),
	},
	{
		id = "projects",
		command = "Projects",
		key = "P",
		group = "Find",
		desc = "Browse projects",
		run = call("zortex.ui.picker.projects", "open"),
	},
	{
		id = "toc",
		command = "TOC",
		key = "l",
		group = "Find",
		desc = "Table of contents of this note, in a split that follows the note as you edit and move",
		run = call("zortex.features.toc", "show_toc"),
	},
	{
		id = "toc_popup",
		command = "TOCPopup",
		key = "L",
		group = "Find",
		desc = "Table of contents in a popup",
		run = call("zortex.features.toc", "show_toc_popup"),
	},

	-- Links --------------------------------------------------------------------
	{
		id = "link_open",
		command = "LinkOpen",
		key = "gx",
		group = "Links",
		desc = "Follow the link under the cursor",
		run = call("zortex.features.links", "open_link"),
	},
	{
		id = "link_open_web",
		command = "LinkOpenWeb",
		key = "gX",
		group = "Links",
		desc = "Open the link under the cursor (or this line) in the web app",
		run = call("zortex.features.web", "open_at_cursor"),
	},
	{
		id = "link_preview",
		command = "LinkPreview",
		key = "K",
		group = "Links",
		desc = "Preview the link target in a float",
		run = call("zortex.features.preview", "preview_link"),
	},
	{
		id = "backlinks",
		command = "Backlinks",
		key = "b",
		group = "Links",
		desc = "Links into the section under the cursor (quickfix)",
		run = backlinks,
	},
	{
		id = "broken_links",
		command = "BrokenLinks",
		key = "B",
		group = "Links",
		desc = "Links that resolve nowhere, then tags that go nowhere (quickfix)",
		run = call("zortex.core.link_index", "broken_links_quickfix"),
	},

	-- Structure ----------------------------------------------------------------
	{
		id = "section_next",
		command = "SectionNext",
		key = "]",
		group = "Structure",
		desc = "Next section at the same or higher level",
		run = call("zortex.features.links", "next_section"),
	},
	{
		id = "section_prev",
		command = "SectionPrev",
		key = "[",
		group = "Structure",
		desc = "Previous section at the same or higher level",
		run = call("zortex.features.links", "prev_section"),
	},
	{
		id = "section_parent",
		command = "SectionParent",
		key = "^",
		group = "Structure",
		desc = "Parent section",
		run = call("zortex.features.links", "parent_section"),
	},
	{
		id = "folds_update",
		key = "F",
		group = "Structure",
		desc = "Recompute folds (`:Zortex refold`)",
		run = function()
			require("zortex.features.folding").update_folds(0)
		end,
	},

	{
		id = "archive_section",
		command = "ArchiveSection",
		key = "a",
		group = "Structure",
		desc = "Move the section under the cursor to the note's z/archive file",
		run = call("zortex.features.archive", "archive_current_section"),
	},
	{
		id = "move",
		command = "Move",
		key = "M",
		group = "Structure",
		range = true,
		nargs = "?",
		desc = "Move or rename what is under the cursor (or the selected lines), keeping every link to it: a new title renames a heading or label, a place picked in the search (or a [link]) moves it",
		run = function(args)
			require("zortex.features.move").move_current(args)
		end,
	},
	{
		id = "undo",
		command = "Undo",
		key = "U",
		group = "Structure",
		desc = "Take back the last move, rename or inbox move in every note it changed",
		run = function()
			local label, err = require("zortex.core.workspace").undo_last()
			if not label then
				return notify("Nothing to undo: " .. err, vim.log.levels.WARN)
			end
			notify("Undone: " .. label)
		end,
	},

	-- Tasks --------------------------------------------------------------------
	{
		id = "task_toggle",
		command = "TaskToggle",
		key = "T",
		group = "Tasks",
		desc = "Toggle the task on this line (makes one if needed); on a project heading, mark the project done",
		run = call("zortex.services.tasks", "toggle_current_task"),
	},

	-- Plan ---------------------------------------------------------------------
	{
		id = "review",
		command = "Review",
		key = "R",
		group = "Plan",
		desc = "Review: week (default), day (since the last daily review), or a number of days",
		nargs = "?",
		complete = function()
			return { "day", "week" }
		end,
		run = function(args)
			local a = vim.trim(args and args.args or "")
			if a == "day" then
				return require("zortex.ui.review").open({ scope = "day" })
			end
			require("zortex.ui.review").open({ days = tonumber(a) })
		end,
	},
	{
		id = "review_day",
		key = "r",
		group = "Plan",
		desc = "Daily review (`:ZortexReview day`)",
		run = function()
			require("zortex.ui.review").open({ scope = "day" })
		end,
	},

	{
		id = "plan",
		command = "Plan",
		key = "p",
		group = "Plan",
		desc = "Plan a day: calendar day (from its template) plus ranked tasks, projects, KRs and areas to put on it",
		nargs = "?",
		run = function(args)
			local date = args and args.args ~= "" and args.args or nil
			require("zortex.ui.planner").open({ date = date })
		end,
	},
	{
		id = "today",
		command = "Today",
		key = "d",
		group = "Plan",
		desc = "Go to today in the calendar (or a date), adding the day from its template when it isn't there",
		nargs = "?",
		run = function(args)
			require("zortex.ui.planner").open_day(args and args.args or nil)
		end,
	},
	{
		id = "now",
		command = "Now",
		key = "n",
		group = "Plan",
		desc = "Go to today in the calendar, at the entry for the time now (the latest one that has started)",
		run = call("zortex.features.calendar_time", "goto_now"),
	},
	{
		id = "time_later",
		command = "TimeShift",
		key = "+",
		group = "Plan",
		range = true,
		nargs = "?",
		desc = "Move the times on the line (or the selected lines) later by an offset: 1h30m takes 12:00 to 13:30; -15m moves them earlier",
		run = function(args)
			require("zortex.features.calendar_time").shift(args, 1)
		end,
	},
	{
		id = "time_earlier",
		key = "-",
		group = "Plan",
		range = true,
		desc = "Move the times on the line (or the selected lines) earlier by an offset",
		run = function(args)
			require("zortex.features.calendar_time").shift(args, -1)
		end,
	},
	{
		id = "carry_forward",
		command = "CarryForward",
		key = "Cf",
		group = "Plan",
		desc = "Copy the open tasks of the days before to today (or a date), marking the old lines [>]",
		nargs = "?",
		run = function(args)
			local date = args and args.args ~= "" and args.args or nil
			local moved, added = require("zortex.services.planner").carry_forward(date)
			vim.notify(
				string.format("%d task%s carried, %d copied", moved, moved == 1 and "" or "s", added),
				vim.log.levels.INFO,
				{ title = "Zortex" }
			)
		end,
	},
	{
		id = "calendar",
		command = "Calendar",
		key = "c",
		group = "Plan",
		desc = "Calendar view",
		run = call("zortex.ui.calendar.view", "open"),
	},
	-- Pomodoro (the clock is shared with `zortex serve` when server.enabled) --
	{
		id = "pomodoro_toggle",
		command = "Pomodoro",
		key = "oo",
		group = "Pomodoro",
		desc = "The pomodoro (the clock is the server's): " .. POMODORO_DESC,
		nargs = "*",
		complete = POMODORO_COMPLETE,
		run = POMODORO_RUN,
	},
	{
		id = "pomodoro_skip",
		key = "os",
		group = "Pomodoro",
		desc = "End the current pomodoro phase now (`:ZortexPomodoro skip`)",
		run = call("zortex.notifications.pomodoro", "skip"),
	},
	{
		id = "pomodoro_restart",
		key = "or",
		group = "Pomodoro",
		desc = "Begin a new pomodoro cycle (`:ZortexPomodoro restart`)",
		run = call("zortex.notifications.pomodoro", "restart"),
	},
	{
		id = "pomodoro_stop",
		key = "ox",
		group = "Pomodoro",
		desc = "Stop the pomodoro (`:ZortexPomodoro stop`)",
		run = call("zortex.notifications.pomodoro", "stop"),
	},
	{
		id = "pomodoro_status",
		key = "oi",
		group = "Pomodoro",
		desc = "Show the pomodoro status (`:ZortexPomodoro status`)",
		run = call("zortex.notifications.pomodoro", "show_status"),
	},

	{
		id = "notifications",
		command = "Notifications",
		group = "Calendar",
		desc = "Calendar notifications (sent by the server): " .. NOTIFICATIONS_DESC,
		nargs = "*",
		complete = NOTIFICATIONS_COMPLETE,
		run = NOTIFICATIONS_RUN,
	},

	-- Files --------------------------------------------------------------------

	{
		id = "import_markdown",
		command = "ImportMarkdown",
		group = "Files",
		desc = "Convert a Markdown file, or every one under a folder, to a note next to it (`--join` flows wrapped lines; `!` overwrites)",
		nargs = "*",
		bang = true,
		complete = "file",
		run = function(args)
			require("zortex.features.markdown_import").command(args)
		end,
	},
	{
		id = "conflicts",
		command = "Conflicts",
		group = "Files",
		desc = "Merge a sync tool's conflict copy of a note in a diff beside the note; `done` saves the note and deletes the copy",
		nargs = "?",
		complete = function()
			return { "done" }
		end,
		run = function(args)
			require("zortex.features.conflicts").command(args)
		end,
	},
	{
		id = "open",
		command = "Open",
		group = "Files",
		desc = "Open a note by its file name, without the extension (`projects`, `calendar`, `z/garden`); the structure note without one",
		nargs = "?",
		complete = function(lead)
			return note_names(lead)
		end,
		run = function(args)
			open_note(args and args.args)
		end,
	},
	{
		id = "open_projects",
		key = "fp",
		group = "Files",
		desc = "Open projects.zortex (`:ZortexOpen projects`)",
		run = function()
			open_note("projects")
		end,
	},
	{
		id = "open_areas",
		key = "fa",
		group = "Files",
		desc = "Open areas.zortex (`:ZortexOpen areas`)",
		run = function()
			open_note("areas")
		end,
	},
	{
		id = "open_okr",
		key = "fo",
		group = "Files",
		desc = "Open okr.zortex (`:ZortexOpen okr`)",
		run = function()
			open_note("okr")
		end,
	},
	{
		id = "open_calendar",
		key = "fc",
		group = "Files",
		desc = "Open calendar.zortex (`:ZortexOpen calendar`)",
		run = function()
			open_note("calendar")
		end,
	},
	{
		id = "open_structure",
		key = "fs",
		group = "Files",
		desc = "Open structure.zortex (`:ZortexOpen structure`)",
		run = function()
			open_note("structure")
		end,
	},
	{
		id = "open_inbox",
		key = "fi",
		group = "Files",
		desc = "Open inbox.zortex (`:ZortexOpen inbox`)",
		run = function()
			open_note("inbox")
		end,
	},

	{
		id = "present",
		command = "Present",
		key = "S",
		group = "Files",
		desc = "Present this note as slides in the web app, from the slide under the cursor",
		run = call("zortex.features.present", "present"),
	},

	-- XP -----------------------------------------------------------------------
	{
		id = "xp",
		command = "XP",
		key = "xx",
		group = "XP",
		desc = "Season, the last two weeks, projects in progress, recent awards and the area tree in one view",
		run = call("zortex.ui.xp", "show"),
	},
	{
		id = "xp_explain",
		command = "XPExplain",
		key = "xe",
		group = "XP",
		desc = "How the project at the cursor earned its XP",
		run = call("zortex.services.xp.stats", "explain_project"),
	},
	{
		id = "xp_guide",
		command = "XPGuide",
		key = "xg",
		group = "XP",
		desc = "How XP is calibrated: hours per @size, area XP and season XP, tiers",
		run = call("zortex.ui.xp_guide", "show"),
	},
	{
		id = "season",
		command = "Season",
		group = "XP",
		desc = "The season: `status` (default), `start [span] [name]` (a span like 3M-2026-Q4; without one it asks, the quarter filled in; adds the season's heading to the OKR note), `end`",
		nargs = "*",
		complete = function(lead)
			return vim.tbl_filter(function(c)
				return c:sub(1, #lead) == lead
			end, { "status", "start", "end" })
		end,
		run = function(args)
			local fargs = vim.deepcopy(args and args.fargs or {})
			local sub = table.remove(fargs, 1) or "status"
			if sub == "start" then
				season_start({ fargs = fargs })
			elseif sub == "end" then
				season_end()
			else
				season_status()
			end
		end,
	},

	-- System -------------------------------------------------------------------
	{
		id = "export",
		command = "Export",
		group = "System",
		desc = "Export notes and the model as JSON (default notes_dir/.z/export)",
		nargs = "?",
		complete = "dir",
		run = export,
	},
	{
		id = "debug",
		command = "Debug",
		group = "System",
		desc = "For finding problems: `status` (default; counts, state directory, timings), `logs [n]`, `level <LEVEL>`, `timers`, `clear` (logs and timers)",
		nargs = "*",
		complete = function(lead, cmdline)
			local words = vim.split(vim.trim(cmdline), "%s+")
			if (#words == 2 and lead == "") or #words >= 3 then
				if words[2] == "level" then
					return { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }
				end
				return {}
			end
			return vim.tbl_filter(function(c)
				return c:sub(1, #lead) == lead
			end, { "status", "logs", "level", "timers", "clear" })
		end,
		run = debug_cmd,
	},
	{
		id = "zortex",
		command = "",
		group = "System",
		desc = "Zortex itself: " .. ZORTEX_DESC,
		nargs = "*",
		complete = ZORTEX_COMPLETE,
		run = ZORTEX_RUN,
	},
	{
		id = "help",
		key = "?",
		group = "System",
		desc = "List commands and keys (`:Zortex`)",
		run = function()
			M.show_help()
		end,
	},
}

M.by_id = {}
for _, a in ipairs(M.list) do
	if type(a.run) == "table" then
		local target = a.run
		a.target = target
		a.run = function()
			return require(target.module)[target.fn](unpack(target.args))
		end
	end
	M.by_id[a.id] = a
end

--- Run an action by id.
function M.run(id, args)
	local action = M.by_id[id]
	if not action then
		error("Unknown Zortex action: " .. tostring(id))
	end
	return action.run(args or { args = "", fargs = {} })
end

-- =============================================================================
-- Commands and keymaps
-- =============================================================================

-- An action this setup offers: XP's need xp.enabled
local function offered(action)
	if action.group ~= "XP" then
		return true
	end
	return ((require("zortex.config").xp or {}).enabled ~= false)
end

local function keys_of(action, mappings)
	local key = action.key
	if mappings and mappings[action.id] ~= nil then
		key = mappings[action.id]
	end
	if key == false or key == nil then
		return {}
	end
	return type(key) == "table" and key or { key }
end

--- Create :<prefix><Command> for every action with a command.
function M.create_commands(prefix)
	for _, a in ipairs(M.list) do
		if a.command and offered(a) then
			vim.api.nvim_create_user_command(prefix .. a.command, function(args)
				a.run(args)
			end, { desc = a.desc, nargs = a.nargs or 0, complete = a.complete, range = a.range, bang = a.bang })
		end
	end
end

--- Map <prefix><key> for every action with a key. `mappings` overrides
--- keys by id (a string, a list, or false to unmap).
function M.create_keymaps(prefix, mappings)
	for _, a in ipairs(M.list) do
		for _, key in ipairs(offered(a) and keys_of(a, mappings) or {}) do
			vim.keymap.set("n", prefix .. key, function()
				a.run()
			end, { silent = true, desc = a.desc })
			if a.range then
				vim.keymap.set("x", prefix .. key, function()
					local s, e = vim.fn.line("v"), vim.fn.line(".")
					vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
					a.run({ range = 2, line1 = math.min(s, e), line2 = math.max(s, e) })
				end, { silent = true, desc = a.desc })
			end
		end
	end
end

-- First key of a key sequence: "C" of "Cc", "<C-x>" of "<C-x>y".
local function first_key(key)
	return key:match("^<[^>]+>") or key:sub(1, 1)
end

--- Names for the key prefixes, for which-key: the keymap prefix itself
--- ("Zortex") and every first key that starts a longer mapping ("C" of
--- "Cc"). A prefix is named by `names[key]` if set (false skips it), else
--- by the group of the actions under it. Returns { { lhs, name }, ... }.
function M.key_groups(prefix, mappings, names)
	names = names or {}
	local under, order = {}, {}
	for _, a in ipairs(M.list) do
		for _, key in ipairs(offered(a) and keys_of(a, mappings) or {}) do
			local k = first_key(key)
			if #k < #key then
				if not under[k] then
					under[k] = {}
					order[#order + 1] = k
				end
				if not vim.tbl_contains(under[k], a.group) then
					table.insert(under[k], a.group)
				end
			end
		end
	end
	local out = { { prefix, "Zortex" } }
	for _, k in ipairs(order) do
		local name = names[k]
		if name == nil then
			name = table.concat(under[k], " & ")
		end
		if name then
			out[#out + 1] = { prefix .. k, name }
		end
	end
	return out
end

--- Name the key prefixes in which-key (v3 `add`, or v2 `register`), so
--- <prefix> shows "Zortex" and <prefix>C shows "Calendar". Does
--- nothing when which-key isn't installed. Returns true when registered.
function M.register_which_key(prefix, mappings, names)
	local ok, wk = pcall(require, "which-key")
	if not ok or type(wk) ~= "table" then
		return false
	end
	local groups = M.key_groups(prefix, mappings, names)
	if type(wk.add) == "function" then
		local spec = {}
		for _, g in ipairs(groups) do
			spec[#spec + 1] = { g[1], group = g[2], mode = "n" }
		end
		wk.add(spec)
	elseif type(wk.register) == "function" then
		local spec = {}
		for _, g in ipairs(groups) do
			spec[g[1]] = { name = "+" .. g[2] }
		end
		wk.register(spec, { mode = "n" })
	else
		return false
	end
	return true
end

--- Lines describing every action (commands and keys), grouped.
function M.help_lines()
	local Config = require("zortex.config")
	local cprefix = Config.commands and Config.commands.prefix or "Zortex"
	local kprefix = Config.keymaps and Config.keymaps.prefix or "<leader>z"
	local mappings = Config.keymaps and Config.keymaps.mappings
	local lines, group = {}, nil
	for _, a in ipairs(vim.tbl_filter(offered, M.list)) do
		if a.group ~= group then
			group = a.group
			lines[#lines + 1] = ""
			lines[#lines + 1] = "# " .. group
		end
		local keys = vim.tbl_map(function(k)
			return kprefix .. k
		end, keys_of(a, mappings))
		lines[#lines + 1] = string.format(
			"%-26s %-22s %s",
			a.command and (":" .. cprefix .. a.command) or "",
			table.concat(keys, " "),
			a.desc
		)
	end
	table.remove(lines, 1)
	return lines
end

function M.show_help()
	vim.cmd("new")
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.help_lines())
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	pcall(vim.api.nvim_buf_set_name, buf, "Zortex Help")
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true })
end

return M
