-- init.lua - require("zortex"): setup() plus the public API (zortex.api)
local api = require("zortex.api")

-- :help zortex needs doc/tags. Plugin managers make it on install, but not
-- for a plugin loaded from a local folder (lazy.nvim's dir = / dev = true),
-- so make it here when it is missing or older than doc/zortex.txt and the
-- folder is writable (not, say, the Nix store).
function api.helptags()
	local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
	local doc = root .. "/doc"
	local txt, tags = doc .. "/zortex.txt", doc .. "/tags"
	if vim.fn.filereadable(txt) == 0 or vim.fn.filewritable(doc) ~= 2 then
		return false
	end
	if vim.fn.getftime(tags) >= vim.fn.getftime(txt) then
		return true
	end
	return (pcall(vim.cmd.helptags, vim.fn.fnameescape(doc)))
end

function api.setup(opts)
	if vim.fn.has("nvim-0.10") == 0 then
		vim.notify("zortex.nvim needs Neovim 0.10 or newer", vim.log.levels.ERROR)
		return
	end
	local Config = require("zortex.config")
	Config.setup(opts)
	-- the note format's knobs, before anything parses a note
	require("zortex.core.syntax_config").setup(Config.syntax, vim.tbl_get(Config, "ui", "calendar", "group_days"))

	api.helptags()

	-- Say which key notes are missing (:Zortex init creates them), and
	-- whether a sync tool left conflict copies (:ZortexConflicts)
	require("zortex.core.starter").setup()
	if Config.notes_dir then
		require("zortex.features.conflicts").setup()
	end

	-- Core: logger, events, workspace, link index, XP pipeline
	require("zortex.core").setup(Config)

	-- Editor features
	require("zortex.features.highlights").setup()
	require("zortex.features.folding").setup()
	require("zortex.features.preview").setup(Config.ui.preview)
	require("zortex.features.completion").setup()
	require("zortex.features.diagnostics").setup((Config.features or {}).diagnostics)
	require("zortex.features.size_hint").setup((Config.features or {}).size_hint)

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
