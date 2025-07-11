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
local ui = require("zortex.ui")

-- =============================================================================
-- User Commands
-- =============================================================================

local function setup_commands()
	local cmd = vim.api.nvim_create_user_command
	local prefix = "Zortex"

	-- Navigation
	cmd(prefix .. "Search", function()
		modules.search.search()
	end, { desc = "Hierarchical search across all notes" })
	cmd(prefix .. "OpenLink", function()
		modules.links.open_link()
	end, { desc = "Open link under cursor" })

	-- Calendar
	cmd(prefix .. "Calendar", function()
		ui.calendar.open()
	end, { desc = "Open Zortex calendar" })
	cmd(prefix .. "CalendarAdd", function()
		ui.calendar.add_entry_interactive()
	end, { desc = "Add calendar entry" })

	-- Telescope
	cmd("ZortexTelescope", function()
		require("telescope").extensions.zortex.zortex()
	end, { desc = "Open Zortex telescope picker" })
	cmd("ZortexToday", function()
		ui.telescope.today_digest()
	end, { desc = "Show today's digest" })
	cmd("ZortexProjects", function()
		ui.telescope.projects()
	end, { desc = "Browse projects with telescope" })
	cmd("ZortexCalendarSearch", function()
		ui.telescope.calendar()
	end, { desc = "Search calendar with telescope" })

	-- Projects
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

	-- Archive
	cmd(prefix .. "ArchiveProject", function()
		modules.archive.archive_current_project()
	end, { desc = "Archive current project" })

	cmd(prefix .. "ArchiveAllCompleted", function()
		modules.archive.archive_all_completed_projects()
	end, { desc = "Archive all completed projects" })

	-- Progress
	cmd(prefix .. "UpdateProgress", function()
		modules.progress.update_all_progress()
	end, { desc = "Update progress for all projects and OKRs" })

	-- Skill tree
	cmd(prefix .. "SkillTree", function()
		ui.skill_tree.show()
	end, { desc = "Show skill tree and season progress" })

	-- Season management
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

	-- Task completion
	cmd(prefix .. "ToggleTask", function()
		modules.progress.toggle_current_task()
	end, { desc = "Toggle the task on current line" })
	cmd(prefix .. "CompleteTask", function()
		modules.progress.complete_current_task()
	end, { desc = "Complete the task on current line" })
	cmd(prefix .. "UncompleteTask", function()
		modules.progress.uncomplete_current_task()
	end, { desc = "Uncomplete the task on current line" })

	-- XP notifications
	cmd(prefix .. "PreviewTaskXP", modules.xp_notifications.preview_task_xp, {
		desc = "Preview XP for completing current task",
	})

	cmd(prefix .. "PreviewProjectXP", modules.xp_notifications.preview_project_xp, {
		desc = "Preview XP for completing current project",
	})

	-- XP system info
	cmd(prefix .. "XPInfo", function()
		modules.xp_notifications.show_xp_overview()
	end, {
		desc = "Show XP system overview",
	})

	-- Area XP management
	cmd(prefix .. "AddAreaXP", function(opts)
		local args = vim.split(opts.args, " ")
		if #args < 2 then
			vim.notify("Usage: ZortexAddAreaXP <area_path> <xp_amount>", vim.log.levels.ERROR)
			return
		end

		local path = args[1]
		local xp_amount = tonumber(args[2])
		if not xp_amount then
			vim.notify("Invalid XP amount", vim.log.levels.ERROR)
			return
		end

		modules.xp.add_area_xp(path, xp_amount, nil)
		vim.notify(string.format("Added %d XP to %s", xp_amount, path), vim.log.levels.INFO)
	end, { nargs = "+", desc = "Manually add XP to an area" })

	cmd(prefix .. "AreaStats", function()
		local stats = modules.xp.get_area_stats()
		print("Area Statistics:")
		print("================")
		for path, data in pairs(stats) do
			print(string.format("%s - Level %d (%d XP)", path, data.level, data.xp))
		end
	end, { desc = "Show area XP statistics" })

	-- Project info
	cmd(prefix .. "ProjectInfo", function()
		local project = core.buffer.find_current_project()
		if not project then
			vim.notify("Not in a project", vim.log.levels.WARN)
			return
		end

		local stats = modules.xp.get_project_stats()
		if stats[project] then
			local s = stats[project]
			print(string.format("Project: %s", project))
			print(string.format("XP earned: %d", s.xp))
			print(string.format("Tasks: %d/%d (%.0f%%)", s.completed_tasks, s.total_tasks, s.completion_rate * 100))
		else
			print("No stats for this project yet")
		end
	end, { desc = "Show project statistics" })
end

