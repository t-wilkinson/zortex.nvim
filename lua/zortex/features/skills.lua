-- features/skills.lua - Skill tree system for Zortex
local M = {}

local config = require("zortex.config")
local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")

-- Cached data
local area_tree = nil
local area_tree_timestamp = nil
local area_xp = {}

-- =============================================================================
-- Tree Node Type
-- =============================================================================

-- @class AreaNode
-- @field name string Display name
-- @field path string Full path in tree
-- @field level number Depth in tree (1 for root)
-- @field children table Array of child nodes
-- @field parent AreaNode|nil Parent node
-- @field xp number Current XP for this node
-- @field total_xp number Total XP including children

-- Create a new area node
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

-- Parse areas.zortex and build tree structure
local function parse_areas_file()
	local areas_file = fs.get_areas_file()
	if not areas_file or not fs.file_exists(areas_file) then
		return nil
	end

	local lines = fs.read_lines(areas_file)
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
		local heading_level = parser.get_heading_level(line)
		if heading_level > 0 then
			local heading = parser.parse_heading(line)
			if heading then
				-- Clean text of attributes
				local text = heading.text:gsub(" @%w+%([^%)]*%)", ""):gsub(" @%w+", "")
				text = parser.trim(text)

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

-- Find node by path in tree
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
-- XP Distribution
-- =============================================================================

-- Get XP percentage from completion curve
local function get_xp_from_curve(completion_pct)
	local cfg = config.get("skills")
	local curve = cfg.objective_base_xp

	local lower_pct, lower_xp = 0, 0
	local upper_pct, upper_xp = 1, 1

	-- Find appropriate points in curve
	local sorted_pcts = {}
	for pct, _ in pairs(curve) do
		table.insert(sorted_pcts, pct)
	end
	table.sort(sorted_pcts)

	for _, pct in ipairs(sorted_pcts) do
		if pct <= completion_pct and pct > lower_pct then
			lower_pct = pct
			lower_xp = curve[pct]
		end
		if pct >= completion_pct and pct < upper_pct then
			upper_pct = pct
			upper_xp = curve[pct]
		end
	end

	-- Linear interpolation
	if upper_pct == lower_pct then
		return lower_xp
	end

	local t = (completion_pct - lower_pct) / (upper_pct - lower_pct)
	return lower_xp + t * (upper_xp - lower_xp)
end

-- Distribute XP among areas based on distribution curve
local function distribute_xp(total_xp, area_paths)
	local cfg = config.get("skills")
	local distribution = {}
	local num_areas = #area_paths

	if num_areas == 0 then
		return distribution
	end

	if cfg.distribution_curve == "even" then
		-- Even distribution
		local xp_per_area = total_xp / num_areas
		for _, path in ipairs(area_paths) do
			distribution[path] = xp_per_area
		end
	elseif cfg.distribution_curve == "weighted" then
		-- Weighted distribution
		local weights = cfg.distribution_weights
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

-- Add XP to node and bubble up
local function add_xp_to_node(node, xp_amount)
	if not node or xp_amount <= 0 then
		return
	end

	local cfg = config.get("skills")

	-- Add to current node
	node.xp = node.xp + xp_amount

	-- Save to persistent storage
	if not area_xp[node.path] then
		area_xp[node.path] = 0
	end
	area_xp[node.path] = area_xp[node.path] + xp_amount

	-- Save data after each update
	M.save_xp_data()

	-- Bubble up to parent with multiplier
	if node.parent then
		local bubbled_xp = xp_amount * cfg.bubble_multiplier
		add_xp_to_node(node.parent, bubbled_xp)
	end
end

-- =============================================================================
-- OKR Processing
-- =============================================================================

