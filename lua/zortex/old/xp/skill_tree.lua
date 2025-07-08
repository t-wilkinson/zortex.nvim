-- skill_tree.lua - Skill tree system for tracking area-based XP progression
local M = {}

-- Dependencies
local utils = require("zortex.utils")
local links = require("zortex.links")

-- Default configuration
M.defaults = {
	-- XP distribution curve (how XP is distributed across multiple areas)
	distribution_curve = "even", -- "even", "weighted", "primary"
	distribution_weights = {
		primary = 0.7, -- Primary area gets 70%
		secondary = 0.2, -- Secondary areas share 20%
		tertiary = 0.1, -- Remaining areas share 10%
	},

	-- XP bubble-up multiplier (XP multiplies as it goes up the tree)
	bubble_multiplier = 1.2,

	-- Objective XP based on span (exponential curve)
	objective_base_xp = {
		M = 100, -- Monthly
		Q = 300, -- Quarterly
		Y = 1000, -- Yearly
		["5Y"] = 4000, -- 5 Year
		["10Y"] = 12000, -- 10 Year
	},

	-- Key result completion curve (% of objective XP)
	kr_completion_curve = {
		[0.1] = 0.05, -- 10% complete = 5% XP
		[0.2] = 0.12, -- 20% complete = 12% XP
		[0.3] = 0.20, -- 30% complete = 20% XP
		[0.4] = 0.30, -- 40% complete = 30% XP
		[0.5] = 0.42, -- 50% complete = 42% XP
		[0.6] = 0.55, -- 60% complete = 55% XP
		[0.7] = 0.70, -- 70% complete = 70% XP
		[0.8] = 0.82, -- 80% complete = 82% XP
		[0.9] = 0.92, -- 90% complete = 92% XP
		[1.0] = 1.00, -- 100% complete = 100% XP
	},

	-- Level thresholds (XP needed for each level)
	level_thresholds = {
		100, -- Level 1
		300, -- Level 2
		600, -- Level 3
		1000, -- Level 4
		1500, -- Level 5
		2200, -- Level 6
		3000, -- Level 7
		4000, -- Level 8
		5200, -- Level 9
		6600, -- Level 10
	},

	-- Visual settings for popup
	popup = {
		width = 80,
		height = 30,
		border = "rounded",
		highlight_groups = {
			level_1_3 = "DiagnosticWarn",
			level_4_6 = "DiagnosticInfo",
			level_7_9 = "DiagnosticOk",
			level_10_plus = "DiagnosticHint",
			progress_bar = "IncSearch",
			progress_bg = "NonText",
		},
	},
}

-- Current configuration
M.config = {}

-- Cached area tree
M.area_tree = nil
M.area_tree_timestamp = nil

-- Cached XP data
M.area_xp = {}

-- =============================================================================
-- Tree Structure
-- =============================================================================

--- Node in the area tree
-- @class AreaNode
-- @field name string Display name
-- @field path string Full path in tree
-- @field level number Depth in tree (1 for root)
-- @field children table Array of child nodes
-- @field parent AreaNode|nil Parent node
-- @field xp number Current XP for this node
-- @field total_xp number Total XP including children

