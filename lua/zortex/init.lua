-- init.lua - require("zortex"): setup() plus the public API (zortex.api)
local api = require("zortex.api")

function api.setup(opts)
	if vim.fn.has("nvim-0.10") == 0 then
		vim.notify("zortex.nvim needs Neovim 0.10 or newer", vim.log.levels.ERROR)
		return
	end
	local Config = require("zortex.config")
	Config.setup(opts)

	-- A new notes folder gets the key notes (calendar, projects, ...)
	require("zortex.core.starter").setup(Config.init_files)

	-- Core: logger, events, workspace, link index, XP pipeline
	require("zortex.core").setup(Config)

	-- Editor features
	require("zortex.features.highlights").setup()
	require("zortex.features.folding").setup()
	require("zortex.features.preview").setup(Config.ui.preview)
	require("zortex.features.completion").setup()

	-- Services with configuration
	require("zortex.services.search").setup(Config.ui.search)
	require("zortex.ui.calendar.view").setup(Config.ui.calendar)
	require("zortex.notifications").setup(Config.notifications)

	-- Commands and keymaps, both generated from zortex.actions
	local actions = require("zortex.actions")
	actions.create_commands(Config.commands.prefix)
	if Config.keymaps.enabled ~= false then
		actions.create_keymaps(Config.keymaps.prefix, Config.keymaps.mappings)
		if Config.keymaps.groups ~= false then
			actions.register_which_key(Config.keymaps.prefix, Config.keymaps.mappings, Config.keymaps.groups)
		end
	end
end

return api
