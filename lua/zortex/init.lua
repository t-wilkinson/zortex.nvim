-- init.lua - Main entry point for Zortex

-- Core modules
local Config = require("zortex.config")
local core = require("zortex.core")

-- Features

-- Initialize Zortex
local function setup(opts)
	-- Merge user config
	Config.setup(opts)

	-- Setup core systems
	core.setup(Config)

	-- Setup features
	require("zortex.features.highlights").setup()
	require("zortex.features.folding").setup()

	local has_cmp, cmp = pcall(require, "cmp")
	if has_cmp then
		local completion = require("zortex.features.completion")
		cmp.register_source("zortex", completion.new())
	end

	-- Notifications
	require("zortex.notifications").setup(Config.notifications)

	-- Setup UI
	require("zortex.ui.commands").setup(Config.commands.prefix)
	require("zortex.ui.keymaps").setup(Config.keymaps.prefix, Config.commands.prefix)
	require("zortex.ui.calendar.view").setup(Config.ui.calendar)
	require("zortex.ui.telescope.search").setup(Config.ui.search)
	require("zortex.ui.telescope.core").setup()
end

local api = require("zortex.api")

api.setup = setup

return api
