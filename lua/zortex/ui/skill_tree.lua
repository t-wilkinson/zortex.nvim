-- ui/skill_tree.lua - Skill tree popup display for Zortex
local M = {}

local config = require("zortex.config")
local constants = require("zortex.constants")
local skills = require("zortex.features.skills")

-- =============================================================================
-- Display Helpers
-- =============================================================================

-- Create progress bar string
local function create_progress_bar(progress, width)
	local filled = math.floor(progress * width)
	local empty = width - filled
	return string.rep("█", filled) .. string.rep("░", empty)
end

-- Get highlight group for level
local function get_level_highlight(level)
	if level <= 3 then
		return constants.HIGHLIGHTS.SKILL_LEVEL_1_3
	elseif level <= 6 then
		return constants.HIGHLIGHTS.SKILL_LEVEL_4_6
	elseif level <= 9 then
		return constants.HIGHLIGHTS.SKILL_LEVEL_7_9
	else
		return constants.HIGHLIGHTS.SKILL_LEVEL_10_PLUS
	end
end

-- =============================================================================
-- Tree Rendering
-- =============================================================================

-- Render node and its children
local function render_node(node, lines, highlights, indent_level)
	indent_level = indent_level or 0
	local indent = string.rep("  ", indent_level)

	-- Skip root node in display
	if node.level > 0 then
		-- Calculate level and progress
		local level, progress, current_xp, next_xp = skills.calculate_level(node.total_xp)

		-- Create line
		local line = string.format("%s%s", indent, node.name)
		local level_text = string.format(" [Lvl %d]", level)
		local xp_text = string.format(" (%d XP)", math.floor(node.total_xp))

		table.insert(lines, line .. level_text .. xp_text)
		local line_num = #lines

		-- Add highlights
		local hl_group = get_level_highlight(level)
		table.insert(highlights, {
			line = line_num - 1,
			col_start = #line,
			col_end = #line + #level_text,
			group = hl_group,
		})

		-- Add progress bar for non-deep nodes
		if next_xp and indent_level < 3 then
			local bar = create_progress_bar(progress, 20)
			local progress_line = string.format("%s  %s %.0f%%", indent, bar, progress * 100)
			table.insert(lines, progress_line)

			-- Highlight progress bar
			table.insert(highlights, {
				line = #lines - 1,
				col_start = #indent + 2,
				col_end = #indent + 2 + #bar,
				group = constants.HIGHLIGHTS.PROGRESS_BAR,
			})
		end
	end

	-- Render children
	for _, child in ipairs(node.children) do
		render_node(child, lines, highlights, node.level > 0 and indent_level + 1 or 0)
	end
end

-- =============================================================================
-- Popup Creation
-- =============================================================================

-- Show skill tree popup
function M.show()
	-- Get the area tree
	local area_tree = skills.get_area_tree()
	if not area_tree then
		vim.notify("No areas.zortex file found", vim.log.levels.WARN)
		return
	end

	local cfg = config.get("ui.skill_tree")

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "filetype", "zortex-skill-tree")

	-- Render tree
	local lines = {}
	local highlights = {}

	-- Add header
	table.insert(lines, "SKILL TREE")
	table.insert(lines, string.rep("=", 50))
	table.insert(lines, "")

	-- Render tree starting from root
	render_node(area_tree, lines, highlights)

	-- Add footer
	table.insert(lines, "")
	table.insert(lines, string.rep("-", 50))
	table.insert(lines, "Press 'q' or <Esc> to close")

	-- Set buffer content
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Apply highlights
	for _, hl in ipairs(highlights) do
		vim.api.nvim_buf_add_highlight(buf, -1, hl.group, hl.line, hl.col_start, hl.col_end)
	end

	-- Create window
	local win_config = {
		relative = "editor",
		width = cfg.width,
		height = cfg.height,
		col = math.floor((vim.o.columns - cfg.width) / 2),
		row = math.floor((vim.o.lines - cfg.height) / 2),
		style = "minimal",
		border = cfg.border,
	}

	local win = vim.api.nvim_open_win(buf, true, win_config)

	-- Set keymaps
	local opts = { noremap = true, silent = true, buffer = buf }
	vim.keymap.set("n", "q", ":close<CR>", opts)
	vim.keymap.set("n", "<Esc>", ":close<CR>", opts)

	-- Make buffer read-only
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

return M
