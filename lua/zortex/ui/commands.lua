-- ui/commands.lua

local M = {}

local api = require("zortex.api")
local fs = require("zortex.utils.filesystem")
local Logger = require("zortex.core.logger")
local notifications = require("zortex.notifications")

-- =============================================================================
-- User Commands
-- =============================================================================

function M.setup(prefix)
	local function cmd(name, command, options)
		vim.api.nvim_create_user_command(prefix .. name, command, options)
	end

	-- ===========================================================================
	-- Logging
	-- ===========================================================================
	cmd("Logs", function(opts)
		local count = tonumber(opts.args) or 50
		Logger.show_logs(count)
	end, { nargs = "?" })

	cmd("Performance", function()
		Logger.show_performance_report()
	end, {})

	cmd("LogLevel", function(opts)
		Logger.set_level(opts.args:upper())
	end, {
		nargs = 1,
		complete = function()
			return { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }
		end,
	})

	cmd("ClearLogs", function()
		Logger.clear_logs()
	end, {})

	-- ===========================================================================
	-- iCal Import/Export
	-- ===========================================================================
	cmd("IcalImport", function()
		require("zortex.features.ical").import_interactive()
	end, { desc = "Import iCal file or URL" })

	cmd("IcalExport", function()
		require("zortex.features.ical").export_interactive()
	end, { desc = "Export calendar to iCal file" })

	-- ===========================================================================
	-- Navigation
	-- ===========================================================================
	cmd("OpenLink", function()
		require("zortex.features.links").open_link()
	end, { desc = "Open link under cursor" })

	cmd("SearchSections", function()
		api.search_sections()
	end, { desc = "Section-based search" })
	cmd("SearchArticles", function()
		api.search_articles()
	end, { desc = "Article-based search" })
	cmd("SearchTasks", function()
		api.search_tasks()
	end, { desc = "Task-based search" })
	cmd("SearchAll", function()
		api.search_all()
	end, { desc = "Search sections, articles, and tasks" })

	-- ===========================================================================
	-- Calendar
	-- ===========================================================================
	cmd("Calendar", function()
		api.calendar.open()
	end, { desc = "Open Zortex calendar" })

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
		local proj_path = fs.get_projects_file()
		if proj_path then
			vim.cmd("edit " .. proj_path)
		end
	end, { desc = "Open projects file" })

	-- cmd("ProjectsStats", function()
	-- 	local stats = modules.projects.get_all_stats()
	-- 	print(string.format("Projects: %d", stats.project_count))
	-- 	print(string.format("Total tasks: %d", stats.total_tasks))
	-- 	print(
	-- 		string.format(
	-- 			"Completed: %d (%.1f%%)",
	-- 			stats.completed_tasks,
	-- 			stats.total_tasks > 0 and (stats.completed_tasks / stats.total_tasks * 100) or 0
	-- 		)
	-- 	)
	-- end, { desc = "Show project statistics" })

	-- -- Update all project progress
	-- cmd("UpdateProgress", function()
	-- 	modules.progress.update_all_progress()
	-- end, { desc = "Update progress for all projects and OKRs" })

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
		api.skill_tree()
	end, { desc = "Show skill tree and season progress" })

	-- XP system info
	cmd("XPInfo", function()
		notifications.xp.show_xp_overview()
	end, {
		desc = "Show XP system overview",
	})

	-- ===========================================================================
	-- Season management
	-- ===========================================================================
	-- cmd("StartSeason", function(opts)
	-- 	local args = vim.split(opts.args, " ")
	-- 	if #args < 2 then
	-- 		vim.notify("Usage: ZortexStartSeason <name> <end-date YYYY-MM-DD>", vim.log.levels.ERROR)
	-- 		vim.notify("Example: ZortexStartSeason Q1-2024 2024-03-31", vim.log.levels.INFO)
	-- 		return
	-- 	end

	-- 	local name = args[1]
	-- 	local end_date = args[2]
	-- 	xp.projects.start_season(name, end_date)
	-- end, { nargs = "*", desc = "Start a new season" })

	-- cmd("EndSeason", function()
	-- 	xp.projects.end_season()
	-- end, { desc = "End the current season" })

	-- cmd("SeasonStatus", function()
	-- 	local status = xp.projects.get_season_status()
	-- 	if status then
	-- 		print("Current Season: " .. status.season.name)
	-- 		print(
	-- 			string.format(
	-- 				"Level %d - %s Tier",
	-- 				status.level,
	-- 				status.current_tier and status.current_tier.name or "None"
	-- 			)
	-- 		)
	-- 		print(string.format("Progress: %.0f%%", status.progress_to_next * 100))
	-- 	else
	-- 		print("No active season")
	-- 	end
	-- end, { desc = "Show current season status" })

	-- ===========================================================================
	-- Task management
	-- ===========================================================================
	cmd("ToggleTask", function()
		api.task.toggle()
	end, { desc = "Toggle the task on current line" })

	cmd("CompleteTask", function()
		api.task.complete_current_task()
	end, { desc = "Complete the task on current line" })

	cmd("UncompleteTask", function()
		api.task.uncomplete_current_task()
	end, { desc = "Uncomplete the task on current line" })

	-- ===========================================================================
	-- System Status
	-- ===========================================================================
	cmd("SystemStatus", function()
		api.status()
	end, { desc = "Show Zortex system status" })

	cmd("SaveStores", function()
		local persistence_manager = require("zortex.stores.persistence_manager")
		local results = persistence_manager.save_all()
		vim.notify(string.format("Saved %d stores", #results.saved), vim.log.levels.INFO)
	end, { desc = "Force save all stores" })
end

return M
