-- ui/commands.lua

local M = {}

local Core = require("zortex.core.init")
local DocumentManager = require("zortex.core.document_manager")

local notifications = require("zortex.notifications")

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

local services = {
	task = require("zortex.services.task"),
	xp = require("zortex.services.xp"),
}

local features = {
	-- archive = require("zortex.features.archive"),
	calendar = require("zortex.features.calendar"),
	completion = require("zortex.features.completion"),
	highlights = require("zortex.features.highlights"),
	links = require("zortex.features.links"),
	ical = require("zortex.features.ical"),
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
	persistence = require("zortex.stores.persistence_manager"),
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

function M.setup(prefix)
	local function cmd(name, command, options)
		vim.api.nvim_create_user_command(prefix .. name, command, options)
	end

	-- ===========================================================================
	-- Notifications
	-- ===========================================================================
	cmd("Notify", function(opts)
		local args = vim.split(opts.args, " ", { plain = false, trimempty = true })
		if #args < 2 then
			vim.notify("Usage: ZortexNotify <title> <message>", vim.log.levels.ERROR)
			return
		end
		local title = args[1]
		local message = table.concat(vim.list_slice(args, 2), " ")
		notifications.notify(title, message)
	end, { nargs = "+", desc = "Send a notification" })

	-- Pomodoro
	cmd("PomodoroStart", function()
		notifications.pomodoro.start()
	end, { desc = "Start pomodoro timer" })

	cmd("PomodoroStop", function()
		notifications.pomodoro.stop()
	end, { desc = "Stop pomodoro timer" })

	cmd("PomodoroStatus", function()
		local status = notifications.pomodoro.status()
		if status.phase == "stopped" then
			vim.notify("Pomodoro is not running", vim.log.levels.INFO)
		else
			vim.notify(
				string.format("Pomodoro: %s - %s remaining", status.phase:gsub("_", " "), status.remaining_formatted),
				vim.log.levels.INFO
			)
		end
	end, { desc = "Show pomodoro status" })

	-- Timers
	cmd("TimerStart", function(opts)
		local args = vim.split(opts.args, " ", { plain = false, trimempty = true })
		if #args < 1 then
			vim.notify("Usage: ZortexTimerStart <duration> [name]", vim.log.levels.ERROR)
			return
		end
		local duration = args[1]
		local name = args[2] and table.concat(vim.list_slice(args, 2), " ") or nil
		local id = notifications.timer.start(duration, name)
		if id then
			vim.notify("Timer started: " .. id, vim.log.levels.INFO)
		end
	end, { nargs = "+", desc = "Start a timer" })

	cmd("TimerList", function()
		local timers = notifications.timer.list()
		if #timers == 0 then
			vim.notify("No active timers", vim.log.levels.INFO)
		else
			local lines = { "Active timers:" }
			for _, timer in ipairs(timers) do
				table.insert(
					lines,
					string.format("  %s: %s - %s remaining", timer.id:sub(1, 8), timer.name, timer.remaining_formatted)
				)
			end
			vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
		end
	end, { desc = "List active timers" })

	-- Calendar sync
	cmd("NotificationSync", function()
		notifications.calendar.sync()
	end, { desc = "Sync calendar notifications" })

	-- Test notifications
	cmd("TestNotifications", function()
		notifications.test.all()
	end, { desc = "Test all notification providers" })

	-- ===========================================================================
	-- Daily Digest
	-- ===========================================================================
	cmd("DigestSend", function()
		local success, msg = notifications.digest.send_now()
		vim.notify(msg, success and vim.log.levels.INFO or vim.log.levels.ERROR)
	end, { desc = "Send daily digest email now" })

	cmd("DigestPreview", function()
		notifications.digest.preview()
	end, { desc = "Preview daily digest" })

	-- ===========================================================================
	-- iCal Import/Export
	-- ===========================================================================
	cmd("IcalImport", function()
		features.ical.import_interactive()
	end, { desc = "Import iCal file or URL" })

	cmd("IcalExport", function()
		features.ical.export_interactive()
	end, { desc = "Export calendar to iCal file" })

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
	-- Task management (UPDATED TO USE SERVICES)
	-- ===========================================================================
	cmd("ToggleTask", function()
		Core.toggle_current_task()
	end, { desc = "Toggle the task on current line" })

	cmd("CompleteTask", function()
		local bufnr = vim.api.nvim_get_current_buf()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]

		-- Get document and find task
		local doc = DocumentManager.get_buffer(bufnr)
		if not doc then
			vim.notify("No document found for current buffer", vim.log.levels.ERROR)
			return
		end

		local section = doc:get_section_at_line(lnum)
		if not section then
			vim.notify("No section found at current line", vim.log.levels.ERROR)
			return
		end

		-- Find task at this line
		local task = nil
		for _, t in ipairs(section.tasks) do
			if t.line == lnum then
				task = t
				break
			end
		end

		if not task then
			-- Try to convert line to task
			services.task.convert_line_to_task({ bufnr = bufnr, lnum = lnum })
			return
		end

		-- Complete the task
		if task.attributes and task.attributes.id then
			services.task.complete_task(task.attributes.id, { bufnr = bufnr })
		else
			vim.notify("Task has no ID", vim.log.levels.ERROR)
		end
	end, { desc = "Complete the task on current line" })

	cmd("UncompleteTask", function()
		local bufnr = vim.api.nvim_get_current_buf()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]

		-- Get document and find task
		local doc = DocumentManager.get_buffer(bufnr)
		if not doc then
			vim.notify("No document found for current buffer", vim.log.levels.ERROR)
			return
		end

		local section = doc:get_section_at_line(lnum)
		if not section then
			vim.notify("No section found at current line", vim.log.levels.ERROR)
			return
		end

		-- Find task at this line
		local task = nil
		for _, t in ipairs(section.tasks) do
			if t.line == lnum then
				task = t
				break
			end
		end

		if not task or not task.completed then
			vim.notify("No completed task at current line", vim.log.levels.WARN)
			return
		end

		-- Uncomplete the task
		if task.attributes and task.attributes.id then
			services.task.uncomplete_task(task.attributes.id, { bufnr = bufnr })
		else
			vim.notify("Task has no ID", vim.log.levels.ERROR)
		end
	end, { desc = "Uncomplete the task on current line" })

	-- ===========================================================================
	-- System Status
	-- ===========================================================================
	cmd("SystemStatus", function()
		Core.print_status()
	end, { desc = "Show Zortex system status" })

	cmd("SaveStores", function()
		local results = stores.persistence.save_all()
		vim.notify(string.format("Saved %d stores", #results.saved), vim.log.levels.INFO)
	end, { desc = "Force save all stores" })
end

return M