--- Get heading level from line
local function get_heading_level(line)
	local level = 0
	for i = 1, #line do
		if line:sub(i, i) == "#" then
			level = level + 1
		else
			break
		end
	end
	-- Only count as heading if followed by space or end of string
	if level > 0 and (line:sub(level + 1, level + 1) == " " or level == #line) then
		return level
	end
	return 0
end

--- Create a new area node
local function create_node(name, path, level, parent)
	return {
		name = name,
		path = path,
		level = level,
		children = {},
		parent = parent,
		xp = 0,
		total_xp = 0,
	}
end

-- =============================================================================
-- Area Tree Parsing
-- =============================================================================

--- Parse areas.zortex and build tree structure
local function parse_areas_file()
	local areas_file = utils.get_file_path(utils.AREAS_FILE)
	if not areas_file or vim.fn.filereadable(areas_file) == 0 then
		return nil
	end

	local lines = utils.read_file_lines(areas_file)
	if not lines then
		return nil
	end

	-- Root node
	local root = create_node("Areas", "", 0, nil)
	local current_nodes = { [0] = root }

	for _, line in ipairs(lines) do
		-- Skip empty lines
		if line:match("^%s*$") then
			goto continue
		end

		-- Check for heading
		local heading_level = get_heading_level(line)
		if heading_level > 0 then
			local text = line:match("^#+ (.+)$")
			if text then
				-- Clean text of attributes
				text = text:gsub(" @%w+%([^%)]*%)", ""):gsub(" @%w+", ""):match("^%s*(.-)%s*$")

				-- Find parent
				local parent_level = heading_level - 1
				while parent_level >= 0 and not current_nodes[parent_level] do
					parent_level = parent_level - 1
				end

				local parent = current_nodes[parent_level] or root
				local path = parent.path .. "/" .. text
				if parent == root then
					path = text
				end

				local node = create_node(text, path, heading_level, parent)
				table.insert(parent.children, node)
				current_nodes[heading_level] = node

				-- Clear deeper levels
				for level = heading_level + 1, 10 do
					current_nodes[level] = nil
				end
			end
		else
			-- Check for label
			local label = line:match("^(%w[^:]*):$")
			if label then
				-- Find parent (most recent heading)
				local parent = nil
				for level = 10, 0, -1 do
					if current_nodes[level] then
						parent = current_nodes[level]
						break
					end
				end

				if parent then
					local path = parent.path .. "/" .. label
					local node = create_node(label, path, parent.level + 1, parent)
					table.insert(parent.children, node)
					-- Labels can be parents too
					current_nodes[parent.level + 1] = node
				end
			end
		end

		::continue::
	end

	return root
end

--- Find node by path in tree
local function find_node_by_path(root, path)
	if not path or path == "" then
		return nil
	end

	-- Normalize path
	path = path:gsub("^/", ""):gsub("/$", "")

	-- Check current node
	if root.path == path then
		return root
	end

	-- Search children
	for _, child in ipairs(root.children) do
		local found = find_node_by_path(child, path)
		if found then
			return found
		end
	end

	return nil
end

-- =============================================================================
-- Area Link Parsing
-- =============================================================================

--- Parse area links from objective line
-- @param line string Line containing area links
-- @return table Array of area paths
local function parse_area_links(line)
	local area_paths = {}
	local all_links = utils.extract_all_links(line)

	for _, link_info in ipairs(all_links) do
		if link_info.type == "link" then
			local parsed = links.parse_link_definition(link_info.definition)
			if parsed and #parsed.components > 0 then
				-- Check if first component is "A" or "Areas"
				local first = parsed.components[1]
				if first.type == "article" and (first.text == "A" or first.text == "Areas") then
					-- Build path from remaining components
					local path_parts = {}
					for i = 2, #parsed.components do
						local comp = parsed.components[i]
						if comp.type == "heading" or comp.type == "label" then
							table.insert(path_parts, comp.text)
						end
					end

					if #path_parts > 0 then
						local path = table.concat(path_parts, "/")
						table.insert(area_paths, path)
					end
				end
			end
		end
	end

	return area_paths
end

-- =============================================================================
-- XP Calculation
-- =============================================================================

--- Get XP percentage from completion curve
local function get_xp_from_curve(completion_pct, curve)
	local lower_pct, lower_xp = 0, 0
	local upper_pct, upper_xp = 1, 1

	for pct, xp in pairs(curve) do
		if pct <= completion_pct and pct > lower_pct then
			lower_pct = pct
			lower_xp = xp
		end
		if pct >= completion_pct and pct < upper_pct then
			upper_pct = pct
			upper_xp = xp
		end
	end

	-- Linear interpolation
	if upper_pct == lower_pct then
		return lower_xp
	end

	local t = (completion_pct - lower_pct) / (upper_pct - lower_pct)
	return lower_xp + t * (upper_xp - lower_xp)
end

--- Distribute XP among areas based on distribution curve
local function distribute_xp(total_xp, area_paths)
	local distribution = {}
	local num_areas = #area_paths

	if num_areas == 0 then
		return distribution
	end

	if M.config.distribution_curve == "even" then
		-- Even distribution
		local xp_per_area = total_xp / num_areas
		for _, path in ipairs(area_paths) do
			distribution[path] = xp_per_area
		end
	elseif M.config.distribution_curve == "weighted" then
		-- Weighted distribution
		local weights = M.config.distribution_weights
		if num_areas == 1 then
			distribution[area_paths[1]] = total_xp
		elseif num_areas == 2 then
			distribution[area_paths[1]] = total_xp * weights.primary
			distribution[area_paths[2]] = total_xp * (1 - weights.primary)
		else
			-- Primary gets primary weight
			distribution[area_paths[1]] = total_xp * weights.primary

			-- Secondary areas share secondary weight
			local secondary_count = math.min(2, num_areas - 1)
			local secondary_xp = (total_xp * weights.secondary) / secondary_count
			for i = 2, math.min(3, num_areas) do
				distribution[area_paths[i]] = secondary_xp
			end

			-- Remaining share tertiary
			if num_areas > 3 then
				local tertiary_xp = (total_xp * weights.tertiary) / (num_areas - 3)
				for i = 4, num_areas do
					distribution[area_paths[i]] = tertiary_xp
				end
			end
		end
	else
		-- Primary mode - all to first area
		distribution[area_paths[1]] = total_xp
	end

	return distribution
end

--- Add XP to node and bubble up
local function add_xp_to_node(node, xp_amount)
	if not node or xp_amount <= 0 then
		return
	end

	-- Add to current node
	node.xp = node.xp + xp_amount

	-- Save to persistent storage
	if not M.area_xp[node.path] then
		M.area_xp[node.path] = 0
	end
	M.area_xp[node.path] = M.area_xp[node.path] + xp_amount

	-- Save data after each update
	M.save_xp_data()

	-- Bubble up to parent with multiplier
	if node.parent then
		local bubbled_xp = xp_amount * M.config.bubble_multiplier
		add_xp_to_node(node.parent, bubbled_xp)
	end
end

-- =============================================================================
-- OKR Processing
-- =============================================================================

--- Process completed key result
function M.process_kr_completion(objective_data, kr_line)
	-- Get objective base XP
	local base_xp = M.config.objective_base_xp[objective_data.span] or 100

	-- Calculate completion percentage
	local completed_krs = objective_data.completed_krs or 0
	local total_krs = objective_data.total_krs or 1
	local completion_pct = completed_krs / total_krs

	-- Get XP for this completion level
	local xp_pct = get_xp_from_curve(completion_pct, M.config.kr_completion_curve)
	local total_xp = base_xp * xp_pct

	-- Get previous completion XP
	local prev_pct = (completed_krs - 1) / total_krs
	local prev_xp_pct = get_xp_from_curve(prev_pct, M.config.kr_completion_curve)
	local prev_xp = base_xp * prev_xp_pct

	-- Calculate XP earned for this KR
	local earned_xp = total_xp - prev_xp

	-- Parse area links from objective
	local area_paths = parse_area_links(objective_data.line_text)

	if #area_paths == 0 then
		return 0
	end

	-- Ensure tree is loaded
	M.ensure_tree_loaded()
	if not M.area_tree then
		return 0
	end

	-- Distribute XP among areas
	local distribution = distribute_xp(earned_xp, area_paths)

	-- Apply XP to each area
	for path, xp_amount in pairs(distribution) do
		local node = find_node_by_path(M.area_tree, path)
		if node then
			add_xp_to_node(node, xp_amount)
		end
	end

	return earned_xp
end

--- Process completed objective
function M.process_objective_completion(objective_data)
	-- Get total objective XP
	local total_xp = M.config.objective_base_xp[objective_data.span] or 100

	-- Parse area links
	local area_paths = parse_area_links(objective_data.line_text)

	if #area_paths == 0 then
		return 0
	end

	-- Ensure tree is loaded
	M.ensure_tree_loaded()
	if not M.area_tree then
		return 0
	end

	-- Distribute XP among areas
	local distribution = distribute_xp(total_xp, area_paths)

	-- Apply XP to each area
	for path, xp_amount in pairs(distribution) do
		local node = find_node_by_path(M.area_tree, path)
		if node then
			add_xp_to_node(node, xp_amount)
		end
	end

	return total_xp
end

-- =============================================================================
-- Tree Management
-- =============================================================================

--- Ensure area tree is loaded and up to date
function M.ensure_tree_loaded()
	local areas_file = utils.get_file_path(utils.AREAS_FILE)
	if not areas_file then
		return
	end

	local current_mtime = vim.fn.getftime(areas_file)

	-- Reload if file changed or not loaded
	if not M.area_tree or not M.area_tree_timestamp or current_mtime > M.area_tree_timestamp then
		M.area_tree = parse_areas_file()
		M.area_tree_timestamp = current_mtime

		-- Apply saved XP to tree
		if M.area_tree then
			M.apply_saved_xp()
		end
	end
end

--- Apply saved XP data to tree
function M.apply_saved_xp()
	if not M.area_tree then
		return
	end

	-- Reset all XP in tree
	local function reset_node(node)
		node.xp = 0
		node.total_xp = 0
		for _, child in ipairs(node.children) do
			reset_node(child)
		end
	end
	reset_node(M.area_tree)

	-- Apply saved XP
	for path, xp in pairs(M.area_xp) do
		local node = find_node_by_path(M.area_tree, path)
		if node then
			node.xp = xp
		end
	end

	-- Calculate total XP (including children)
	local function calculate_totals(node)
		node.total_xp = node.xp
		for _, child in ipairs(node.children) do
			calculate_totals(child)
			node.total_xp = node.total_xp + child.total_xp
		end
	end
	calculate_totals(M.area_tree)
end

-- =============================================================================
-- Level Calculation
-- =============================================================================

--- Calculate level from XP
local function calculate_level(xp)
	local level = 0
	local remaining_xp = xp

	for i, threshold in ipairs(M.config.level_thresholds) do
		if xp >= threshold then
			level = i
		else
			break
		end
	end

	-- Calculate progress to next level
	local current_threshold = level > 0 and M.config.level_thresholds[level] or 0
	local next_threshold = M.config.level_thresholds[level + 1]
	local progress = 0

	if next_threshold then
		local level_xp = xp - current_threshold
		local level_requirement = next_threshold - current_threshold
		progress = level_xp / level_requirement
	else
		-- Max level reached
		progress = 1.0
	end

	return level, progress, current_threshold, next_threshold
end

-- =============================================================================
-- Popup Display
-- =============================================================================

--- Create progress bar string
local function create_progress_bar(progress, width)
	local filled = math.floor(progress * width)
	local empty = width - filled
	return string.rep("█", filled) .. string.rep("░", empty)
end

--- Get highlight group for level
local function get_level_highlight(level)
	local groups = M.config.popup.highlight_groups
	if level <= 3 then
		return groups.level_1_3
	elseif level <= 6 then
		return groups.level_4_6
	elseif level <= 9 then
		return groups.level_7_9
	else
		return groups.level_10_plus
	end
end

--- Render node and its children
local function render_node(node, lines, highlights, indent_level)
	indent_level = indent_level or 0
	local indent = string.rep("  ", indent_level)

	-- Skip root node
	if node.level > 0 or node == M.area_tree then
		-- Calculate level and progress
		local level, progress, current_xp, next_xp = calculate_level(node.total_xp)

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

		-- Add progress bar
		if next_xp and indent_level < 3 then
			local bar = create_progress_bar(progress, 20)
			local progress_line = string.format("%s  %s %.0f%%", indent, bar, progress * 100)
			table.insert(lines, progress_line)

			-- Highlight progress bar
			table.insert(highlights, {
				line = #lines - 1,
				col_start = #indent + 2,
				col_end = #indent + 2 + #bar,
				group = M.config.popup.highlight_groups.progress_bar,
			})
		end
	end

	-- Render children
	for _, child in ipairs(node.children) do
		render_node(child, lines, highlights, node.level > 0 and indent_level + 1 or 0)
	end
end

--- Show skill tree popup
function M.show_skill_tree()
	-- Ensure tree is loaded
	M.ensure_tree_loaded()
	if not M.area_tree then
		vim.notify("No areas.zortex file found", vim.log.levels.WARN)
		return
	end

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

	-- Render tree
	render_node(M.area_tree, lines, highlights)

	-- Add footer
	table.insert(lines, "")
	table.insert(lines, string.rep("-", 50))
	table.insert(lines, "Press 'q' to close")

	-- Set buffer content
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Apply highlights
	for _, hl in ipairs(highlights) do
		vim.api.nvim_buf_add_highlight(buf, -1, hl.group, hl.line, hl.col_start, hl.col_end)
	end

	-- Create window
	local win_config = {
		relative = "editor",
		width = M.config.popup.width,
		height = M.config.popup.height,
		col = math.floor((vim.o.columns - M.config.popup.width) / 2),
		row = math.floor((vim.o.lines - M.config.popup.height) / 2),
		style = "minimal",
		border = M.config.popup.border,
	}

	local win = vim.api.nvim_open_win(buf, true, win_config)

	-- Set keymaps
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { noremap = true, silent = true })
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", { noremap = true, silent = true })

	-- Make buffer read-only
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- =============================================================================
-- Integration with XP System
-- =============================================================================

