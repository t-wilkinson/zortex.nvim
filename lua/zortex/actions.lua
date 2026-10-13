-- actions.lua - Every user-facing action, defined once
--
-- Commands (:Zortex<Command>), keymaps (<prefix><key>) and require("zortex")
-- .actions.<id>() are all generated from this list, so names, descriptions
-- and behaviour can't drift apart.
--
-- An action:
--   id        snake_case name: Config.keymaps.mappings key, api.actions.<id>
--   command   command suffix (":Zortex" .. command), nil for keymap-only
--   key       default key(s) after Config.keymaps.prefix, nil for none
--   desc      one line, used for the command and the keymap
--   group     heading for docs and :ZortexHelp
--   run       function(args) where args = { args = string, fargs = {...} },
--             or call(module, fn, ...) for a plain module function
--   nargs, complete   passed to nvim_create_user_command
local M = {}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Zortex" })
end

local function file(getter)
	return function()
		vim.cmd("edit " .. vim.fn.fnameescape(require("zortex.utils.filesystem")[getter]()))
	end
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

local function task_convert()
	local workspace = require("zortex.core.workspace")
	local ctx = workspace.get_doc_context()
	if not ctx then
		return notify("Not a note buffer", vim.log.levels.WARN)
	end
	local _, line = require("zortex.services.tasks").convert_line_to_task(ctx.line)
	if line then
		workspace.set_line(ctx.bufnr, ctx.lnum, line)
	end
end

local function season_start(args)
	local fargs = args and args.fargs or {}
	if #fargs == 0 then
		return require("zortex.services.xp.stats").prompt_start_season()
	end
	local end_date = fargs[2] or os.date("%Y-%m-%d", os.time() + 90 * 86400)
	-- an optional third argument backdates the start: completions dated from
	-- then on count (XP is read off @done dates)
	require("zortex.services.xp.stats").start_season(fargs[1], end_date, fargs[3])
	notify("Started season: " .. fargs[1])
end

local function season_status()
	local status = require("zortex.services.xp.stats").season_status()
	if not status then
		return notify("No active season")
	end
	notify(
		string.format(
			"%s: level %d (%s tier), %d XP, %.0f%% to next%s",
			status.season.name,
			status.level,
			status.current_tier and status.current_tier.name or "no",
			status.xp,
			(status.progress_to_next or 0) * 100,
			status.days_left and string.format(", %d days left", status.days_left) or ""
		)
	)
end

