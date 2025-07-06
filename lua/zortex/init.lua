local M = {}

M.defaults = {
	zortex_remote_server = "",
	zortex_remote_server_dir = "/www/zortex",
	zortex_remote_wiki_port = "8080",
	zortex_auto_start_server = false,
	zortex_auto_start_preview = true,
	zortex_special_articles = { "structure", "inbox" },
	zortex_auto_close = true,
	zortex_refresh_slow = false,
	zortex_command_for_global = false,
	zortex_open_to_the_world = false,
	zortex_open_ip = "",
	zortex_echo_preview_url = false,
	zortex_browserfunc = "",
	zortex_browser = "",
	zortex_markdown_css = "",
	zortex_highlight_css = "",
	zortex_port = "8080",
	zortex_page_title = "「${name}」",
	zortex_filetype = "zortex",
	zortex_extension = ".zortex",
	zortex_window_direction = "down",
	zortex_window_width = "40%",
	zortex_window_command = "",
	zortex_preview_direction = "right",
	zortex_preview_width = "",
	zortex_root_dir = vim.fn.expand("$HOME/.zortex") .. "/",
	zortex_notes_dir = vim.fn.expand("$HOME/.zortex") .. "/",
	zortex_preview_options = {
		mkit = {},
		katex = {},
		uml = {},
		maid = {},
		disable_sync_scroll = 0,
		sync_scroll_type = "middle",
		hide_yaml_meta = 1,
		sequence_diagrams = {},
		flowchart_diagrams = {},
		content_editable = false,
		disable_filename = 0,
		toc = {},
	},
}

M.options = {}

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})

	for k, v in pairs(M.options) do
		vim.g[k] = v
	end

	M.init()
end

function M.init()
	local search = require("zortex.search")
	local links = require("zortex.links")
	local calendar = require("zortex.calendar")
	local xp = require("zortex.xp")
	local telescope = require("zortex.telescope")

	local cmd = vim.api.nvim_create_user_command

	-- Telescope functions
	cmd("ZortexCalendarSearch", telescope.calendar, { desc = "Browse calendar chronologically" })
	cmd("ZortexDigestTelescope", telescope.today_digest, { desc = "Show today's digest in Telescope" })
	cmd("ZortexProjects", telescope.today_digest, { desc = "Show today's digest in Telescope" })

	-- Searching
	cmd("ZortexOpenLink", links.open_link, {})
	cmd("ZortexSearch", search.search, {})

	-- Create keymaps
	vim.keymap.set("n", "Zc", calendar.open, { desc = "Open Zortex Calendar" })

	-- Telescope keymaps
	vim.keymap.set("n", "ZC", telescope.calendar, { desc = "Search calendar entries" })
	vim.keymap.set("n", "Zp", telescope.projects, { desc = "Search projects" })

	-- Digest
	vim.keymap.set("n", "Zd", telescope.today_digest)
	vim.keymap.set("n", "ZD", calendar.show_today_digest, {
		desc = "Show Today's Digest",
	})
	vim.keymap.set("n", "ZB", calendar.show_digest_buffer)

	calendar.setup()
	xp.setup()
end

M.setup()

return M
