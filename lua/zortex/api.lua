local fs = require("zortex.utils.filesystem")
local constants = require("zortex.constants")

local M = {}

M.archive_projects = function()
	require("zortex.features.archive").archive_completed_projects()
end

M.task = {
	toggle = function()
		require("zortex.services.tasks").toggle_current_task()
	end,

	complete = function()
		require("zortex.services.tasks").complete_current_task()
	end,

	uncomplete = function()
		require("zortex.services.tasks").uncomplete_current_task()
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
		require("zortex.services.xp").show_overview()
	end,

	stats = function()
		return require("zortex.services.xp").get_stats()
	end,

	season = {
		start = function(name, end_date)
			require("zortex.services.xp").start_season(name, end_date)
		end,

		end_current = function()
			require("zortex.services.xp").end_season()
		end,

		status = function()
			return require("zortex.services.xp").get_season_status()
		end,
	},
}

-- ===========================================================================
-- UI
-- ===========================================================================
M.search = function(opts)
	require("zortex.ui.telescope.search").search(opts)
end

M.search_sections = function()
	require("zortex.ui.telescope.search").search_sections()
end

M.search_articles = function()
	require("zortex.ui.telescope.search").search_articles()
end

M.search_all = function()
	require("zortex.ui.telescope.search").search_all()
end

M.calendar = {
	open = function()
		require("zortex.ui.calendar.view").open()
	end,

	add_entry = function(date_str, text)
		require("zortex.stores.calendar").add_entry(date_str, text)
	end,
}

M.projects = function(opts)
	require("zortex.ui.telescope").projects(opts)
end

M.skill_tree = function()
	require("zortex.ui.skill_tree").show()
end

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

return M
