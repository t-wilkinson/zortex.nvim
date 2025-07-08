-- lua/zortex/completion_setup.lua - Setup nvim-cmp integration for Zortex
local M = {}

function M.setup()
	-- Setup nvim-cmp if available
	local ok, cmp = pcall(require, "cmp")
	if not ok then
		vim.notify("nvim-cmp not found. Install it for context-aware completions.", vim.log.levels.WARN)
		return
	end

	-- Register the Zortex source
	local zortex_source = require("zortex.cmp_source")
	cmp.register_source("zortex", zortex_source.new())

	-- Get existing config
	local config = cmp.get_config()

	-- Add Zortex source to existing sources
	local sources = config.sources or {}

	-- Check if zortex source is already added
	local has_zortex = false
	for _, source in ipairs(sources) do
		if source.name == "zortex" then
			has_zortex = true
			break
		end
	end

	if not has_zortex then
		-- Add zortex source with high priority for .zortex files
		table.insert(sources, 1, {
			name = "zortex",
			priority = 1000,
			option = {
				-- Add any source-specific options here
			},
		})

		-- Update cmp configuration
		cmp.setup({
			sources = sources,
		})
	end

	-- Setup buffer-specific configuration for .zortex files
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "zortex",
		callback = function()
			cmp.setup.buffer({
				sources = {
					{ name = "zortex", priority = 1000 },
					{ name = "buffer", priority = 500 },
					{ name = "path", priority = 250 },
				},
			})
		end,
	})

	-- Also setup for files with .zortex extension
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		pattern = "*.zortex",
		callback = function()
			vim.bo.filetype = "zortex"

			-- Ensure cmp is configured for this buffer
			cmp.setup.buffer({
				sources = {
					{ name = "zortex", priority = 1000 },
					{ name = "buffer", priority = 500 },
					{ name = "path", priority = 250 },
				},
			})
		end,
	})

	vim.notify("Zortex completions configured successfully!", vim.log.levels.INFO)
end

-- Manual setup function that users can call
function M.setup_keymaps()
	-- Optional: Add keymaps for manual completion triggering
	vim.keymap.set("i", "<C-Space>", function()
		require("cmp").complete({
			config = {
				sources = {
					{ name = "zortex" },
				},
			},
		})
	end, { desc = "Trigger Zortex completions" })
end

return M
