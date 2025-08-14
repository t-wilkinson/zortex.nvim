local fs = require("zortex.utils.filesystem")
local constants = require("zortex.constants")

local M = {}

M.archive_projects = function()
	return require("zortex.features.archive").archive_completed_projects()
end

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
-- 		xp = require("zortex.services.xp").get_stats(),
-- 	}
--
-- 	-- Format and display stats
-- 	require("zortex.ui.progress_dashboard").show(stats)
-- end

M.update_progress = function()
	require("zortex.services.okr").update_progress()

	-- Update project progress
	local projects_file = fs.get_file_path(constants.FILES.PROJECTS)
	local bufnr = vim.fn.bufnr(projects_file)
	if bufnr > 0 then
		require("zortex.services.projects").update_all_project_progress(bufnr)
	end
end

-- ===========================================================================
-- XP
-- ===========================================================================
M.xp = {
	overview = function()
		require("zortex.services.xp").show_xp_overview()
	end,

	stats = function()
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
	end,

	season = {
		start = function(name, end_date)
			require("zortex.services.xp").start_season(name, end_date)
		end,

		end_current = function()
			local result = require("zortex.services.xp").end_season()
			if result then
				vim.notify("Ended season: " .. result.name, vim.log.levels.INFO)
			else
				vim.notify("No active season to end", vim.log.levels.WARN)
			end
		end,

		status = function()
			return require("zortex.services.xp").get_season_status()
		end,
	},
}

-- ===========================================================================
-- UI
-- ===========================================================================
M.search = {
	search = function(opts)
		require("zortex.ui.telescope.search").search(opts)
	end,

	sections = function()
		require("zortex.ui.telescope.search").search_sections()
	end,

	articles = function()
		require("zortex.ui.telescope.search").search_articles()
	end,

	all = function()
		require("zortex.ui.telescope.search").search_all()
	end,

	projects = function(opts)
		require("zortex.ui.telescope").projects(opts)
	end,
}

M.calendar = {
	open = function()
		require("zortex.ui.calendar.view").open()
	end,

	add_entry = function(date_str, text)
		require("zortex.stores.calendar").add_entry(date_str, text)
	end,
}

M.skill_tree = function()
	require("zortex.ui.skill_tree").show()
end

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

	-- Check document manager
	if status.document_manager then
		vim.health.report_ok(
			string.format(
				"Doc: %d buffers, %d files",
				status.document_manager.buffer_count,
				status.document_manager.file_count
			)
		)
	end

	-- Check persistence
	if status.persistence then
		if status.persistence.initialized then
			vim.health.report_ok("Persistence manager active")
		else
			vim.health.report_warn("Persistence manager not initialized")
		end
	end
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

	-- Buffer sync status
	local buffer_sync = require("zortex.core.buffer_sync")
	local sync_status = buffer_sync.get_status()
	table.insert(lines, "Buffer Sync:")
	table.insert(lines, "  Strategy: " .. sync_status.strategy)
	table.insert(lines, "  Pending Changes: " .. sync_status.total_pending_changes)
	table.insert(lines, "  Active Timers: " .. sync_status.active_timers)
	table.insert(lines, "")

	-- Document manager status
	local doc_manager = require("zortex.core.document_manager")
	local docs = doc_manager.get_all_documents()
	table.insert(lines, "Documents:")
	table.insert(lines, "  Loaded: " .. #docs)

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
