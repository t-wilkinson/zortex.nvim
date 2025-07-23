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
end

return M
