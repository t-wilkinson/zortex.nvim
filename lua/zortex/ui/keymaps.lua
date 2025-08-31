-- ui/keymaps.lua
local M = {}
local api = require("zortex.api")

-- =============================================================================
-- Keymaps
-- =============================================================================

function M.setup(key_prefix, cmd_prefix)
	local default_opts = { noremap = true, silent = true }
	local function add_opts(with_opts)
		return vim.tbl_extend("force", default_opts, with_opts)
	end

	local map = function(modes, key, cmd, opts)
		if type(cmd) == "string" then
			vim.keymap.set(modes, key_prefix .. key, "<cmd>" .. cmd_prefix .. cmd .. "<cr>", opts)
		else
			vim.keymap.set(modes, key_prefix .. key, cmd, opts)
		end
	end

	map("n", "r", "FoldsReload", add_opts({ desc = "Open Zortex link" }))

	-- Navigation
	map("n", "gx", "OpenLink", add_opts({ desc = "Open Zortex link" }))
	-- map("n", "<CR>", "OpenLink", add_opts({ desc = "Open Zortex link" }))
	map("n", "z", "SearchAll", add_opts({ desc = "Zortex search" }))
	map("n", "Z", "SearchAll", add_opts({ desc = "Zortex search" }))
	-- map("n", "?", function()
	--   require("zortex.ui.search").search_current_file()
	-- end, { desc = "Search current file" })

	map("n", "d", "Digest", add_opts({ desc = "Open daily digest" }))
	map("n", "D", "DigestUpdate", add_opts({ desc = "Update daily digest " }))

	-- Calendar
	map("n", "c", "Calendar", { desc = "Open calendar" })
	-- map("n", "A", "CalendarAdd", { desc = "Add calendar entry" })

	-- Archive keymaps
	map("n", "a", function()
		api.archive.section()
	end, { desc = "Archive current project" })

	-- Telescope
	-- map("n", "t", "Today", { desc = "Today's digest" })
	-- map("n", "p", "Projects", { desc = "Browse projects" })
	-- map("n", "f", "Telescope", { desc = "Zortex telescope" })

	-- Projects
	map("n", "P", "ProjectsOpen", add_opts({ desc = "Open projects" }))
	map("n", "u", "UpdateProgress", { desc = "Update progress" })
	-- map("n", prefix .. "pp", function()
	-- 	vim.cmd("ZortexProjectProgress")
	-- end, { desc = "Update project progress" })
	-- map("n", prefix .. "ps", function()
	-- 	vim.cmd("ZortexProjectStats")
	-- end, { desc = "Project statistics" })

	-- XP System
	map("n", "k", "SkillTree", add_opts({ desc = "Show skill tree" }))
	map("n", "xi", function()
		api.xp.overview()
	end, { desc = "XP info" })
	map("n", "xs", function()
		api.xp.stats()
	end, { desc = "XP stats" })

	-- Seasons
	-- map("n", key_prefix .. "ss", ":" .. cmd_prefix .. "SeasonStatus<CR>", { desc = "Season status" })
	-- map("n", key_prefix .. "sn", ":" .. cmd_prefix .. "SeasonStart<CR>", { desc = "Start new season" })
	-- map("n", key_prefix .. "se", ":" .. cmd_prefix .. "SeasonEnd<CR>", { desc = "End season" })

	-- Quick access to main files
	map("n", "fp", "OpenProjects", { desc = "Open projects file" })
	map("n", "fa", "OpenAreas", { desc = "Open areas file" })
	map("n", "fc", "OpenCalendar", { desc = "Open calendar file" })
	map("n", "fo", "OpenOKR", { desc = "Open OKR file" })

	-- Task mappings
	map("n", "T", "TaskToggle", add_opts({ desc = "Toggle current task" }))
	map("n", "tc", "TaskComplete", { desc = "Complete task" })
	map("n", "tu", "TaskUncomplete", { desc = "Uncomplete task" })

	-- -- Status and debugging
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

	-- vim.api.nvim_create_autocmd("FileType", {
	-- 	pattern = "zortex",
	-- 	callback = function()
	-- 		-- Link navigation
	-- 		map("n", "<CR>", function()
	-- 			require("zortex.navigation").follow_link()
	-- 		end, { buffer = true, desc = "Follow link" })

	-- 		map("n", "<BS>", function()
	-- 			require("zortex.navigation").go_back()
	-- 		end, { buffer = true, desc = "Go back" })

	-- 		-- Section navigation
	-- 		map("n", "]]", function()
	-- 			require("zortex.navigation").next_section()
	-- 		end, { buffer = true, desc = "Next section" })

	-- 		map("n", "[[", function()
	-- 			require("zortex.navigation").prev_section()
	-- 		end, { buffer = true, desc = "Previous section" })
	-- 	end,
	-- })
end

return M
