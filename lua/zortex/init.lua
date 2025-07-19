-- init.lua - Main entry point for Zortex
local M = {}

-- =============================================================================
-- Module Loading
-- =============================================================================

-- Core modules
local core = {
	config = require("zortex.config"),
	constants = require("zortex.constants"),
	attributes = require("zortex.core.attributes"),
	buffer = require("zortex.core.buffer"),
	datetime = require("zortex.core.datetime"),
	filesystem = require("zortex.core.filesystem"),
	parser = require("zortex.core.parser"),
}

local features = {
	-- archive = require("zortex.features.archive"),
	calendar = require("zortex.features.calendar"),
	completion = require("zortex.features.completion"),
	highlights = require("zortex.features.highlights"),
	links = require("zortex.features.links"),
	notifications = require("zortex.features.notifications"),
}

local models = {
	task = require("zortex.models.task"),
}

local modules = {
	areas = require("zortex.modules.areas"),
	objectives = require("zortex.modules.objectives"),
	progress = require("zortex.modules.progress"),
	projects = require("zortex.modules.projects"),
	tasks = require("zortex.modules.tasks"),
}

local stores = {
	areas = require("zortex.stores.areas"),
	base = require("zortex.stores.base"),
	tasks = require("zortex.stores.tasks"),
	xp = require("zortex.stores.xp"),
}

local ui = {
	calendar = require("zortex.ui.calendar"),
	projects = require("zortex.ui.projects"),
	search = require("zortex.ui.search"),
	skill_tree = require("zortex.ui.skill_tree"),
	telescope = require("zortex.ui.telescope"),
}

local xp = {
	areas = require("zortex.xp.areas"),
	core = require("zortex.xp.core"),
	notifications = require("zortex.xp.notifications"),
	projects = require("zortex.xp.projects"),
}

-- =============================================================================
-- User Commands
-- =============================================================================

local function setup_commands(prefix)
	local function cmd(name, command, options)
		vim.api.nvim_create_user_command(prefix .. name, command, options)
	end

	-- ===========================================================================
	-- Notifications
	-- ===========================================================================
	cmd("SyncNotifications", function()
		features.notifications.sync()
	end, { desc = "Sync notification manifest to AWS handler" })

	-- Test notifications
	cmd("TestNotifications", function()
		features.notifications.test_notifications_ete()
	end, { desc = "Test notifications end to end" })
	cmd("TestSystemNotifications", function()
		features.notifications.test_notification()
	end, { desc = "Test notification system" })
	cmd("TestNtfy", function()
		local success = features.notifications.test_ntfy_notification()
		if success then
			vim.notify("Ntfy test notification sent!", vim.log.levels.INFO)
		else
			vim.notify("Failed to send ntfy notification", vim.log.levels.ERROR)
		end
	end, { desc = "Test ntfy notification" })
	cmd("TestAWS", function()
		features.notifications.test_aws_connection()
	end, { desc = "Test AWS notification connection" })

	-- ===========================================================================
	-- Navigation
	-- ===========================================================================
	cmd("OpenLink", function()
		features.links.open_link()
	end, { desc = "Open link under cursor" })
	cmd("Search", function()
		ui.search.search({ search_type = "section" })
	end, { desc = "Section-based search with breadcrumbs" })
	cmd("SearchArticles", function()
		ui.search.search({ search_type = "article" })
	end, { desc = "Article-based search" })
	cmd("SearchSections", function()
		ui.search.search({ search_type = "section" })
	end, { desc = "Section-based search" })

	-- ===========================================================================
	-- Calendar
	-- ===========================================================================
	cmd("Calendar", function()
		ui.calendar.open()
	end, { desc = "Open Zortex calendar" })
	cmd("CalendarAdd", function()
		ui.calendar.add_entry_interactive()
	end, { desc = "Add calendar entry" })

	-- ===========================================================================
	-- Telescope
	-- ===========================================================================
	-- cmd("Telescope", function()
	-- 	require("telescope").extensions.zortex.zortex()
	-- end, { desc = "Open Zortex telescope picker" })
	-- cmd("Today", function()
	-- 	ui.telescope.today_digest()
	-- end, { desc = "Show today's digest" })
	-- cmd("Projects", function()
	-- 	ui.telescope.projects()
	-- end, { desc = "Browse projects with telescope" })
	-- cmd("CalendarSearch", function()
	-- 	ui.telescope.calendar()
	-- end, { desc = "Search calendar with telescope" })

	-- ===========================================================================
	-- Project management & archive
	-- ===========================================================================
	cmd("ProjectsOpen", function()
		local proj_path = core.filesystem.get_projects_file()
		if proj_path then
			vim.cmd("edit " .. proj_path)
		end
	end, { desc = "Open projects file" })

	cmd("ProjectsStats", function()
		local stats = modules.projects.get_all_stats()
		print(string.format("Projects: %d", stats.project_count))
		print(string.format("Total tasks: %d", stats.total_tasks))
		print(
			string.format(
				"Completed: %d (%.1f%%)",
				stats.completed_tasks,
				stats.total_tasks > 0 and (stats.completed_tasks / stats.total_tasks * 100) or 0
			)
		)
	end, { desc = "Show project statistics" })

	-- Update all project progress
	cmd("UpdateProgress", function()
		modules.progress.update_all_progress()
	end, { desc = "Update progress for all projects and OKRs" })

	-- Archive
	-- cmd("ArchiveProject", function()
	-- 	features.archive.archive_current_project()
	-- end, { desc = "Archive current project" })

	-- cmd("ArchiveAllCompleted", function()
	-- 	features.archive.archive_all_completed_projects()
	-- end, { desc = "Archive all completed projects" })

	-- ===========================================================================
	-- XP & Skill tree
	-- ===========================================================================
	cmd("SkillTree", function()
		ui.skill_tree.show()
	end, { desc = "Show skill tree and season progress" })

	-- XP system info
	cmd("XPInfo", function()
		xp.notifications.show_xp_overview()
	end, {
		desc = "Show XP system overview",
	})

	-- ===========================================================================
	-- Season management
	-- ===========================================================================
	cmd("StartSeason", function(opts)
		local args = vim.split(opts.args, " ")
		if #args < 2 then
			vim.notify("Usage: ZortexStartSeason <name> <end-date YYYY-MM-DD>", vim.log.levels.ERROR)
			vim.notify("Example: ZortexStartSeason Q1-2024 2024-03-31", vim.log.levels.INFO)
			return
		end

		local name = args[1]
		local end_date = args[2]
		xp.projects.start_season(name, end_date)
	end, { nargs = "*", desc = "Start a new season" })

	cmd("EndSeason", function()
		xp.projects.end_season()
	end, { desc = "End the current season" })

	cmd("SeasonStatus", function()
		local status = xp.projects.get_season_status()
		if status then
			print("Current Season: " .. status.season.name)
			print(
				string.format(
					"Level %d - %s Tier",
					status.level,
					status.current_tier and status.current_tier.name or "None"
				)
			)
			print(string.format("Progress: %.0f%%", status.progress_to_next * 100))
		else
			print("No active season")
		end
	end, { desc = "Show current season status" })

	-- ===========================================================================
	-- Task management
	-- ===========================================================================
	cmd("ToggleTask", function()
		modules.progress.toggle_current_task()
	end, { desc = "Toggle the task on current line" })
	cmd("CompleteTask", function()
		modules.progress.complete_current_task()
	end, { desc = "Complete the task on current line" })
	cmd("UncompleteTask", function()
		modules.progress.uncomplete_current_task()
	end, { desc = "Uncomplete the task on current line" })
