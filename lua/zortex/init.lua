local open_link = require("zortex.open_link")
local search = require("zortex.search")

local M = {}

M.defaults = {
	zortex_remote_server = "",
	zortex_remote_server_dir = "/www/zortex",
	zortex_remote_wiki_port = "8080",
	zortex_auto_start_server = false,
	zortex_auto_start_preview = true,
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
end

function M.init()
	local opts = M.options

	-- Legacy access
	for k, v in pairs(M.options) do
		vim.g[k] = v
	end

	vim.keymap.set("n", "Zo", function()
		open_link.open_link_in_split()
	end, { desc = "Open link in split (structure navigation)" })

	vim.api.nvim_create_user_command("ZortexOpenLinkSplit", open_link.open_link_in_split, {})
	vim.api.nvim_create_user_command("ZortexOpenLink", open_link.open_link, {})
	vim.api.nvim_create_user_command("ZortexSearch", search.search, {})
	-- vim.api.nvim_create_user_command("ZortexOpenLink", links.open_link, {
	-- 	bang = false, -- No !bang support for now
	-- 	nargs = "0", -- No arguments
	-- 	desc = "Open Zortex link under cursor",
	-- })
end

M.init()

return M
