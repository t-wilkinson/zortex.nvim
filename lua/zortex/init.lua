-- init.lua - Main entry point for Zortex
local M = {}

-- =============================================================================
-- Module Loading
-- =============================================================================

-- Core modules
local core = {
	highlights = require("zortex.core.highlights"),
	parser = require("zortex.core.parser"),
	buffer = require("zortex.core.buffer"),
	filesystem = require("zortex.core.filesystem"),
	search = require("zortex.core.search"),
	config = require("zortex.core.config"),
}

-- Feature modules
local modules = {
	notifications = require("zortex.modules.notifications"),
	archive = require("zortex.modules.archive"),
	links = require("zortex.modules.links"),
	progress = require("zortex.modules.progress"),
	projects = require("zortex.modules.projects"),
	calendar = require("zortex.modules.calendar"),
	search = require("zortex.modules.search"),
	skills = require("zortex.modules.skills"),
	xp = require("zortex.modules.xp"),
	xp_notifications = require("zortex.modules.xp_notifications"),
}

-- UI modules
local ui = {
	calendar = require("zortex.ui.calendar"),
	telescope = require("zortex.ui.telescope"),
	skill_tree = require("zortex.ui.skill_tree"),
}

-- =============================================================================
-- User Commands
-- =============================================================================

local function setup_commands(prefix)
	local cmd = vim.api.nvim_create_user_command

	-- ===========================================================================
	-- Notifications
	-- ===========================================================================
	-- Ntfy commands
	cmd(prefix .. "NtfyTest", function()
		local success = modules.notifications.test_ntfy_notification()
		if success then
			vim.notify("Ntfy test notification sent!", vim.log.levels.INFO)
		else
			vim.notify("Failed to send ntfy notification", vim.log.levels.ERROR)
		end
	end, { desc = "Test ntfy notification" })

	-- AWS Notification commands
	cmd(prefix .. "SyncNotifications", function()
		modules.notifications.sync()
	end, { desc = "Sync all notifications to AWS" })

	cmd(prefix .. "TestAWS", function()
		modules.notifications.test_aws_connection()
	end, { desc = "Test AWS notification connection" })

	-- System notifications
	cmd("ZortexNotifyTest", function()
		modules.notifications.test_notification()
	end, { desc = "Test notification system" })

	-- ===========================================================================
	-- Navigation
	-- ===========================================================================
	cmd(prefix .. "Search", function()
		modules.search.search()
	end, { desc = "Hierarchical search across all notes" })
	cmd(prefix .. "OpenLink", function()
		modules.links.open_link()
	end, { desc = "Open link under cursor" })

	-- ===========================================================================
	-- Calendar
	-- ===========================================================================
	cmd(prefix .. "Calendar", function()
		ui.calendar.open()
	end, { desc = "Open Zortex calendar" })
	cmd(prefix .. "CalendarAdd", function()
		ui.calendar.add_entry_interactive()
	end, { desc = "Add calendar entry" })

	-- ===========================================================================
	-- Telescope
	-- ===========================================================================
	cmd(prefix .. "Telescope", function()
		require("telescope").extensions.zortex.zortex()
	end, { desc = "Open Zortex telescope picker" })
	cmd(prefix .. "Today", function()
		ui.telescope.today_digest()
	end, { desc = "Show today's digest" })
	cmd(prefix .. "Projects", function()
		ui.telescope.projects()
	end, { desc = "Browse projects with telescope" })
	cmd(prefix .. "CalendarSearch", function()
		ui.telescope.calendar()
	end, { desc = "Search calendar with telescope" })

	-- ===========================================================================
	-- Project management & archive
	-- ===========================================================================
	cmd(prefix .. "ProjectsOpen", function()
		local proj_path = core.filesystem.get_projects_file()
		if proj_path then
			vim.cmd("edit " .. proj_path)
		end
	end, { desc = "Open projects file" })

	cmd(prefix .. "ProjectsStats", function()
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
	cmd(prefix .. "UpdateProgress", function()
		modules.progress.update_all_progress()
	end, { desc = "Update progress for all projects and OKRs" })

	-- Archive
	cmd(prefix .. "ArchiveProject", function()
		modules.archive.archive_current_project()
	end, { desc = "Archive current project" })

	cmd(prefix .. "ArchiveAllCompleted", function()
		modules.archive.archive_all_completed_projects()
	end, { desc = "Archive all completed projects" })

	-- ===========================================================================
	-- XP & Skill tree
	-- ===========================================================================
	cmd(prefix .. "SkillTree", function()
		ui.skill_tree.show()
	end, { desc = "Show skill tree and season progress" })

	-- XP system info
	cmd(prefix .. "XPInfo", function()
		modules.xp_notifications.show_xp_overview()
	end, {
		desc = "Show XP system overview",
	})

	-- ===========================================================================
	-- Season management
	-- ===========================================================================
	cmd(prefix .. "StartSeason", function(opts)
		local args = vim.split(opts.args, " ")
		if #args < 2 then
			vim.notify("Usage: ZortexStartSeason <name> <end-date YYYY-MM-DD>", vim.log.levels.ERROR)
			vim.notify("Example: ZortexStartSeason Q1-2024 2024-03-31", vim.log.levels.INFO)
			return
		end

		local name = args[1]
		local end_date = args[2]
		modules.xp.start_season(name, end_date)
	end, { nargs = "*", desc = "Start a new season" })

	cmd(prefix .. "EndSeason", function()
		modules.xp.end_season()
	end, { desc = "End the current season" })

	cmd(prefix .. "SeasonStatus", function()
		local status = modules.xp.get_season_status()
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
	cmd(prefix .. "ToggleTask", function()
		modules.progress.toggle_current_task()
	end, { desc = "Toggle the task on current line" })
	cmd(prefix .. "CompleteTask", function()
		modules.progress.complete_current_task()
	end, { desc = "Complete the task on current line" })
	cmd(prefix .. "UncompleteTask", function()
		modules.progress.uncomplete_current_task()
	end, { desc = "Uncomplete the task on current line" })
end

-- =============================================================================
-- Keymaps
-- =============================================================================

local function setup_keymaps(key_prefix, cmd_prefix)
	local opts = { noremap = true, silent = true }
	local function add_opts(with_opts)
		return vim.tbl_extend("force", opts, with_opts)
	end

	local map = vim.keymap.set

	-- Navigation
	map("n", key_prefix .. "s", "<cmd>" .. cmd_prefix .. "Search<CR>", add_opts({ desc = "Zortex search" }))
	map("n", "gx", "<cmd>" .. cmd_prefix .. "OpenLink<CR>", add_opts({ desc = "Open Zortex link" }))
	-- map("n", "<CR>", "<cmd>" .. cmd_prefix .. "OpenLink<CR>", add_opts({ desc = "Open Zortex link" }))

	-- Calendar
	map("n", key_prefix .. "c", "<cmd>" .. cmd_prefix .. "Calendar<cr>", { desc = "Open calendar" })
	map("n", key_prefix .. "A", "<cmd>" .. cmd_prefix .. "CalendarAdd<cr>", { desc = "Add calendar entry" })

	-- Telescope
	map("n", key_prefix .. "t", "<cmd>" .. cmd_prefix .. "Today<cr>", { desc = "Today's digest" })
	map("n", key_prefix .. "p", "<cmd>" .. cmd_prefix .. "Projects<cr>", { desc = "Browse projects" })
	map("n", key_prefix .. "f", "<cmd>" .. cmd_prefix .. "Telescope<cr>", { desc = "Zortex telescope" })

	-- Projects
	map("n", key_prefix .. "P", ":ZortexProjectsOpen<CR>", add_opts({ desc = "Open projects" }))
	map("n", key_prefix .. "a", "<cmd>" .. cmd_prefix .. "ArchiveProject<CR>", add_opts({ desc = "Archive project" }))
	map("n", key_prefix .. "x", "<cmd>" .. cmd_prefix .. "ToggleTask<CR>", add_opts({ desc = "Complete current task" }))

	-- Progress
	map("n", key_prefix .. "u", "<cmd>" .. cmd_prefix .. "UpdateProgress<cr>", { desc = "Update progress" })

	-- XP System
	map("n", key_prefix .. "k", "<cmd>" .. cmd_prefix .. "SkillTree<CR>", add_opts({ desc = "Show skill tree" }))
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
				modules.progress.update_project_progress(args.buf)
				modules.progress.update_okr_progress()
			elseif filename == "okr.zortex" then
				modules.progress.update_okr_progress()
			elseif filename == "calendar.zortex" then
				-- Reload calendar on save
				modules.calendar.load()
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
	modules.notifications.setup(config.notifications)
	-- modules.projects.load() -- Not sure if this is necessary

	core.highlights.setup_autocmd()
	core.highlights.setup_highlights()

	-- Setup autocmds, keymaps, and autocmds
	setup_commands(config.commands.prefix)
	setup_keymaps(config.keymaps.prefix, config.commands.prefix)
	setup_autocmds()

	-- Random seed for generating ids
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
M.search = modules.search.search
M.open_link = modules.links.open_link
M.calendar = ui.calendar.open
M.projects = ui.telescope.projects

M.modules = modules
M.ui = ui
M.core = core

return M
