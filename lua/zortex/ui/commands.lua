-- ui/commands.lua

local M = {}

local api = require("zortex.api")
local fs = require("zortex.utils.filesystem")
local Logger = require("zortex.core.logger")

-- =============================================================================
-- User Commands
-- =============================================================================

function M.setup(prefix)
	local function cmd(name, command, options)
		vim.api.nvim_create_user_command(prefix .. name, command, options)
	end

	-- ===========================================================================
	-- Files
	-- ===========================================================================
	cmd("OpenProjects", function()
		vim.cmd("edit " .. fs.get_projects_file())
	end, { desc = "Open projects file" })
	cmd("OpenCalendar", function()
		vim.cmd("edit " .. fs.get_calendar_file())
	end, { desc = "Open projects file" })
	cmd("OpenOKR", function()
		vim.cmd("edit " .. fs.get_okr_file())
	end, { desc = "Open projects file" })
	cmd("OpenAreas", function()
		vim.cmd("edit " .. fs.get_areas_file())
	end, { desc = "Open projects file" })

	-- ===========================================================================
	-- Tasks
	-- ===========================================================================
	cmd("TaskToggle", function()
		api.task.toggle()
	end, { desc = "Toggle task" })
	cmd("TaskComplete", function()
		api.task.complete()
	end, { desc = "Complete task" })
	cmd("TaskUncomplete", function()
		api.task.uncomplete()
	end, { desc = "Uncomplete task" })
	cmd("TaskConvert", function()
		api.task.convert()
	end, { desc = "Convert line to task" })

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
	cmd("LinkOpen", function()
		require("zortex.features.links").open_link()
	end, { desc = "Open link under cursor" })

	cmd("SearchSections", function()
		api.search.sections()
	end, { desc = "Section-based search" })
	cmd("SearchArticles", function()
		api.search.articles()
	end, { desc = "Article-based search" })
	cmd("SearchTasks", function()
		api.search.tasks()
	end, { desc = "Task-based search" })
	cmd("SearchAll", function()
		api.search.all()
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
	cmd("ProjectProgress", function()
		local bufnr = vim.api.nvim_get_current_buf()
		local progress_service = require("zortex.services.projects.progress")
		local updated = progress_service.update_all_projects(bufnr)
		vim.notify(string.format("Updated %d projects", updated), vim.log.levels.INFO)
	end, { desc = "Update all project progress in current buffer" })

	-- ===========================================================================
	-- XP & Skill tree
	-- ===========================================================================
	cmd("SkillTree", function()
		api.skill_tree()
	end, { desc = "Show skill tree and season progress" })

	cmd("XPInfo", function()
		require("zortex.notifications.types.xp").show_xp_overview()
	end, { desc = "Show XP system overview" })

	cmd("XPStats", function()
		local xp_service = require("zortex.services.xp")
		local stats = xp_service.get_stats()

		local lines = { "📊 XP Statistics", "" }

		-- Season stats
		if stats.season then
			table.insert(lines, "🏆 Season: " .. stats.season.season.name)
			table.insert(lines, string.format("   Level: %d", stats.season.level))
			table.insert(lines, string.format("   XP: %d", stats.season.xp))
			if stats.season.current_tier then
				table.insert(lines, "   Tier: " .. stats.season.current_tier.name)
			end
			table.insert(lines, "")
		end

		-- Project stats
		if next(stats.projects) then
			table.insert(lines, "📁 Projects:")
			for name, proj in pairs(stats.projects) do
				table.insert(lines, string.format("   %s: Level %d (%d XP)", name, proj.level, proj.xp))
			end
			table.insert(lines, "")
		end

		-- Area stats
		if stats.areas then
			table.insert(lines, string.format("🏔️  Areas: %d total", stats.areas.total_areas))
			table.insert(lines, string.format("   Total XP: %d", stats.areas.total_xp))
			table.insert(lines, string.format("   Max Level: %d", stats.areas.max_level))
		end

		vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "XP Stats" })
	end, { desc = "Show XP statistics" })

	-- ===========================================================================
	-- Season management
	-- ===========================================================================
	cmd("SeasonStatus", function()
		local status = api.xp.season.status()
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

	cmd("SeasonStart", function(opts)
		local args = vim.split(opts.args, " ")
		if #args < 1 then
			vim.notify("Usage: ZortexStartSeason <name> [<end-date YYYY-MM-DD>]", vim.log.levels.ERROR)
			vim.notify("Example: ZortexStartSeason Q1-2024 2024-03-31", vim.log.levels.INFO)
			return
		end

		local name = args[1] or ("S-" .. os.date("%Y-%m"))
		local end_date

		if #args == 1 then
			end_date = os.time() + (90 * 24 * 60 * 60) -- 90 days from now
		else
			end_date = args[2]
		end

		local xp_service = require("zortex.services.xp")

		xp_service.start_season(name, end_date)
		vim.notify("Started season: " .. name, vim.log.levels.INFO)
	end, {
		desc = "Start a new season",
		nargs = "*",
	})

	cmd("SeasonEnd", function()
		local xp_service = require("zortex.services.xp")
		local result = xp_service.end_season()

		if result then
			vim.notify("Ended season: " .. result.name, vim.log.levels.INFO)
		else
			vim.notify("No active season to end", vim.log.levels.WARN)
		end
	end, { desc = "End the current season" })

	-- ===========================================================================
	-- Task management
	-- ===========================================================================
	cmd("TaskToggle", function()
		api.task.toggle()
	end, { desc = "Toggle the task on current line" })

	cmd("TaskComplete", function()
		api.task.complete()
	end, { desc = "Complete the task on current line" })

	cmd("TaskUncomplete", function()
		api.task.uncomplete()
	end, { desc = "Uncomplete the task on current line" })

	-- ===========================================================================
	-- System Management
	-- ===========================================================================
	cmd("SystemStatus", function()
		api.status()
	end, { desc = "Show Zortex system status" })

	cmd("Debug", function()
		api.debug()
	end, { desc = "Show Zortex system status" })

	cmd("SaveStores", function()
		local persistence_manager = require("zortex.stores.persistence_manager")
		local results = persistence_manager.save_all()
		vim.notify(string.format("Saved %d stores", #results.saved), vim.log.levels.INFO)
	end, { desc = "Force save all stores" })

	-- Create user commands
	cmd("Digest", function()
		api.digest.open()
	end, { desc = "Open daily digest" })

	cmd("DigestUpdate", function()
		api.digest.update()
	end, { desc = "Update daily digest" })
end

return M
