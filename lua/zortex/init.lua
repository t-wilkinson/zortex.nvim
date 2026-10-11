-- init.lua - require("zortex"): setup() plus the public API (zortex.api)
local api = require("zortex.api")

function api.setup(opts)
	local Config = require("zortex.config")
	Config.setup(opts)

	-- Core: logger, events, workspace, link index, XP pipeline
	require("zortex.core").setup(Config)

	-- Editor features
	require("zortex.features.highlights").setup()
	require("zortex.features.folding").setup()
	local has_cmp, cmp = pcall(require, "cmp")
	if has_cmp then
		cmp.register_source("zortex", require("zortex.features.completion").new())
	end

	-- Services with configuration
	require("zortex.services.search").setup(Config.ui.search)
	require("zortex.ui.calendar.view").setup(Config.ui.calendar)
	require("zortex.notifications").setup(Config.notifications)

	-- Commands and keymaps, both generated from zortex.actions
	local actions = require("zortex.actions")
	actions.create_commands(Config.commands.prefix)
	if Config.keymaps.enabled ~= false then
		actions.create_keymaps(Config.keymaps.prefix, Config.keymaps.mappings)
	end

	require("zortex.ui.telescope.core").setup()
end

return api