-- Process completed key result
function M.process_kr_completion(objective_data, kr_line)
	local cfg = config.get("skills")

	-- Get objective base XP
	local base_xp = cfg.objective_base_xp[objective_data.span] or 100

	-- Calculate completion percentage
	local completed_krs = objective_data.completed_krs or 0
	local total_krs = objective_data.total_krs or 1
	local completion_pct = completed_krs / total_krs

	-- Get XP for this completion level
	local xp_pct = get_xp_from_curve(completion_pct)
	local total_xp = base_xp * xp_pct

	-- Get previous completion XP
	local prev_pct = (completed_krs - 1) / total_krs
	local prev_xp_pct = get_xp_from_curve(prev_pct)
	local prev_xp = base_xp * prev_xp_pct

	-- Calculate XP earned for this KR
	local earned_xp = total_xp - prev_xp

	-- Parse area links from objective
	local area_paths = parser.extract_area_links(objective_data.line_text)

	if #area_paths == 0 then
		return 0
	end

	-- Ensure tree is loaded
	M.ensure_tree_loaded()
	if not area_tree then
		return 0
	end

	-- Distribute XP among areas
	local distribution = distribute_xp(earned_xp, area_paths)

	-- Apply XP to each area
	for path, xp_amount in pairs(distribution) do
		local node = find_node_by_path(area_tree, path)
		if node then
			add_xp_to_node(node, xp_amount)
		end
	end

	return earned_xp
end

-- Process completed objective
function M.process_objective_completion(objective_data)
	local cfg = config.get("skills")

	-- Get total objective XP
	local total_xp = cfg.objective_base_xp[objective_data.span] or 100

	-- Parse area links
	local area_paths = parser.extract_area_links(objective_data.line_text)

	if #area_paths == 0 then
		return 0
	end

	-- Ensure tree is loaded
	M.ensure_tree_loaded()
	if not area_tree then
		return 0
	end

	-- Distribute XP among areas
	local distribution = distribute_xp(total_xp, area_paths)

	-- Apply XP to each area
	for path, xp_amount in pairs(distribution) do
		local node = find_node_by_path(area_tree, path)
		if node then
			add_xp_to_node(node, xp_amount)
		end
	end

	return total_xp
end

-- =============================================================================
-- Tree Management
-- =============================================================================

-- Ensure area tree is loaded and up to date
function M.ensure_tree_loaded()
	local areas_file = fs.get_areas_file()
	if not areas_file then
		return
	end

	local current_mtime = vim.fn.getftime(areas_file)

	-- Reload if file changed or not loaded
	if not area_tree or not area_tree_timestamp or current_mtime > area_tree_timestamp then
		area_tree = parse_areas_file()
		area_tree_timestamp = current_mtime

		-- Apply saved XP to tree
		if area_tree then
			M.apply_saved_xp()
		end
	end
end

-- Apply saved XP data to tree
function M.apply_saved_xp()
	if not area_tree then
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
	reset_node(area_tree)

	-- Apply saved XP
	for path, xp in pairs(area_xp) do
		local node = find_node_by_path(area_tree, path)
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
	calculate_totals(area_tree)
end

-- =============================================================================
-- Level Calculation
-- =============================================================================

-- Calculate level from XP
function M.calculate_level(xp)
	local cfg = config.get("skills")
	local level = 0
	local remaining_xp = xp

	for i, threshold in ipairs(cfg.level_thresholds) do
		if xp >= threshold then
			level = i
		else
			break
		end
	end

	-- Calculate progress to next level
	local current_threshold = level > 0 and cfg.level_thresholds[level] or 0
	local next_threshold = cfg.level_thresholds[level + 1]
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
-- Data Persistence
-- =============================================================================

-- Save XP data to file
function M.save_xp_data()
	local data_file = fs.get_skill_data_file()
	if not data_file then
		return false
	end

	return fs.write_json(data_file, area_xp)
end

-- Load XP data from file
function M.load_xp_data()
	local data_file = fs.get_skill_data_file()
	if not data_file then
		return false
	end

	local data = fs.read_json(data_file)
	if data then
		area_xp = data
		return true
	end

	return false
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Get the area tree (ensure it's loaded first)
function M.get_area_tree()
	M.ensure_tree_loaded()
	return area_tree
end

-- Manually add XP to an area (for debugging)
function M.add_xp(area_path, xp_amount)
	M.ensure_tree_loaded()
	if not area_tree then
		return false
	end

	local node = find_node_by_path(area_tree, area_path)
	if node then
		add_xp_to_node(node, xp_amount)
		return true
	end

	return false
end

return M