--[[
	-- Notification commands
	cmd("ZortexNotifySetup", function()
		local count = features.notifications.setup_notifications()
		vim.notify(string.format("Scheduled %d notifications", count), vim.log.levels.INFO)
	end, { desc = "Setup calendar notifications" })

	cmd("ZortexNotifyTest", function()
		features.notifications.test_notification()
	end, { desc = "Test notification system" })

	-- Skills commands (if module available)
	if features.skills then
		cmd("ZortexSkillsTree", function()
			if ui.skills_tree then
				ui.skills_tree.open()
			else
				vim.notify("Skills tree UI not available", vim.log.levels.WARN)
			end
		end, { desc = "Open skills tree" })
]]

-- =============================================================================
-- Keymaps
-- =============================================================================

local function setup_keymaps()
	local opts = { noremap = true, silent = true }
	local function add_opts(with_opts)
		return vim.tbl_extend("force", opts, with_opts)
	end

	local prefix = "<leader>z"
	local map = vim.keymap.set

	-- Navigation
	map("n", prefix .. "s", ":ZortexSearch<CR>", add_opts({ desc = "Zortex search" }))
	map("n", "gx", "<cmd>ZortexOpenLink<CR>", add_opts({ desc = "Open Zortex link" }))
	-- map("n", "<CR>", "<cmd>ZortexOpenLink<CR>", add_opts({ desc = "Open Zortex link" }))

	-- Calendar
	map("n", prefix .. "c", "<cmd>ZortexCalendar<cr>", { desc = "Open calendar" })
	map("n", prefix .. "A", "<cmd>ZortexCalendarAdd<cr>", { desc = "Add calendar entry" })

	-- Telescope
	map("n", prefix .. "t", "<cmd>ZortexToday<cr>", { desc = "Today's digest" })
	map("n", prefix .. "p", "<cmd>ZortexProjects<cr>", { desc = "Browse projects" })
	map("n", prefix .. "f", "<cmd>ZortexTelescope<cr>", { desc = "Zortex telescope" })

	-- Projects
	map("n", prefix .. "P", ":ZortexProjectsOpen<CR>", add_opts({ desc = "Open projects" }))
	map("n", prefix .. "a", "<cmd>ZortexArchiveProject<CR>", add_opts({ desc = "Archive project" }))
	map("n", prefix .. "x", "<cmd>ZortexToggleTask<CR>", add_opts({ desc = "Complete current task" }))

	-- Progress
	map("n", prefix .. "u", "<cmd>ZortexUpdateProgress<cr>", { desc = "Update progress" })

	-- XP System
	map("n", prefix .. "k", "<cmd>ZortexSkillTree<CR>", add_opts({ desc = "Show skill tree" }))
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

	-- Auto-load projects and calendar on startup
	vim.api.nvim_create_autocmd("VimEnter", {
		pattern = "*",
		callback = function()
			vim.defer_fn(function()
				modules.projects.load()
				modules.calendar.load()
			end, 100)
		end,
		group = group,
	})
end

--[[

local function setup_autocmds()
	local group = vim.api.nvim_create_augroup("Zortex", { clear = true })

	-- Progress tracking
	features.progress.setup_autocmd()

	-- Auto-save XP state
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			features.xp.save_state()
		end,
	})

	-- Track file access
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		pattern = "*" .. M.config.extension,
		callback = function()
			local filepath = vim.api.nvim_buf_get_name(0)
			if filepath and filepath ~= "" then
				local search_managers = require("zortex.features.search_managers")
				search_managers.AccessTracker.record(filepath)
			end
		end,
	})

	-- Setup notifications on startup
	vim.api.nvim_create_autocmd("VimEnter", {
		group = group,
		once = true,
		callback = function()
			vim.defer_fn(function()
				features.notifications.setup_notifications()
			end, 1000)
		end,
	})
end



function M.setup_autocmds()
	local group = vim.api.nvim_create_augroup("Zortex", { clear = true })

	-- Progress tracking
	vim.api.nvim_create_autocmd("BufWritePre", {
		pattern = "*.zortex",
		callback = function(args)
			local filename = vim.fn.expand("%:t")

			if filename == "projects.zortex" then
				progress.update_project_progress(args.buf)
			elseif filename == "okr.zortex" then
				progress.update_okr_progress(args.buf)
			end
		end,
		group = group,
	})

	-- XP tracking for task completion
	vim.api.nvim_create_autocmd("TextChanged", {
		pattern = "*.zortex",
		callback = function()
			-- Debounced XP tracking could be added here
		end,
		group = group,
	})

	-- Calendar refresh on file changes
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "calendar.zortex",
		callback = function()
			calendar.load()
		end,
		group = group,
	})

	-- Projects refresh on file changes
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "projects.zortex",
		callback = function()
			projects.load()
		end,
		group = group,
	})
end
--]]

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup(opts)
	-- Initialize modules
	core.config.setup(opts)
	modules.xp.setup(core.config.get("xp"))
	ui.setup()
	core.highlights.setup_autocmd()
	core.highlights.setup_highlights()

	-- Setup autocmds, keymaps, and autocmds
	setup_commands()
	setup_keymaps()
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