local function season_end()
	local result = require("zortex.services.xp.stats").end_season()
	notify(result and ("Ended season: " .. result.name) or "No active season to end")
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
		"",
		"events (count, avg ms):",
	}
	for event, s in pairs(require("zortex.core.event_bus").get_performance_report()) do
		lines[#lines + 1] = string.format("  %-28s %5d %8.2f", event, s.count, s.avg_time)
	end
	notify(table.concat(lines, "\n"))
end

local function project_progress()
	local updated = require("zortex.services.projects").update_progress(0)
	notify(string.format("Updated @progress on %d projects", updated))
end

-- :ZortexNotificationsSync [force]: unchanged calendars are not re-sent
local function notifications_sync(args)
	local force = args and args.args and vim.trim(args.args) == "force"
	require("zortex.notifications").calendar.sync({
		force = force,
		on_done = function(msg)
			if msg:match("unchanged") then
				msg = msg .. "; nothing sent (:ZortexNotificationsSync force resends)"
			end
			notify(msg)
		end,
	})
end

local function link_index_rebuild()
	require("zortex.core.link_index").rebuild()
	notify("Link index rebuilt")
end

local function log_level(args)
	require("zortex.core.logger").set_level((args and args.args or "INFO"):upper())
end

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
		run = call("zortex.ui.telescope.search", "structural_search"),
	},
	{
		id = "search_articles",
		command = "SearchArticles",
		key = "Z",
		group = "Find",
		desc = "Search article names",
		run = call("zortex.ui.telescope.search", "structural_search", { mode = "article" }),
	},
	{
		id = "projects",
		command = "Projects",
		key = "p",
		group = "Find",
		desc = "Browse projects",
		run = call("zortex.ui.telescope.projects", "projects"),
	},
	{
		id = "toc",
		command = "TOC",
		key = "l",
		group = "Find",
		desc = "Table of contents of this note",
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
		desc = "Links that resolve nowhere (quickfix)",
		run = call("zortex.core.link_index", "broken_links_quickfix"),
	},
	{
		id = "link_index_rebuild",
		command = "LinkIndexRebuild",
		group = "Links",
		desc = "Rebuild the link index from scratch",
		run = link_index_rebuild,
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
		command = "FoldsUpdate",
		key = "r",
		group = "Structure",
		desc = "Recompute folds",
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

	-- Tasks --------------------------------------------------------------------
	{
		id = "task_toggle",
		command = "TaskToggle",
		key = "T",
		group = "Tasks",
		desc = "Toggle the task on this line (makes one if needed)",
		run = call("zortex.services.tasks", "toggle_current_task"),
	},
	{
		id = "task_complete",
		command = "TaskComplete",
		key = "tc",
		group = "Tasks",
		desc = "Complete the task on this line",
		run = call("zortex.services.tasks", "complete_current_task"),
	},
	{
		id = "task_uncomplete",
		command = "TaskUncomplete",
		key = "tu",
		group = "Tasks",
		desc = "Reopen the task on this line",
		run = call("zortex.services.tasks", "uncomplete_current_task"),
	},
	{
		id = "task_convert",
		command = "TaskConvert",
		key = "tt",
		group = "Tasks",
		desc = "Turn this line into a task",
		run = task_convert,
	},
	{
		id = "project_progress",
		command = "ProjectProgress",
		key = "u",
		group = "Tasks",
		desc = "Write @progress(done/total) on project headings in this buffer",
		run = project_progress,
	},

	-- Plan ---------------------------------------------------------------------
	{
		id = "review",
		command = "Review",
		key = "w",
		group = "Plan",
		desc = "Weekly review (optional window in days, default 7)",
		nargs = "?",
		run = function(args)
			require("zortex.ui.review").open({ days = tonumber(args and args.args) })
		end,
	},
	{
		id = "plan",
		command = "Plan",
		key = "m",
		group = "Plan",
		desc = "Plan a day: calendar day (from its template) plus ranked tasks, projects, KRs and areas to put on it",
		nargs = "?",
		run = function(args)
			local date = args and args.args ~= "" and args.args or nil
			require("zortex.ui.planner").open({ date = date })
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
	{
		id = "calendar_digest",
		command = "CalendarDigest",
		key = "Cc",
		group = "Plan",
		desc = "Calendar view with the digest panel",
		run = call("zortex.ui.calendar.view", "open_digest"),
	},
	{
		id = "digest",
		command = "Digest",
		key = "Cd",
		group = "Plan",
		desc = "Open the digest note",
		run = call("zortex.services.digest", "open_digest"),
	},
	{
		id = "digest_update",
		command = "DigestUpdate",
		key = "CD",
		group = "Plan",
		desc = "Regenerate the digest note",
		run = call("zortex.services.digest", "force_update"),
	},
	-- Pomodoro (the clock is shared with `zortex serve` when server.enabled) --
	{
		id = "pomodoro_toggle",
		key = "oo",
		group = "Pomodoro",
		desc = "Start, pause or resume the pomodoro",
		run = call("zortex.notifications.types.pomodoro", "toggle"),
	},
	{
		id = "pomodoro_skip",
		key = "os",
		group = "Pomodoro",
		desc = "End the current pomodoro phase now",
		run = call("zortex.notifications.types.pomodoro", "skip"),
	},
	{
		id = "pomodoro_restart",
		key = "or",
		group = "Pomodoro",
		desc = "Begin a new pomodoro cycle",
		run = call("zortex.notifications.types.pomodoro", "restart"),
	},
	{
		id = "pomodoro_stop",
		key = "ox",
		group = "Pomodoro",
		desc = "Stop the pomodoro",
		run = call("zortex.notifications.types.pomodoro", "stop"),
	},
	{
		id = "pomodoro_status",
		key = "oi",
		group = "Pomodoro",
		desc = "Show the pomodoro status",
		run = function()
			notify(require("zortex.notifications.types.pomodoro").describe())
		end,
	},
	{
		id = "notifications_sync",
		command = "NotificationsSync",
		group = "Calendar",
		desc = "Sync calendar notifications (to the server if enabled); `force` resends unchanged",
		run = notifications_sync,
		nargs = "?",
		complete = function()
			return { "force" }
		end,
	},
	{
		id = "ical_import",
		command = "IcalImport",
		group = "Calendar",
		desc = "Import an iCal file or URL into the calendar",
		run = call("zortex.features.ical", "import_interactive"),
	},
	{
		id = "ical_export",
		command = "IcalExport",
		group = "Calendar",
		desc = "Export the calendar to an iCal file",
		run = call("zortex.features.ical", "export_interactive"),
	},

	-- Files --------------------------------------------------------------------
	{
		id = "migrate",
		command = "Migrate",
		group = "Files",
		desc = "Rewrite old-style bold headings (`**Text**`, `**Text**:`) as `**Text:**`",
		run = call("zortex.features.migrate", "run"),
	},
	{
		id = "init",
		command = "Init",
		group = "Files",
		desc = "Create missing key notes (calendar, projects, areas, okr, structure, inbox)",
		run = call("zortex.core.starter", "init_command"),
	},
	{
		id = "open_projects",
		command = "OpenProjects",
		key = { "fp", "P" },
		group = "Files",
		desc = "Open projects.zortex",
		run = file("get_projects_file"),
	},
	{
		id = "open_areas",
		command = "OpenAreas",
		key = "fa",
		group = "Files",
		desc = "Open areas.zortex",
		run = file("get_areas_file"),
	},
	{
		id = "open_okr",
		command = "OpenOKR",
		key = "fo",
		group = "Files",
		desc = "Open okr.zortex",
		run = file("get_okr_file"),
	},
	{
		id = "open_calendar",
		command = "OpenCalendar",
		key = "fc",
		group = "Files",
		desc = "Open calendar.zortex",
		run = file("get_calendar_file"),
	},
	{
		id = "open_structure",
		command = "OpenStructure",
		key = "fs",
		group = "Files",
		desc = "Open structure.zortex",
		run = file("get_structure_file"),
	},
	{
		id = "open_inbox",
		command = "OpenInbox",
		key = "fi",
		group = "Files",
		desc = "Open inbox.zortex",
		run = file("get_inbox_file"),
	},

	-- XP -----------------------------------------------------------------------
	{
		id = "skill_tree",
		command = "SkillTree",
		key = "k",
		group = "XP",
		desc = "Skill tree and season progress",
		run = call("zortex.ui.skill_tree", "show"),
	},
	{
		id = "xp_stats",
		command = "XPStats",
		key = "xs",
		group = "XP",
		desc = "XP statistics",
		run = call("zortex.services.xp.stats", "show_stats"),
	},
	{
		id = "xp_areas",
		command = "XPAreas",
		key = "xa",
		group = "XP",
		desc = "Top areas by XP",
		run = call("zortex.services.xp.stats", "show_area_xp"),
	},
	{
		id = "xp_explain",
		command = "XPExplain",
		key = "xe",
		group = "XP",
		desc = "How the project at the cursor earned its XP",
		run = call("zortex.services.xp.stats", "explain_project"),
	},
	{ id = "season_status", command = "SeasonStatus", group = "XP", desc = "Current season", run = season_status },
	{
		id = "season_start",
		command = "SeasonStart",
		group = "XP",
		desc = "Start a season: [name] [end YYYY-MM-DD] [start YYYY-MM-DD] (prompts without args)",
		nargs = "*",
		run = season_start,
	},
	{ id = "season_end", command = "SeasonEnd", group = "XP", desc = "End the current season", run = season_end },

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
		id = "status",
		command = "Status",
		group = "System",
		desc = "Counts, state directory and event timings",
		run = status,
	},
	{
		id = "logs",
		command = "Logs",
		group = "System",
		desc = "Recent log entries (optional count)",
		nargs = "?",
		run = function(args)
			require("zortex.core.logger").show_logs(tonumber(args and args.args) or 50)
		end,
	},
	{
		id = "log_level",
		command = "LogLevel",
		group = "System",
		desc = "Set the log level",
		nargs = 1,
		complete = function()
			return { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }
		end,
		run = log_level,
	},
	{
		id = "performance",
		command = "Performance",
		group = "System",
		desc = "Timer statistics",
		run = call("zortex.core.logger", "show_performance_report"),
	},
	{
		id = "clear_logs",
		command = "ClearLogs",
		group = "System",
		desc = "Clear logs and timers",
		run = call("zortex.core.logger", "clear_logs"),
	},
	{
		id = "help",
		command = "Help",
		key = "?",
		group = "System",
		desc = "List commands and keys",
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
			-- the pickers are telescope's; say so instead of a module error
			if target.module:find("^zortex%.ui%.telescope") and not pcall(require, "telescope") then
				return notify(
					":Zortex" .. (a.command or a.id) .. " needs telescope.nvim (nvim-telescope/telescope.nvim)",
					vim.log.levels.WARN
				)
			end
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
		if a.command then
			vim.api.nvim_create_user_command(prefix .. a.command, function(args)
				a.run(args)
			end, { desc = a.desc, nargs = a.nargs or 0, complete = a.complete })
		end
	end
end

--- Map <prefix><key> for every action with a key. `mappings` overrides
--- keys by id (a string, a list, or false to unmap).
function M.create_keymaps(prefix, mappings)
	for _, a in ipairs(M.list) do
		for _, key in ipairs(keys_of(a, mappings)) do
			vim.keymap.set("n", prefix .. key, function()
				a.run()
			end, { silent = true, desc = "Zortex: " .. a.desc })
		end
	end
end

--- Lines describing every action (commands and keys), grouped.
function M.help_lines()
	local Config = require("zortex.config")
	local cprefix = Config.commands and Config.commands.prefix or "Zortex"
	local kprefix = Config.keymaps and Config.keymaps.prefix or "<leader>z"
	local mappings = Config.keymaps and Config.keymaps.mappings
	local lines, group = {}, nil
	for _, a in ipairs(M.list) do
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
