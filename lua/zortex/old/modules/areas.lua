-- modules/areas.lua - Area tree management and link extraction
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local xp_areas = require("zortex.xp.areas")
local constants = require("zortex.constants")

-- =============================================================================
-- Area Tree Node
-- =============================================================================

local function create_node(name, path, level, parent)
	return {
		name = name,
		path = path,
		level = level,
		children = {},
		parent = parent,
		xp_data = nil,
	}
end

-- =============================================================================
-- Area Tree Parsing
-- =============================================================================

function M.parse_areas_file()
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
	local last_heading_node = nil
	local last_heading_level = 0

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
				-- Clean text (remove attributes)
				local _, text = parser.parse_attributes(heading.text)
				text = parser.trim(text)

				-- Find parent
				local parent_level = heading_level - 1
				while parent_level >= 0 and not current_nodes[parent_level] do
					parent_level = parent_level - 1
				end

				local parent = current_nodes[parent_level] or root
				local path = parent.path ~= "" and (parent.path .. "/" .. text) or text

				local node = create_node(text, path, heading_level, parent)
				table.insert(parent.children, node)
				current_nodes[heading_level] = node

				-- Update last heading info
				last_heading_node = node
				last_heading_level = heading_level

				-- Clear deeper levels
				for level = heading_level + 1, 10 do
					current_nodes[level] = nil
				end
			end
		else
			-- Check for label
			local label = parser.parse_label(line)
			if label then
				-- Labels should be children of the last heading
				local parent = last_heading_node

				if parent then
					local path = parent.path .. "/" .. label.text
					local node = create_node(label.text, path, last_heading_level + 1, parent)
					table.insert(parent.children, node)
				end
			end
		end

		::continue::
	end

	return root
end

-- Apply XP data to tree
function M.apply_xp_to_tree(root)
	if not root then
		return
	end

	local area_stats = xp_areas.get_all_stats()

	local function apply_to_node(node)
		if node.path and node.path ~= "" then
			node.xp_data = area_stats[node.path]
			if node.xp_data then
				-- Ensure XP is never negative
				node.xp_data.xp = math.max(0, node.xp_data.xp or 0)
				node.xp_data.level = node.xp_data.level or 1
				node.xp_data.progress = node.xp_data.progress or 0
			end
		end

		for _, child in ipairs(node.children) do
			apply_to_node(child)
		end
	end

	apply_to_node(root)
end

-- =============================================================================
-- Area Link Management
-- =============================================================================

-- Extract area links from a line
function M.extract_area_links(line)
	if not line then
		return {}
	end

	local links = {}
	local all_links = parser.extract_all_links(line)

	for _, link_info in ipairs(all_links) do
		if link_info.type == "link" then
			local parsed = parser.parse_link_definition(link_info.definition)
			if parsed and #parsed.components > 0 then
				local first = parsed.components[1]
				-- Check if first component is Areas or A
				if first.type == "article" and (first.text == "A" or first.text == "Areas") then
					-- This is an area link
					table.insert(links, link_info.definition)
				end
			end
		end
	end

	return links
end

-- Resolve area link to full path
function M.resolve_area_link(area_link, area_tree)
	local parsed = parser.parse_link_definition(area_link)
	if not parsed or #parsed.components == 0 then
		return nil
	end

	-- Get the path from XP areas module
	local path = xp_areas.parse_area_path(area_link)
	if not path then
		return nil
	end

	-- If we have a tree and the path seems partial, try to find full path
	if area_tree and not path:match("/") then
		local function find_matching_node(node, target)
			if node.path and node.path:lower():find(target:lower() .. "$") then
				return node.path
			end

			for _, child in ipairs(node.children) do
				local found = find_matching_node(child, target)
				if found then
					return found
				end
			end

			return nil
		end

		local full_path = find_matching_node(area_tree, path)
		if full_path then
			return full_path
		end
	end

	return path
end

-- =============================================================================
-- Area Tree Queries
-- =============================================================================

-- Get the area tree with XP data
function M.get_area_tree()
	local tree = M.parse_areas_file()
	if tree then
		M.apply_xp_to_tree(tree)
	end
	return tree
end

-- Find node by path
function M.find_node_by_path(root, path)
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
		local found = M.find_node_by_path(child, path)
		if found then
			return found
		end
	end

	return nil
end

-- Calculate total XP for a node (including children)
function M.calculate_total_xp(node)
	local total = 0

	-- Add own XP
	if node.xp_data and node.xp_data.xp then
		total = node.xp_data.xp
	end

	-- Add children's XP
	for _, child in ipairs(node.children) do
		total = total + M.calculate_total_xp(child)
	end

	return total
end

-- Get top areas by XP
function M.get_top_areas(limit)
	return xp_areas.get_top_areas(limit)
end

-- =============================================================================
-- Area Statistics Display
-- =============================================================================

function M.show_area_stats()
	local tree = M.get_area_tree()
	if not tree then
		vim.notify("Could not load areas file", vim.log.levels.ERROR)
		return
	end

	local top_areas = M.get_top_areas(10)

	local lines = {}
	table.insert(lines, "🎯 Area Statistics")
	table.insert(lines, "")

	if #top_areas > 0 then
		table.insert(lines, "Top Areas by XP:")
		for i, area in ipairs(top_areas) do
			table.insert(lines, string.format("%d. %s - Level %d (%d XP)", i, area.path, area.level, area.xp))
		end
	else
		table.insert(lines, "No areas with XP yet.")
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M

