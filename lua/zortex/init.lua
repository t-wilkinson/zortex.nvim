-- init.lua - Main entry point for Zortex

-- Core modules
local Config = require("zortex.config")
local core = require("zortex.core")

-- Features
local highlights = require("zortex.features.highlights")
local completion = require("zortex.features.completion")

-- Initialize Zortex
local function setup(opts)
	-- Merge user config
	Config.setup(opts)

	-- Setup core systems
	core.setup(Config)

	-- Setup features
	highlights.setup()
	local has_cmp, cmp = pcall(require, "cmp")
	if has_cmp then
		cmp.register_source("zortex", completion.new())
	end

	-- Notifications
	-- require("zortex.notifications").setup(Config.notifications)

	-- Setup UI
	require("zortex.ui.commands").setup(Config.commands.prefix)
	require("zortex.ui.keymaps").setup(Config.keymaps.prefix, Config.commands.prefix)
	require("zortex.ui.calendar.view").setup(Config.ui.calendar)
	require("zortex.ui.telescope.search").setup(Config.ui.search)
	require("zortex.ui.telescope.core").setup()

	-- Setup performance monitoring
	local perf_monitor = require("zortex.core.performance_monitor")
	perf_monitor.setup_commands()

	if Config.debug then
		-- perf_monitor.start()
	end
end

local api = require("zortex.api")

api.setup = setup

return api
