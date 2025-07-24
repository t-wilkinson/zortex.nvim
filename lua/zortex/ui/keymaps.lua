-- ui/keymaps.lua
local M = {}

-- =============================================================================
-- Keymaps
-- =============================================================================

function M.setup(key_prefix, cmd_prefix)
	local default_opts = { noremap = true, silent = true }
	local function add_opts(with_opts)
		return vim.tbl_extend("force", default_opts, with_opts)
	end

	local map = function(modes, key, cmd, opts)
		vim.keymap.set(modes, key_prefix .. key, "<cmd>" .. cmd_prefix .. cmd .. "<cr>", opts)
	end

	-- Navigation
	map("n", "s", "Search", add_opts({ desc = "Zortex search" }))
	map("n", "gx", "OpenLink", add_opts({ desc = "Open Zortex link" }))
	-- map("n", "<CR>", "OpenLink", add_opts({ desc = "Open Zortex link" }))

	-- Calendar
	map("n", "c", "Calendar", { desc = "Open calendar" })
	map("n", "A", "CalendarAdd", { desc = "Add calendar entry" })

	-- Telescope
	map("n", "t", "Today", { desc = "Today's digest" })
	map("n", "p", "Projects", { desc = "Browse projects" })
	map("n", "f", "Telescope", { desc = "Zortex telescope" })

	-- Projects
	map("n", "P", "ProjectsOpen", add_opts({ desc = "Open projects" }))
	map("n", "a", "ArchiveProject", add_opts({ desc = "Archive project" }))
	map("n", "x", "ToggleTask", add_opts({ desc = "Toggle current task" }))

	-- Progress
	map("n", "u", "UpdateProgress", { desc = "Update progress" })

	-- XP System
	map("n", "k", "SkillTree", add_opts({ desc = "Show skill tree" }))

	-- local opts = { noremap = true, silent = true }
	--
	-- -- Task keymaps
	-- vim.keymap.set("n", key_prefix .. "t", ":" .. cmd_prefix .. "ToggleTask<CR>",
	--   vim.tbl_extend("force", opts, { desc = "Toggle task" }))
	--
	-- vim.keymap.set("n", key_prefix .. "T", ":" .. cmd_prefix .. "ConvertToTask<CR>",
	--   vim.tbl_extend("force", opts, { desc = "Convert to task" }))
	--
	-- -- XP keymaps
	-- vim.keymap.set("n", key_prefix .. "x", ":" .. cmd_prefix .. "XPOverview<CR>",
	--   vim.tbl_extend("force", opts, { desc = "XP overview" }))
	--
	-- vim.keymap.set("n", key_prefix .. "X", ":" .. cmd_prefix .. "XPStats<CR>",
	--   vim.tbl_extend("force", opts, { desc = "XP statistics" }))
	--
	-- -- Season keymaps
	-- vim.keymap.set("n", key_prefix .. "ss", ":" .. cmd_prefix .. "SeasonStatus<CR>",
	--   vim.tbl_extend("force", opts, { desc = "Season status" }))
	--
	-- vim.keymap.set("n", key_prefix .. "sn", ":" .. cmd_prefix .. "SeasonStart<CR>",
	--   vim.tbl_extend("force", opts, { desc = "Start new season" }))
	--
	-- vim.keymap.set("n", key_prefix .. "se", ":" .. cmd_prefix .. "SeasonEnd<CR>",
	--   vim.tbl_extend("force", opts, { desc = "End season" }))
	--
	-- -- Search keymaps
	-- vim.keymap.set("n", key_prefix .. "/", function()
	--   require("zortex.ui.search").search()
	-- end, vim.tbl_extend("force", opts, { desc = "Search Zortex" }))
	--
	-- vim.keymap.set("n", key_prefix .. "?", function()
	--   require("zortex.ui.search").search_current_file()
	-- end, vim.tbl_extend("force", opts, { desc = "Search current file" }))
	--
	-- -- Project keymaps
	-- vim.keymap.set("n", key_prefix .. "p", function()
	--   require("zortex.ui.telescope").projects()
	-- end, vim.tbl_extend("force", opts, { desc = "Browse projects" }))
	--
	-- -- Calendar keymaps
	-- vim.keymap.set("n", key_prefix .. "c", function()
	--   require("zortex.ui.calendar_view").toggle()
	-- end, vim.tbl_extend("force", opts, { desc = "Toggle calendar" }))
	--
	-- -- Archive keymaps
	-- vim.keymap.set("n", key_prefix .. "a", function()
	--   require("zortex.features.archive").archive_current_project()
	-- end, vim.tbl_extend("force", opts, { desc = "Archive current project" }))
	--
	-- -- Link navigation
	-- vim.keymap.set("n", key_prefix .. "o", function()
	--   require("zortex.features.links").open_link()
	-- end, vim.tbl_extend("force", opts, { desc = "Open link" }))
	--
	-- -- Status and debugging
	-- vim.keymap.set("n", key_prefix .. "S", ":" .. cmd_prefix .. "Status<CR>",
	--   vim.tbl_extend("force", opts, { desc = "System status" }))
	--
	-- -- Which-key integration (if available)
	-- local ok, which_key = pcall(require, "which-key")
	-- if ok then
	--   which_key.register({
	--     [key_prefix] = {
	--       name = "+zortex",
	--       t = "Toggle task",
	--       T = "Convert to task",
	--       x = "XP overview",
	--       X = "XP statistics",
	--       s = {
	--         name = "+season",
	--         s = "Status",
	--         n = "New season",
	--         e = "End season",
	--       },
	--       ["/"] = "Search all",
	--       ["?"] = "Search file",
	--       p = "Projects",
	--       c = "Calendar",
	--       a = "Archive project",
	--       o = "Open link",
	--       S = "System status",
	--     }
	--   })
	-- end
end

return M
