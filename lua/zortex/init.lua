-- init.lua - Main entry point for Zortex (Service Architecture)
local M = {}

-- Utils
local fs = require("zortex.utils.filesystem")
local constants = require("zortex.constants")

-- Core modules
local Config = require("zortex.config")
local core = require("zortex.core")

-- Features
local highlights = require("zortex.features.highlights")
local completion = require("zortex.features.completion")
local calendar = require("zortex.features.calendar")

-- Initialize Zortex
function M.setup(opts)
	-- Merge user config
	Config.setup(opts)

	-- Ensure core zortex folders exist
	vim.fn.mkdir(fs.joinpath(Config.notes_dir, ".z"), "p") -- Store data
	vim.fn.mkdir(fs.joinpath(Config.notes_dir, "z"), "p") -- User library

	-- Setup core systems
	core.setup(Config)

	-- Setup features
	highlights.setup()
	calendar.init()

	-- Setup UI
	require("zortex.ui.commands").setup(Config.commands.prefix)
	require("zortex.ui.keymaps").setup(Config.keymaps.prefix, Config.commands.prefix)
	require("zortex.ui.calendar_view").setup(Config.ui.calendar)
	require("zortex.ui.telescope.search").setup(Config.ui.search)
	require("zortex.ui.telescope.core").setup()

	-- Setup completion
	local has_cmp, cmp = pcall(require, "cmp")
	if has_cmp then
		cmp.register_source("zortex", completion.new())
	end

	-- Setup performance monitoring
	local perf_monitor = require("zortex.core.performance_monitor")
	perf_monitor.setup_commands()

	if Config.debug then
		perf_monitor.start()
	end

	-- Emit setup complete
	-- EventBus.emit("zortex:setup_complete", {
	-- 	config = Config,
	-- })
end

-- Public API
M.toggle_task = function()
	require("zortex.services.tasks").toggle_task_at_line({
		bufnr = vim.api.nconfig.get("t_current_buf")(),
		lnum = vim.api.nvim_win_get_cursor(0)[1],
	})
end

M.complete_task = function()
	local task = require("zortex.services.tasks")
	local bufnr = vim.api.nconfig.get("t_current_buf")()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]

	local doc = require("zortex.core.document_manager").get_buffer(bufnr)
	if not doc then
		return
	end

	local section = doc:get_section_at_line(lnum)
	if not section then
		-- Convert to task
		task.convert_line_to_task({ bufnr = bufnr, lnum = lnum })
		return
	end

	-- Find task at line
	for _, task in ipairs(section.tasks) do
		if task.line == lnum and task.attributes and task.attributes.id then
			if not task.completed then
				task.complete_task(task.attributes.id, { bufnr = bufnr })
			end
			return
		end
	end

	-- No task found, convert line
	task.convert_line_to_task({ bufnr = bufnr, lnum = lnum })
end

M.search_sections = function()
	require("zortex.ui.telescope.search").search_sections()
end

M.open_calendar = function()
	require("zortex.ui.calendar_view").open()
end

M.archive_projects = function()
	require("zortex.services.archive").archive_completed_projects()
end

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

-- Public API exports
M.task = {
	toggle = function()
		local bufnr = vim.api.nconfig.get("t_current_buf")()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]

		require("zortex.services.tasks").toggle_task_at_line({
			bufnr = bufnr,
			lnum = lnum,
		})
	end,

	complete = function(task_id)
		require("zortex.services.tasks").complete_task(task_id, {
			bufnr = vim.api.nconfig.get("t_current_buf")(),
		})
	end,

	uncomplete = function(task_id)
		require("zortex.services.tasks").uncomplete_task(task_id, {
			bufnr = vim.api.nconfig.get("t_current_buf")(),
		})
	end,
}

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

M.search = function(opts)
	require("zortex.ui.telescope.search").search(opts)
end

M.calendar = {
	open = function()
		require("zortex.ui.calendar_view").open()
	end,

	add_entry = function(date_str, text)
		require("zortex.features.calendar").add_entry(date_str, text)
	end,
}

M.projects = function(opts)
	require("zortex.ui.telescope").projects(opts)
end

-- Status and debugging
M.status = function()
	core.print_status()
end

M.health = function()
	-- Check core systems
	vim.health.report_start("Zortex Core")

	-- Check initialization
	local status = core.get_status()
	if status.initialized then
		vim.health.report_ok("Core initialized")
	else
		vim.health.report_error("Core not initialized")
	end

	-- Check event bus
	if status.event_bus then
		local event_count = vim.tbl_count(status.event_bus)
		vim.health.report_ok(string.format("EventBus active (%d events tracked)", event_count))
	end

	-- Check document manager
	if status.document_manager then
		vim.health.report_ok(
			string.format(
				"DocumentManager: %d buffers, %d files",
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
