-- features/skills.lua - Revamped Skills System for Area progression
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local xp = require("zortex.features.xp")

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

				-- Clear deeper levels
				for level = heading_level + 1, 10 do
					current_nodes[level] = nil
				end
			end
		else
			-- Check for label
			local label = line:match("^(%w[^:]*):$")
			if label then
				-- Find parent
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
					current_nodes[parent.level + 1] = node
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

-- Extract area links from a line (space-separated zortex links)
function M.extract_area_links(line)
	local links = {}

	-- Look for zortex-style links
	for link in line:gmatch("%[([^%]]+)%]") do
		-- Skip if it's a task checkbox
		if not link:match("^%s*[xX~@]?%s*$") then
			table.insert(links, link)
		end
	end

	return links
end

-- Extract area links from the line below a heading
function M.get_area_links_for_heading(lines, heading_line_num)
	if heading_line_num >= #lines then
		return {}
	end

	local next_line = lines[heading_line_num + 1]

	-- Check if next line contains links (not another heading or task)
	if not parser.get_heading_level(next_line) and not parser.is_task_line(next_line) and next_line:match("%[.+%]") then
		return M.extract_area_links(next_line)
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
function M.process_task_completion(project_name, task_position, total_tasks, project_area_links)
	return xp.complete_task(project_name, task_position, total_tasks, project_area_links)
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
