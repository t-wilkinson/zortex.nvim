-- ui/skill_tree.lua - Revamped Skill Tree UI for dual progression system
local M = {}

local config = require("zortex.config")
local constants = require("zortex.constants")
local xp_stats = require("zortex.services.xp.stats")
local areas = require("zortex.services.areas")
local projects = require("zortex.services.projects")

-- =============================================================================
-- Display Helpers
-- =============================================================================

-- Default highlight links (users can override the groups)
local function define_highlights()
	local links = {
		[constants.HIGHLIGHTS.SKILL_LEVEL_1_3] = "Comment",
		[constants.HIGHLIGHTS.SKILL_LEVEL_4_6] = "String",
		[constants.HIGHLIGHTS.SKILL_LEVEL_7_9] = "Function",
		[constants.HIGHLIGHTS.SKILL_LEVEL_10_PLUS] = "Special",
		[constants.HIGHLIGHTS.PROGRESS_BAR] = "DiagnosticOk",
	}
	for group, link in pairs(links) do
		vim.api.nvim_set_hl(0, group, { link = link, default = true })
	end
end

-- Create progress bar
local function create_progress_bar(progress, width)
	local filled = math.floor(progress * width)
	local empty = width - filled
	return string.rep("█", filled) .. string.rep("░", empty)
end

-- Format XP number
local function format_xp(xp)
	if xp >= 1000000 then
		return string.format("%.1fM", xp / 1000000)
	elseif xp >= 1000 then
		return string.format("%.1fK", xp / 1000)
	else
		return tostring(math.floor(xp + 0.5))
	end
end

-- Get highlight group for area level
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
-- Season Display
-- =============================================================================

local function render_season_section(lines, highlights)
	local status = xp_stats.season_status()

	table.insert(lines, "")
	table.insert(lines, "━━━ SEASON PROGRESS ━━━")
	table.insert(lines, "")

	if not status then
		table.insert(lines, "No active season. Use :ZortexSeasonStart to begin!")
		return
	end

	-- Season info
	table.insert(lines, string.format("Season: %s", status.season.name))
	table.insert(lines, string.format("Period: %s to %s", status.season.start_date, status.season.end_date))
	table.insert(lines, "")

	-- Current tier and level
	local tier_text = status.current_tier and status.current_tier.name or "None"
	table.insert(lines, string.format("Level %d │ %s Tier", status.level, tier_text))

	-- XP and progress
	table.insert(lines, string.format("XP: %s", format_xp(status.xp)))

	-- Progress bar to next level
	local bar = create_progress_bar(status.progress_to_next, 30)
	table.insert(lines, bar .. string.format(" %.0f%%", status.progress_to_next * 100))

	-- Highlight progress bar
	table.insert(highlights, {
		line = #lines - 1,
		col_start = 0,
		col_end = 30,
		group = constants.HIGHLIGHTS.PROGRESS_BAR,
	})

	-- Next tier info
	if status.next_tier then
		table.insert(lines, "")
		table.insert(
			lines,
			string.format("Next: %s Tier (Level %d)", status.next_tier.name, status.next_tier.required_level)
		)
	else
		table.insert(lines, "")
		table.insert(lines, "MAX TIER REACHED! 🏆")
	end

	-- Project stats
	local active_projects = 0
	local completed_projects = 0

	for _, project in ipairs(projects.all({ include_roots = false })) do
		if project:is_done() then
			completed_projects = completed_projects + 1
		elseif project:stats().done > 0 then
			active_projects = active_projects + 1
		end
	end

	table.insert(lines, "")
	table.insert(lines, string.format("Projects: %d active, %d completed", active_projects, completed_projects))
end

-- =============================================================================
-- Area Tree Display
-- =============================================================================

-- Render an Area (services/areas) and its sub-areas. Levels come from the
-- area's total XP (sub-areas included).
local function render_area_node(node, lines, highlights, indent_level)
	indent_level = indent_level or 0
	local indent = string.rep("  ", indent_level)
	local show_self = not node:is_root()

	if show_self then
		local data = node:xp_data()
		if data.total_xp > 0 and data.level then
			local level_str = string.format("[Lvl %d]", data.level)
			table.insert(lines, string.format("%s%s %s (%s XP)", indent, node.name, level_str, format_xp(data.total_xp)))

			local level_start = #indent + #node.name + 1
			table.insert(highlights, {
				line = #lines - 1,
				col_start = level_start,
				col_end = level_start + #level_str,
				group = get_level_highlight(data.level),
			})

			if indent_level < 3 and data.progress then
				local bar = create_progress_bar(data.progress, 20)
				table.insert(lines, string.format("%s  %s %.0f%% to next", indent, bar, data.progress * 100))
				table.insert(highlights, {
					line = #lines - 1,
					col_start = #indent + 2,
					col_end = #indent + 22,
					group = constants.HIGHLIGHTS.PROGRESS_BAR,
				})
			end
		else
			table.insert(lines, indent .. node.name .. " [No XP]")
		end
	end

	for _, child in ipairs(node.children) do
		render_area_node(child, lines, highlights, show_self and (indent_level + 1) or indent_level)
	end
end

-- =============================================================================
-- Top Areas Section
-- =============================================================================

local function render_top_areas(tree, lines, highlights)
	table.insert(lines, "")
	table.insert(lines, "━━━ TOP AREAS ━━━")
	table.insert(lines, "")

	local top_areas = areas.top(5)

	if #top_areas == 0 then
		table.insert(lines, "No areas with XP yet!")
		return
	end

	for i, area in ipairs(top_areas) do
		local line = string.format("%d. %s - Level %s (%s XP)", i, area.name, tostring(area.level or "?"), format_xp(area.xp))
		table.insert(lines, line)

		-- Highlight rank number
		table.insert(highlights, {
			line = #lines - 1,
			col_start = 0,
			col_end = 2,
			group = get_level_highlight(area.level or 1),
		})
	end
end

-- =============================================================================
-- Main Show Function
-- =============================================================================

function M.show()
	define_highlights()

	-- Get area tree
	local tree = areas.get_area_tree()
	if not tree then
		vim.notify("No areas.zortex file found", vim.log.levels.WARN)
		return
	end

	local cfg = vim.tbl_extend(
		"force",
		{ width = 80, height = 35, border = "rounded" },
		(config.ui and config.ui.skill_tree) or {}
	)

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "filetype", "zortex-skill-tree")

	-- Render content
	local lines = {}
	local highlights = {}

	-- Header
	table.insert(
		lines,
		"╔═══════════════════════════════════════╗"
	)
	table.insert(lines, "║         ZORTEX PROGRESSION            ║")
	table.insert(
		lines,
		"╚═══════════════════════════════════════╝"
	)

	-- Season section
	render_season_section(lines, highlights)

	-- Top areas
	render_top_areas(tree, lines, highlights)

	-- Area tree
	table.insert(lines, "")
	table.insert(lines, "━━━ AREA MASTERY TREE ━━━")
	table.insert(lines, "")
	render_area_node(tree, lines, highlights)

	-- Footer
	table.insert(lines, "")
	table.insert(lines, string.rep("─", 50))
	table.insert(lines, "Commands: q - close │ r - refresh │ s - season info")

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
	vim.keymap.set("n", "r", function()
		vim.api.nvim_win_close(win, true)
		M.show()
	end, opts)
	vim.keymap.set("n", "s", function()
		local status = xp_stats.season_status()
		if status then
			print(vim.inspect(status))
		else
			print("No active season")
		end
	end, opts)

	-- Make buffer read-only
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

return M
