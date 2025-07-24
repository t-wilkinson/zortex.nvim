-- core/phase2_init.lua
-- Phase 2 initialization - Task and XP services
local M = {}

local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local Phase1 = require("zortex.core.phase1_init")

-- Phase 2 components
M.initialized = false
M.components = {
	task_service = false,
	xp_service = false,
	xp_distributor = false,
	stores = false,
}

-- Initialize Phase 2
function M.init(opts)
	if M.initialized then
		return true
	end

	opts = opts or {}

	-- Ensure Phase 1 is initialized
	if not Phase1.initialized then
		Logger.error("phase2", "Phase 1 must be initialized first")
		return false
	end

	Logger.info("phase2", "Initializing Phase 2 components")

	-- Initialize stores
	local init_stores = Logger.wrap_function("phase2.init_stores", function()
		local xp_store = require("zortex.stores.xp")
		local task_store = require("zortex.stores.tasks")

		-- Ensure stores are loaded
		xp_store.reload()
		task_store.reload()

		M.components.stores = true
		Logger.info("phase2", "Stores initialized")
	end)
	init_stores()

	-- Initialize XP configuration
	local init_xp_config = Logger.wrap_function("phase2.init_xp_config", function()
		local config = require("zortex.config").config
		local xp_core = require("zortex.xp.core")
		xp_core.setup(config.xp)
		Logger.info("phase2", "XP configuration loaded")
	end)
	init_xp_config()

	-- Initialize XP Distributor
	local init_distributor = Logger.wrap_function("phase2.init_distributor", function()
		local XPDistributor = require("zortex.domain.xp.distributor")
		XPDistributor.init()
		M.components.xp_distributor = true
		Logger.info("phase2", "XP Distributor initialized")
	end)
	init_distributor()

	-- Initialize XP Service
	local init_xp_service = Logger.wrap_function("phase2.init_xp_service", function()
		local XPService = require("zortex.services.xp_service")
		XPService.init()
		M.components.xp_service = true
		Logger.info("phase2", "XP Service initialized")
	end)
	init_xp_service()

	-- Initialize Task Service (no explicit init needed)
	M.components.task_service = true
	Logger.info("phase2", "Task Service ready")

	-- Set up backward compatibility
	M.setup_compatibility()

	-- Set up development commands
	if opts.dev_mode or config.get("zortex_dev_mode") then
		M.setup_dev_commands()
	end

	M.initialized = true
	Logger.info("phase2", "Phase 2 initialization complete", M.components)

	-- Emit initialization event
	EventBus.emit("phase2:initialized", {
		components = M.components,
		opts = opts,
	})

	return true
end

-- Set up backward compatibility with existing modules
function M.setup_compatibility()
	-- Bridge document changes to task processing
	EventBus.on("document:changed", function(data)
		-- Process tasks in changed document
		vim.schedule(function()
			local TaskService = require("zortex.services.task_service")
			TaskService.process_buffer_tasks(data.bufnr)
		end)
	end, {
		priority = 80,
		name = "phase2_compat_doc_changed",
	})

	-- Bridge old task module calls to new service
	local old_tasks = require("zortex.modules.tasks")

	-- Override old toggle function
	old_tasks.toggle_current_task = function()
		local TaskService = require("zortex.services.task_service")
		local bufnr = vim.api.nconfig.get("t_current_buf")()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]

		TaskService.toggle_task_at_line({
			bufnr = bufnr,
			lnum = lnum,
		})
	end

	Logger.info("phase2", "Compatibility layer established")
end

