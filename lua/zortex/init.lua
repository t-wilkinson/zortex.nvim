-- init.lua - Main entry point for Zortex (Service Architecture)
local M = {}

-- Core modules
local core = require("zortex.core")
local config = require("zortex.config")
local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")

-- UI modules
local commands = require("zortex.ui.commands")
local keymaps = require("zortex.ui.keymaps")
local telescope_setup = require("zortex.ui.telescope.core")

-- Features
local highlights = require("zortex.features.highlights")
local completion = require("zortex.features.completion")
local calendar = require("zortex.features.calendar")

-- Initialize Zortex
function M.setup(opts)
	-- Merge user config
	local cfg = config.setup(opts)

	-- Set notes directory
	vim.g.zortex_notes_dir = vim.fn.expand(cfg.notes_dir)
	vim.fn.mkdir(vim.g.zortex_notes_dir, "p")

	-- Initialize core systems
	core.init(cfg)

	-- Setup features
	highlights.setup_autocmd()

	-- Setup UI
	commands.setup(cfg.commands.prefix)
	keymaps.setup(cfg.keymaps.prefix, cfg.commands.prefix)
	telescope_setup.setup()

	-- Setup calendar
	calendar.init()

	-- Setup completion
	local has_cmp, cmp = pcall(require, "cmp")
	if has_cmp then
		cmp.register_source("zortex", completion.new())
	end

	-- Setup logger commands
	Logger.setup_commands()

	-- Setup performance monitoring
	local perf_monitor = require("zortex.core.performance_monitor")
	perf_monitor.setup_commands()

	if cfg.debug then
		perf_monitor.start()
	end

	-- Initialize stores
	require("zortex.stores.xp").setup()

	-- Emit setup complete
	EventBus.emit("zortex:setup_complete", {
		config = cfg,
	})

	vim.notify("Zortex initialized", vim.log.levels.INFO)
end

-- Public API
M.toggle_task = function()
	require("zortex.services.task_service").toggle_task_at_line({
		bufnr = vim.api.nvim_get_current_buf(),
		lnum = vim.api.nvim_win_get_cursor(0)[1],
	})
end

M.complete_task = function()
	local task_service = require("zortex.services.task_service")
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]

	local doc = require("zortex.core.document_manager").get_buffer(bufnr)
	if not doc then
		return
	end

	local section = doc:get_section_at_line(lnum)
	if not section then
		-- Convert to task
		task_service.convert_line_to_task({ bufnr = bufnr, lnum = lnum })
		return
	end

	-- Find task at line
	for _, task in ipairs(section.tasks) do
		if task.line == lnum and task.attributes and task.attributes.id then
			if not task.completed then
				task_service.complete_task(task.attributes.id, { bufnr = bufnr })
			end
			return
		end
	end

	-- No task found, convert line
	task_service.convert_line_to_task({ bufnr = bufnr, lnum = lnum })
end

M.search = function()
	require("zortex.ui.telescope.search").search()
end

M.search_sections = function()
	require("zortex.ui.telescope.search").search_sections()
end

M.open_calendar = function()
	require("zortex.ui.calendar_view").open()
end

M.archive_projects = function()
	require("zortex.services.archive_service").archive_completed_projects()
end

M.show_progress = function()
	local stats = {
		tasks = require("zortex.stores.tasks").get_stats(),
		projects = require("zortex.services.project_service").get_all_stats(),
		xp = require("zortex.services.xp_service").get_stats(),
	}

	-- Format and display stats
	require("zortex.ui.progress_dashboard").show(stats)
end

M.update_progress = function()
	require("zortex.services.objective_service").update_progress()

	-- Update project progress
	local projects_file = vim.g.zortex_notes_dir .. "/projects.zortex"
	local bufnr = vim.fn.bufnr(projects_file)
	if bufnr > 0 then
		require("zortex.services.project_service").update_all_project_progress(bufnr)
	end
end

return M
