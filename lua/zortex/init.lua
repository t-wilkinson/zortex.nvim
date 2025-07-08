-- init.lua - Main entry point for integrated Zortex
local M = {}

local old = {}
old.telescope = require("zortex.old.telescope")
old.calendar = require("zortex.calendar")

-- Core modules
local config = require("zortex.config")
local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")
local core_search = require("zortex.core.search")

-- Feature modules
local xp_config = require("zortex.features.xp_config")
local xp = require("zortex.features.xp")
local archive = require("zortex.features.archive")
local progress = require("zortex.features.progress")
local skills = require("zortex.features.skills")
local links = require("zortex.features.links")
local calendar = require("zortex.features.calendar")
local projects = require("zortex.features.projects")
local search = require("zortex.features.search")

-- UI modules
local skill_tree_ui = require("zortex.ui.skill_tree")

-- =============================================================================
-- Default Configuration
-- =============================================================================

M.defaults = {
	-- Server settings
	zortex_remote_server = "",
	zortex_remote_server_dir = "/www/zortex",
	zortex_remote_wiki_port = "8080",
	zortex_auto_start_server = false,
	zortex_auto_start_preview = true,
	zortex_special_articles = { "structure", "inbox" },
	zortex_auto_close = true,
	zortex_refresh_slow = false,
	zortex_command_for_global = false,
	zortex_open_to_the_world = false,
	zortex_open_ip = "",
	zortex_echo_preview_url = false,
	zortex_browserfunc = "",
	zortex_browser = "",
	zortex_markdown_css = "",
	zortex_highlight_css = "",
	zortex_port = "8080",
	zortex_page_title = "「${name}」",

	-- File settings
	zortex_filetype = "zortex",
	zortex_extension = ".zortex",
	zortex_window_direction = "down",
	zortex_window_width = "40%",
	zortex_window_command = "",
	zortex_preview_direction = "right",
	zortex_preview_width = "",
	zortex_root_dir = vim.fn.expand("$HOME/.zortex") .. "/",
	zortex_notes_dir = vim.fn.expand("$HOME/.zortex") .. "/",

	-- Preview options
	zortex_preview_options = {
		mkit = {},
		katex = {},
		uml = {},
		maid = {},
		disable_sync_scroll = 0,
		sync_scroll_type = "middle",
		hide_yaml_meta = 1,
		sequence_diagrams = {},
		flowchart_diagrams = {},
		content_editable = false,
		disable_filename = 0,
		toc = {},
	},

	-- Feature configurations
	xp = {},
	skills = {},
}

-- =============================================================================
-- Module Setup
-- =============================================================================

function old.setup()
	local cmd = vim.api.nvim_create_user_command

	-- Telescope functions
	cmd("ZortexCalendarSearch", old.telescope.calendar, { desc = "Browse calendar chronologically" })
	cmd("ZortexDigestTelescope", old.telescope.today_digest, { desc = "Show today's digest in Telescope" })
	cmd("ZortexProjects", old.telescope.today_digest, { desc = "Show today's digest in Telescope" })

	-- Create keymaps
	vim.keymap.set("n", "Zc", old.calendar.open, { desc = "Open Zortex Calendar" })

	-- Telescope keymaps
	vim.keymap.set("n", "ZC", old.telescope.calendar, { desc = "Search calendar entries" })
	vim.keymap.set("n", "Zp", old.telescope.projects, { desc = "Search projects" })

	-- Digest
	vim.keymap.set("n", "Zd", old.telescope.today_digest)
	vim.keymap.set("n", "ZD", old.calendar.show_today_digest, {
		desc = "Show Today's Digest",
	})
	vim.keymap.set("n", "ZB", old.calendar.show_digest_buffer)

	old.calendar.setup()
end

function M.setup(opts)
	opts = opts or {}

	-- Merge options with defaults
	local full_opts = vim.tbl_deep_extend("force", M.defaults, opts)

	-- Set vim globals for compatibility
	for k, v in pairs(full_opts) do
		if k:match("^zortex_") then
			vim.g[k] = v
		end
	end

	old.setup()

	-- Initialize configuration system
	config.setup({
		xp = full_opts.xp,
		skills = full_opts.skills,
		ui = full_opts.ui,
		archive = full_opts.archive,
	})

	-- Initialize XP system with configuration
	xp.setup(full_opts.xp)
	xp_config.setup(full_opts.xp)

	-- Load saved data
	xp.load_state()
	calendar.load()
	projects.load()

	-- Set up autocmds
	M.setup_autocmds()

	-- Create user commands
	M.create_commands()

	-- Create keymaps
	M.create_keymaps()

	-- Load telescope extensions if available
	pcall(function()
		local telescope = require("zortex.telescope")
		-- Register telescope commands
	end)