end

-- =============================================================================
-- Keymaps
-- =============================================================================

local function setup_keymaps(key_prefix, cmd_prefix)
	local default_opts = { noremap = true, silent = true }
	local function add_opts(with_opts)
		return vim.tbl_extend("force", default_opts, with_opts)
	end

	local map = function(modes, key, cmd, opts)
		vim.keymap.set(modes, key_prefix .. key, "<cmd>" .. cmd_prefix .. cmd .. "<cr>", opts)
	end

	-- Navigation
	map("n", "s", "Search", add_opts({ desc = "Zortex search" }))
	map("n", "gx", "OpenLink", add_opts({ desc = "Open Zortex link" }))
	-- map("n", "<CR>", "OpenLink", add_opts({ desc = "Open Zortex link" }))

	-- Calendar
	map("n", "c", "Calendar", { desc = "Open calendar" })
	map("n", "A", "CalendarAdd", { desc = "Add calendar entry" })

	-- Telescope
	map("n", "t", "Today", { desc = "Today's digest" })
	map("n", "p", "Projects", { desc = "Browse projects" })
	map("n", "f", "Telescope", { desc = "Zortex telescope" })

	-- Projects
	map("n", "P", "ProjectsOpen", add_opts({ desc = "Open projects" }))
	map("n", "a", "ArchiveProject", add_opts({ desc = "Archive project" }))
	map("n", "x", "ToggleTask", add_opts({ desc = "Complete current task" }))

	-- Progress
	map("n", "u", "UpdateProgress", { desc = "Update progress" })

	-- XP System
	map("n", "k", "SkillTree", add_opts({ desc = "Show skill tree" }))
end

-- =============================================================================
-- Autocmds
-- =============================================================================

local function setup_autocmds()
	local group = vim.api.nvim_create_augroup("Zortex", { clear = true })
	-- Progress tracking
	vim.api.nvim_create_autocmd("BufWritePre", {
		pattern = "*.zortex",
		callback = function(args)
			local filename = vim.fn.expand("%:t")

			if filename == "projects.zortex" then
				modules.projects.update_project_progress(args.buf)
				modules.objectives.update_okr_progress()
			elseif filename == "okr.zortex" then
				modules.objectives.update_okr_progress()
			elseif filename == "calendar.zortex" then
				-- Reload calendar on save
				features.calendar.load()
			end
		end,
		group = group,
	})

	-- Save XP state on exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		pattern = "*",
		callback = function()
			modules.xp.save_state()
		end,
		group = group,
	})
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup(opts)
	-- Initialize modules
	local config = core.config.setup(opts)

	-- Call setup functions
	-- ui.telescope.setup()
	ui.calendar.setup(config.ui.calendar)

	modules.xp.setup(config.xp)
	features.notifications.setup(config.notifications)
	-- modules.projects.load() -- Not sure if this is necessary

	core.highlights.setup_autocmd()
	core.highlights.setup_highlights()

	-- Setup autocmds, keymaps, and autocmds
	setup_commands(config.commands.prefix)
	setup_keymaps(config.keymaps.prefix, config.commands.prefix)
	setup_autocmds()

	-- Random seed for generating task ids
	if not _G.__id_rng_seeded then
		local bit = require("bit")
		local seed = bit.bxor(vim.loop.hrtime(), os.time(), vim.loop.getpid())
		math.randomseed(seed)
		_G.__id_rng_seeded = true -- guard against multiple seeds
	end

	-- Completion
	local cmp = require("cmp")
	local zortex_completion = require("zortex.modules.completion")
	cmp.register_source("zortex", zortex_completion.new())
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Re-export commonly used functions
M.search = ui.search.search
M.open_link = features.links.open_link
M.calendar = ui.calendar.open

M.modules = modules
M.features = features
M.models = models
M.stores = stores
M.ui = ui
M.core = core
M.xp = xp

return M
