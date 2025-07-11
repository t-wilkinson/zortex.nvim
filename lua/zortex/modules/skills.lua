-- modules/skills.lua - Revamped Skills System for Area progression
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local xp = require("zortex.modules.xp")

-- =============================================================================
-- Area Tree Management
-- =============================================================================

-- Tree node structure
local function create_node(name, path, level, parent)
	return {
		name = name,
		path = path,
		level = level,
		children = {},
		parent = parent,
		xp_data = nil, -- Will be populated from XP system
	}
end

-- Parse areas file to build tree
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
				-- Clean text
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
			local label = line:match("^(%w[^:]*):$")
			if label then
				-- Labels should be children of the last heading, not nested under each other
				local parent = last_heading_node

				if parent then
					local path = parent.path .. "/" .. label
					local node = create_node(label, path, last_heading_level + 1, parent)
					table.insert(parent.children, node)
					-- Don't update current_nodes for labels to prevent nesting
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

	local area_stats = xp.get_area_stats()

	-- Recursive function to apply XP data
	local function apply_to_node(node)
		if node.path and node.path ~= "" then
			node.xp_data = area_stats[node.path]
			-- Ensure we have valid data
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

-- =============================================================================
-- Area Link Extraction
-- =============================================================================

-- Extract area links from a line (zortex-style links to areas)
function M.extract_area_links(line)
	local links = {}

	-- Look for all zortex-style links
	for link in line:gmatch("%[([^%]]+)%]") do
		-- Parse the link to check if it's an area link
		local parsed = parser.parse_link_definition(link)
		if parsed and #parsed.components > 0 then
			local first = parsed.components[1]
			-- Check if first component is Areas or A
			if first.type == "article" and (first.text == "A" or first.text == "Areas") then
				-- This is an area link - store the full link definition
				table.insert(links, link)
			end
		end
	end

	return links
end

-- Resolve a potentially shortened area link to its full path
function M.resolve_area_link(area_link)
	local parsed = parser.parse_link_definition(area_link)
	if not parsed or #parsed.components == 0 then
		return nil
	end

	-- If it's a local link or doesn't start with Areas/A, return as-is
	if parsed.scope == "local" then
		return M.build_area_path(parsed.components)
	end

	-- Check if this is an area link
	local first = parsed.components[1]
	if first.type ~= "article" or (first.text ~= "A" and first.text ~= "Areas") then
		return M.build_area_path(parsed.components)
	end

	-- If we only have the Areas component, return nil
	if #parsed.components == 1 then
		return nil
	end

	-- Get the area tree to find the full path
	local tree = M.parse_areas_file()
	if not tree then
		return M.build_area_path(parsed.components)
	end

	-- Build a partial path from the components
	local partial_path = M.build_area_path(parsed.components)
	if not partial_path then
		return nil
	end

	-- Search for a node that ends with this partial path
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

	local full_path = find_matching_node(tree, partial_path)
	return full_path or partial_path
end

-- Extract area links from the line below a heading
function M.get_area_links_for_heading(lines, heading_line_num)
	if heading_line_num >= #lines then
		return {}
	end

	local next_line = lines[heading_line_num + 1]

	-- Check if next line contains links
	if string.sub(next_line, 1, 1) == "[" then
		local raw_links = M.extract_area_links(next_line)
		local resolved_links = {}

		for _, link in ipairs(raw_links) do
			local resolved = M.resolve_area_link(link)
			if resolved then
				-- Convert back to link format with full path
				table.insert(resolved_links, "A/" .. resolved)
			end
		end

		return resolved_links
	end
	return {}
end

-- =============================================================================
-- Integration with OKR/Project Systems
-- =============================================================================

-- Process objective completion (from OKR file)
function M.process_objective_completion(objective_data, lines, line_num)
	-- Extract area links from line below objective
	local area_links = M.get_area_links_for_heading(lines, line_num)

	if #area_links > 0 then
		local time_horizon = objective_data.span or "quarterly"
		local created_date = objective_data.created_date

		return xp.complete_objective(objective_data.title, time_horizon, area_links, created_date)
	end

	return 0
end

-- Process task completion in a project
function M.process_task_completion(project_name, task_position, total_tasks, project_area_links, silent)
	return xp.complete_task(project_name, task_position, total_tasks, project_area_links, silent)
end

-- Get area links for a project
function M.get_project_area_links(lines, project_line_num)
	return M.get_area_links_for_heading(lines, project_line_num)
end

-- =============================================================================
-- Tree Statistics
-- =============================================================================

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
function M.get_top_areas(root, limit)
	limit = limit or 10
	local areas = {}

	-- Collect all areas with XP
	local function collect_areas(node)
		if node.xp_data and node.xp_data.xp > 0 then
			table.insert(areas, {
				path = node.path,
				name = node.name,
				xp = node.xp_data.xp,
				level = node.xp_data.level,
			})
		end

		for _, child in ipairs(node.children) do
			collect_areas(child)
		end
	end

	if root then
		collect_areas(root)
	end

	-- Sort by XP
	table.sort(areas, function(a, b)
		return a.xp > b.xp
	end)

	-- Return top N
	local result = {}
	for i = 1, math.min(limit, #areas) do
		table.insert(result, areas[i])
	end

	return result
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Get the area tree with XP data
function M.get_area_tree()
	local tree = M.parse_areas_file()
	if tree then
		M.apply_xp_to_tree(tree)
	end
	return tree
end

-- Manually add XP to an area
function M.add_area_xp(area_path, xp_amount, parent_links)
	return xp.add_area_xp(area_path, xp_amount, parent_links)
end

-- Get current season status
function M.get_season_status()
	return xp.get_season_status()
end

-- Season management
function M.start_season(name, end_date)
	return xp.start_season(name, end_date)
end

function M.end_season()
	return xp.end_season()
end

-- Get project statistics
function M.get_project_stats()
	return xp.get_project_stats()
end

return M