end

-- =============================================================================
-- Autocmds
-- =============================================================================

function M.setup_autocmds()
	local group = vim.api.nvim_create_augroup("Zortex", { clear = true })

	-- Progress tracking
	vim.api.nvim_create_autocmd("BufWritePre", {
		pattern = "*.zortex",
		callback = function(args)
			local filename = vim.fn.expand("%:t")

			if filename == "projects.zortex" then
				progress.update_project_progress(args.buf)
				progress.update_okr_progress()
			elseif filename == "okr.zortex" then
				progress.update_okr_progress()
			elseif filename == "calendar.zortex" then
				-- Reload calendar on save
				calendar.load()
			end
		end,
		group = group,
	})

	-- Save XP state on exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		pattern = "*",
		callback = function()
			xp.save_state()
		end,
		group = group,
	})

	-- Auto-load projects and calendar on startup
	vim.api.nvim_create_autocmd("VimEnter", {
		pattern = "*",
		callback = function()
			vim.defer_fn(function()
				projects.load()
				calendar.load()
			end, 100)
		end,
		group = group,
	})
end

-- =============================================================================
-- User Commands
-- =============================================================================

function M.create_commands()
	local cmd = vim.api.nvim_create_user_command

	-- Search
	cmd("ZortexSearch", function()
		search.search()
	end, { desc = "Hierarchical search across all notes" })

	-- Link navigation
	cmd("ZortexOpenLink", function()
		links.open_link()
	end, { desc = "Open link under cursor" })

	-- Calendar
	cmd("ZortexCalendarOpen", function()
		local cal_path = fs.get_file_path("calendar.zortex")
		if cal_path then
			vim.cmd("edit " .. cal_path)
		end
	end, { desc = "Open calendar file" })

	cmd("ZortexCalendarToday", function()
		local today = os.date("%Y-%m-%d")
		local entries = calendar.get_entries_for_date(today)

		if #entries == 0 then
			vim.notify("No entries for today", vim.log.levels.INFO)
		else
			print("Today's entries:")
			for i, entry in ipairs(entries) do
				print(string.format("%d. %s", i, entry.display_text))
			end
		end
	end, { desc = "Show today's calendar entries" })

	-- Projects
	cmd("ZortexProjectsOpen", function()
		local proj_path = fs.get_projects_file()
		if proj_path then
			vim.cmd("edit " .. proj_path)
		end
	end, { desc = "Open projects file" })

	cmd("ZortexProjectsStats", function()
		local stats = projects.get_all_stats()
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
	cmd("ZortexArchiveProject", function()
		archive.archive_current_project()
	end, { desc = "Archive current project" })

	cmd("ZortexArchiveAllCompleted", function()
		archive.archive_all_completed_projects()
	end, { desc = "Archive all completed projects" })

	-- Progress
	cmd("ZortexUpdateProgress", function()
		progress.update_all_progress()
	end, { desc = "Update progress for all projects and OKRs" })

	-- Skill tree
	cmd("ZortexSkillTree", function()
		skill_tree_ui.show()
	end, { desc = "Show skill tree and season progress" })

	-- Season management
	cmd("ZortexStartSeason", function(opts)
		local args = vim.split(opts.args, " ")
		if #args < 2 then
			vim.notify("Usage: ZortexStartSeason <name> <end-date>", vim.log.levels.ERROR)
			vim.notify("Example: ZortexStartSeason Q1-2024 2024-03-31", vim.log.levels.INFO)
			return
		end

		local name = args[1]
		local end_date = args[2]
		xp.start_season(name, end_date)
	end, { nargs = "+", desc = "Start a new season" })

	cmd("ZortexEndSeason", function()
		xp.end_season()
	end, { desc = "End the current season" })

	cmd("ZortexSeasonStatus", function()
		local status = xp.get_season_status()
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
	cmd("ZortexCompleteTask", function()
		progress.complete_current_task()
	end, { desc = "Complete the task on current line" })

	-- Area XP management
	cmd("ZortexAddAreaXP", function(opts)
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

		xp.add_area_xp(path, xp_amount, nil)
		vim.notify(string.format("Added %d XP to %s", xp_amount, path), vim.log.levels.INFO)
	end, { nargs = "+", desc = "Manually add XP to an area" })

	cmd("ZortexAreaStats", function()
		local stats = xp.get_area_stats()
		print("Area Statistics:")
		print("================")
		for path, data in pairs(stats) do
			print(string.format("%s - Level %d (%d XP)", path, data.level, data.xp))
		end
	end, { desc = "Show area XP statistics" })

	-- Project info
	cmd("ZortexProjectInfo", function()
		local project = buffer.find_current_project()
		if not project then
			vim.notify("Not in a project", vim.log.levels.WARN)
			return
		end

		local stats = xp.get_project_stats()
		if stats[project] then
			local s = stats[project]
			print(string.format("Project: %s", project))
			print(string.format("XP earned: %d", s.xp))
			print(string.format("Tasks: %d/%d (%.0f%%)", s.completed_tasks, s.total_tasks, s.completion_rate * 100))
		else
			print("No stats for this project yet")
		end
	end, { desc = "Show project statistics" })

	-- Telescope integration
	pcall(function()
		local telescope = require("zortex.telescope")

		cmd("ZortexCalendarSearch", telescope.calendar, { desc = "Browse calendar chronologically" })
		cmd("ZortexProjects", telescope.projects, { desc = "Browse projects in Telescope" })
		cmd("ZortexDigest", telescope.today_digest, { desc = "Show today's digest" })
	end)
end

-- =============================================================================
-- Keymaps
-- =============================================================================

function M.create_keymaps()
	local opts = { noremap = true, silent = true }

	-- Search
	vim.keymap.set("n", "<leader>zs", ":ZortexSearch<CR>", vim.tbl_extend("force", opts, { desc = "Zortex search" }))

	-- Link navigation
	vim.keymap.set("n", "gx", ":ZortexOpenLink<CR>", vim.tbl_extend("force", opts, { desc = "Open Zortex link" }))

	-- Calendar
	vim.keymap.set(
		"n",
		"<leader>zc",
		":ZortexCalendarOpen<CR>",
		vim.tbl_extend("force", opts, { desc = "Open calendar" })
	)
	vim.keymap.set(
		"n",
		"<leader>zt",
		":ZortexCalendarToday<CR>",
		vim.tbl_extend("force", opts, { desc = "Today's entries" })
	)

	-- Projects
	vim.keymap.set(
		"n",
		"<leader>zp",
		":ZortexProjectsOpen<CR>",
		vim.tbl_extend("force", opts, { desc = "Open projects" })
	)

	-- Archive
	vim.keymap.set(
		"n",
		"<leader>za",
		":ZortexArchiveProject<CR>",
		vim.tbl_extend("force", opts, { desc = "Archive project" })
	)

	-- Skill tree
	vim.keymap.set(
		"n",
		"<leader>zk",
		":ZortexSkillTree<CR>",
		vim.tbl_extend("force", opts, { desc = "Show skill tree" })
	)

	-- Task completion
	vim.keymap.set(
		"n",
		"<leader>zx",
		":ZortexCompleteTask<CR>",
		vim.tbl_extend("force", opts, { desc = "Complete current task" })
	)

	-- Telescope (if available)
	pcall(function()
		vim.keymap.set(
			"n",
			"<leader>zC",
			":ZortexCalendarSearch<CR>",
			vim.tbl_extend("force", opts, { desc = "Search calendar" })
		)
		vim.keymap.set(
			"n",
			"<leader>zP",
			":ZortexProjects<CR>",
			vim.tbl_extend("force", opts, { desc = "Browse projects" })
		)
		vim.keymap.set(
			"n",
			"<leader>zd",
			":ZortexDigest<CR>",
			vim.tbl_extend("force", opts, { desc = "Today's digest" })
		)
	end)
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Core modules
M.parser = parser
M.fs = fs
M.buffer = buffer
M.search = core_search

-- Feature modules
M.xp = xp
M.skills = skills
M.progress = progress
M.archive = archive
M.links = links
M.calendar = calendar
M.projects = projects
M.hierarchical_search = search

-- Functions
M.open_link = links.open_link
M.archive_project = archive.archive_current_project
M.archive_all_completed = archive.archive_all_completed_projects
M.update_progress = progress.update_all_progress
M.show_skill_tree = skill_tree_ui.show

-- Initialize with default settings
M.setup()

return M
