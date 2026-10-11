local fs = require("zortex.utils.filesystem")
local constants = require("zortex.constants")

local M = {}

M.toc = function()
	return require("zortex.features.toc").show_toc()
end

M.toc_popup = function()
	return require("zortex.features.toc").show_toc_popup()
end

M.archive_projects = function()
	return require("zortex.features.archive").archive_completed_projects()
end

-- Tasks
M.task = {
	convert = function()
		local tasks = require("zortex.services.tasks")
		local buffer = require("zortex.utils.buffer")
		return tasks.convert_line_to_task(buffer.get_context())
	end,

	toggle = function()
		return require("zortex.services.tasks").toggle_current_task()
	end,

	complete = function()
		return require("zortex.services.tasks").complete_current_task()
	end,

	uncomplete = function()
		return require("zortex.services.tasks").uncomplete_current_task()
	end,
}

-- M.show_progress = function()
-- 	local stats = {
-- 		tasks = require("zortex.stores.tasks").get_stats(),
-- 		projects = require("zortex.services.project").get_all_stats(),
-- 		xp = require("zortex.services.xp.stats").get_stats(),
-- 	}
--
-- 	-- Format and display stats
-- 	require("zortex.ui.progress_dashboard").show(stats)
-- end

-- Write @progress(done/total) on every project heading of the projects buffer
M.update_progress = function()
	local projects_file = fs.get_file_path(constants.FILES.PROJECTS)
	local bufnr = vim.fn.bufnr(projects_file)
	if bufnr > 0 then
		return require("zortex.services.projects").update_progress(bufnr)
	end
	return 0
end

-- Projects (see services/projects for the full API)
M.projects = setmetatable({}, {
	__index = function(_, key)
		return require("zortex.services.projects")[key]
	end,
})

-- ===========================================================================
-- Notifications
-- ===========================================================================
M.notifications = {

	sync = function()
		local notifications = require("zortex.notifications")
		if notifications and notifications.calendar then
			local count = notifications.calendar.sync()
			vim.notify(string.format("Synced %d notifications", count or 0), vim.log.levels.INFO)
		else
			vim.notify("Calendar notifications not available", vim.log.levels.ERROR)
		end
	end,
}

-- ===========================================================================
-- XP
-- ===========================================================================
M.xp = {
	overview = function()
		require("zortex.services.xp.stats").show_stats()
	end,

	stats = function()
		require("zortex.services.xp.stats").show_stats()
	end,

	areas = function()
		require("zortex.services.xp.stats").show_area_xp()
	end,

	season = {
		start = function(name, end_date)
			require("zortex.services.xp.stats").start_season(name, end_date)
		end,

		end_current = function()
			local result = require("zortex.services.xp.stats").end_season()
			if result then
				vim.notify("Ended season: " .. result.name, vim.log.levels.INFO)
			else
				vim.notify("No active season to end", vim.log.levels.WARN)
			end
		end,

		status = function()
			return require("zortex.services.xp.stats").season_status()
		end,
	},
}

-- Areas (see services/areas for the full API)
M.areas = setmetatable({}, {
	__index = function(_, key)
		return require("zortex.services.areas")[key]
	end,
})

-- ===========================================================================
-- UI
-- ===========================================================================
M.search = {
	structural = function(opts)
		require("zortex.ui.telescope.search").structural_search(opts)
	end,

	projects = function(opts)
		require("zortex.ui.telescope.projects").projects(opts)
	end,
}

M.calendar = {
	open = function()
		require("zortex.ui.calendar.view").open()
	end,

	add_entry = function(date_str, text)
		require("zortex.stores.calendar").add_entry(date_str, text)
	end,

	digest = function()
		require("zortex.ui.calendar.view").open_digest()
	end,
}

M.skill_tree = function()
	require("zortex.ui.skill_tree").show()
end

-- ===========================================================================
-- digest
-- ===========================================================================

M.digest = {
	open = function()
		require("zortex.services.digest").open_digest()
	end,
	update = function()
		require("zortex.services.digest").force_update()
	end,
}

-- ===========================================================================
-- Archive
-- ===========================================================================
M.archive = {
	section = function()
		require("zortex.features.archive").archive_current_section()
	end,
}

-- ===========================================================================
-- Status and debugging
-- ===========================================================================
M.status = function()
	require("zortex.core").print_status()
end

M.health = function()
	-- Check core systems
	vim.health.report_start("Zortex Core")

	-- Check initialization
	local status = require("zortex.core").get_status()
	if status.initialized then
		vim.health.report_ok("Core initialized")
	else
		vim.health.report_error("Core not initialized")
	end

	-- Check event bus
	if status.event_bus then
		local event_count = vim.tbl_count(status.event_bus)
		vim.health.report_ok(string.format("Events active (%d events tracked)", event_count))
	end

	-- State files
	vim.health.report_info("State directory: " .. require("zortex.core.state").path(""):gsub("%.json$", ""))
end

M.debug = function()
	local Config = require("zortex.config")
	local lines = {
		"🐛 Zortex Debug Info",
		"",
		"Configuration:",
		"  Notes Dir: " .. Config.notes_dir,
		"  Extension: " .. Config.extension,
		"",
	}

	-- Notes
	table.insert(lines, "Notes:")
	table.insert(lines, "  Indexed: " .. #require("zortex.core.notes").files())

	-- Event bus performance
	local events = require("zortex.core.event_bus")
	local perf = events.get_performance_report()
	table.insert(lines, "")
	table.insert(lines, "Event Performance:")
	for event, stats in pairs(perf) do
		if stats.count > 0 then
			table.insert(lines, string.format("  %s: %d calls, avg %.1fms", event, stats.count, stats.avg_time))
		end
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Debug Info" })
end

return M