-- Development commands
function M.setup_dev_commands()
	-- Test task toggle
	vim.api.nvim_create_user_command("ZortexTestTaskToggle", function()
		local TaskService = require("zortex.services.task_service")
		local bufnr = vim.api.nconfig.get("t_current_buf")()
		local lnum = vim.api.nvim_win_get_cursor(0)[1]

		local task, err = TaskService.toggle_task_at_line({
			bufnr = bufnr,
			lnum = lnum,
		})

		if task then
			print("Task toggled: " .. vim.inspect(task))
		else
			print("Error: " .. (err or "Unknown error"))
		end
	end, {})

	-- Show XP stats
	vim.api.nvim_create_user_command("ZortexXPStats", function()
		local XPService = require("zortex.services.xp_service")
		local stats = XPService.get_stats()

		-- Create buffer
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
		vim.api.nvim_buf_set_name(buf, "Zortex XP Statistics")

		local lines = { "=== XP Statistics ===" }

		-- Season stats
		if stats.season then
			table.insert(lines, "")
			table.insert(lines, "Season: " .. stats.season.season.name)
			table.insert(lines, "  Level: " .. stats.season.level)
			table.insert(lines, "  XP: " .. stats.season.xp)
			table.insert(lines, "  Progress: " .. string.format("%.1f%%", stats.season.progress_to_next * 100))
			table.insert(lines, "  XP to Next: " .. stats.season.xp_to_next)

			if stats.season.current_tier then
				table.insert(lines, "  Tier: " .. stats.season.current_tier.name)
			end
		end

		-- Top areas
		table.insert(lines, "")
		table.insert(lines, "Top Areas:")
		local top_areas = require("zortex.xp.areas").get_top_areas(5)
		for i, area in ipairs(top_areas) do
			table.insert(lines, string.format("  %d. %s - Level %d (%d XP)", i, area.path, area.level, area.xp))
		end

		-- Top projects
		table.insert(lines, "")
		table.insert(lines, "Top Projects:")
		local leaderboard = XPService.get_leaderboard("projects", 5)
		for i, proj in ipairs(leaderboard) do
			local status = proj.completed and "✓" or "○"
			table.insert(
				lines,
				string.format("  %d. %s %s - Level %d (%d XP)", i, status, proj.name, proj.level, proj.xp)
			)
		end

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)

		vim.cmd("split")
		vim.api.nvim_win_set_buf(0, buf)
	end, {})

	-- Test XP distribution
	vim.api.nvim_create_user_command("ZortexTestXPDistribution", function()
		local XPDistributor = require("zortex.domain.xp.distributor")

		local distribution = XPDistributor.distribute("task", "test123", 100, {
			project_name = "Test Project",
			area_links = { "[A/Tech/Neovim]", "[A/Personal/Learning]" },
		})

		print("Distribution result:")
		print(vim.inspect(distribution))
	end, {})

	-- Force buffer task processing
	vim.api.nvim_create_user_command("ZortexProcessTasks", function()
		local TaskService = require("zortex.services.task_service")
		local bufnr = vim.api.nconfig.get("t_current_buf")()

		local tasks = TaskService.process_buffer_tasks(bufnr)
		print(string.format("Processed %d tasks", #tasks))
	end, {})

	-- Monitor events
	vim.api.nvim_create_user_command("ZortexMonitorXPEvents", function(opts)
		local duration = tonumber(opts.args) or 60

		print("Monitoring XP events for " .. duration .. " seconds...")

		local events = {}
		local handlers = {}

		-- Set up temporary handlers
		local event_names = {
			"task:completing",
			"task:completed",
			"task:uncompleted",
			"xp:calculated",
			"xp:awarded",
			"xp:distributed",
			"xp:reversed",
		}

		for _, event in ipairs(event_names) do
			local handler = EventBus.on(event, function(data)
				table.insert(events, {
					event = event,
					time = os.date("%H:%M:%S"),
					data = data,
				})
				print(string.format("[%s] %s", os.date("%H:%M:%S"), event))
			end, {
				priority = 1,
				name = "monitor_" .. event,
			})
			table.insert(handlers, { event = event, handler = handler })
		end

		-- Clean up after duration
		vim.defer_fn(function()
			-- Remove handlers
			for _, h in ipairs(handlers) do
				EventBus.off(h.event, h.handler.handler)
			end

			print("\nMonitoring complete. " .. #events .. " events captured.")

			if #events > 0 then
				print("\nEvent summary:")
				local counts = {}
				for _, e in ipairs(events) do
					counts[e.event] = (counts[e.event] or 0) + 1
				end
				for event, count in pairs(counts) do
					print("  " .. event .. ": " .. count)
				end
			end
		end, duration * 1000)
	end, { nargs = "?" })
end

-- Get Phase 2 status
function M.get_status()
	local TaskService = require("zortex.services.task_service")
	local XPService = require("zortex.services.xp_service")
	local task_stats = require("zortex.stores.tasks").get_stats()
	local xp_stats = XPService.get_stats()

	return {
		initialized = M.initialized,
		components = M.components,
		tasks = {
			total = task_stats.total_tasks,
			completed = task_stats.completed_tasks,
			xp_awarded = task_stats.total_xp_awarded,
		},
		xp = {
			season = xp_stats.season,
			area_count = vim.tbl_count(xp_stats.areas),
			project_count = vim.tbl_count(xp_stats.projects),
		},
	}
end

-- Healthcheck
function M.healthcheck()
	local health = {
		initialized = M.initialized,
		components = {},
		integration = {},
	}

	-- Check components
	for component, initialized in pairs(M.components) do
		health.components[component] = {
			initialized = initialized,
			status = initialized and "OK" or "Not initialized",
		}
	end

	-- Check Phase 1 integration
	health.integration.phase1 = Phase1.initialized

	-- Check stores
	local xp_store = require("zortex.stores.xp")
	local task_store = require("zortex.stores.tasks")

	health.integration.stores = {
		xp = xp_store.get_season_data() and "OK" or "Error",
		tasks = task_store.get_stats() and "OK" or "Error",
	}

	-- Check event handlers
	local handlers = EventBus._instance.handlers
	health.integration.event_handlers = {
		task_completing = handlers["task:completing"] and #handlers["task:completing"] or 0,
		task_completed = handlers["task:completed"] and #handlers["task:completed"] or 0,
		xp_awarded = handlers["xp:awarded"] and #handlers["xp:awarded"] or 0,
	}

	return health
end

return M