-- Note: The XP system integration is handled by modifying the xp.calculate_xp
-- function to check for is_objective and is_key_result flags in task_data

-- =============================================================================
-- Setup and Configuration
-- =============================================================================

--- Setup skill tree system
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

	-- Load saved XP data
	M.load_xp_data()

	-- Create commands
	vim.api.nvim_create_user_command("ZortexSkillTree", function()
		M.show_skill_tree()
	end, { desc = "Show Zortex skill tree" })

	-- Debug command to manually add XP
	vim.api.nvim_create_user_command("ZortexSkillAddXP", function(opts)
		local args = vim.split(opts.args, " ")
		if #args < 2 then
			vim.notify("Usage: ZortexSkillAddXP <area_path> <xp_amount>", vim.log.levels.ERROR)
			return
		end

		local path = args[1]
		local xp = tonumber(args[2])
		if not xp then
			vim.notify("Invalid XP amount", vim.log.levels.ERROR)
			return
		end

		M.ensure_tree_loaded()
		if not M.area_tree then
			vim.notify("Could not load area tree", vim.log.levels.ERROR)
			return
		end

		local node = find_node_by_path(M.area_tree, path)
		if node then
			add_xp_to_node(node, xp)
			vim.notify(string.format("Added %d XP to %s", xp, path), vim.log.levels.INFO)
		else
			vim.notify("Area not found: " .. path, vim.log.levels.ERROR)
		end
	end, { nargs = "+", desc = "Manually add XP to an area (for debugging)" })

	-- Setup auto-save on VimLeavePre
	vim.api.nvim_create_autocmd("VimLeavePre", {
		pattern = "*",
		callback = function()
			M.save_xp_data()
		end,
		group = vim.api.nvim_create_augroup("ZortexSkillTreeSave", { clear = true }),
	})
end

--- Save XP data to file
function M.save_xp_data()
	local data_dir = vim.g.zortex_notes_dir .. "/.zortex"
	local data_file = data_dir .. "/skill_xp.json"

	-- Ensure directory exists
	vim.fn.mkdir(data_dir, "p")

	-- Convert to JSON
	local json_data = vim.fn.json_encode(M.area_xp)

	-- Write to file
	local file = io.open(data_file, "w")
	if file then
		file:write(json_data)
		file:close()
		return true
	end
	return false
end

--- Load XP data from file
function M.load_xp_data()
	local data_file = vim.g.zortex_notes_dir .. "/.zortex/skill_xp.json"

	if vim.fn.filereadable(data_file) == 0 then
		return false
	end

	local file = io.open(data_file, "r")
	if file then
		local content = file:read("*all")
		file:close()

		local success, data = pcall(vim.fn.json_decode, content)
		if success and type(data) == "table" then
			M.area_xp = data
			return true
		end
	end
	return false
end

return M
