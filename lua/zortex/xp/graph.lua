-- Graph management for Zortex XP system
local M = {}

-- Graph data structure
M.data = {
	nodes = {}, -- node_id -> node
	edges = {}, -- node_id -> list of connected node_ids
	backlinks = {}, -- node_id -> list of nodes that link to it
	distances = {}, -- node_id -> distance from nearest vision
	vision_nodes = {},
	areas = {}, -- area_name -> node
	dirty = true, -- whether graph needs rebuilding
}

-- Build graph from all zortex files
function M.build()
	local parser = require("zortex.xp.parser")

	-- Only do full reset if really needed
	if not M.data.nodes or vim.tbl_count(M.data.nodes) == 0 then
		-- Full reset for first build
		M.data = {
			nodes = {},
			edges = {},
			backlinks = {},
			distances = {},
			vision_nodes = {},
			areas = {},
			dirty = false,
		}
	else
		-- Incremental update - keep existing data
		M.data.dirty = false
	end

	-- Find all zortex files
	local notes_dir = vim.g.zortex_notes_dir
	local extension = vim.g.zortex_extension

	-- Use async file finding if available
	local files = vim.fn.globpath(notes_dir, "**/*" .. extension, false, true)

	-- Track which files we've seen
	local seen_files = {}

	-- Parse each file and add to graph
	for _, filepath in ipairs(files) do
		seen_files[filepath] = true

		-- Only parse if we need to (based on file cache in init.lua)
		local xp = require("zortex.xp")
		local stat = vim.loop.fs_stat(filepath)
		if stat then
			local cached_mtime = xp._file_cache[filepath]
			if not cached_mtime or cached_mtime < stat.mtime.sec then
				-- File changed, parse it
				local file_data = parser.parse_file(filepath)
				if file_data then
					M.add_file_to_graph(file_data)
				end
				xp._file_cache[filepath] = stat.mtime.sec
			end
		end
	end

	-- Clean up nodes from deleted files
	local nodes_to_remove = {}
	for node_id, node in pairs(M.data.nodes) do
		if node.file and not seen_files[node.file] then
			table.insert(nodes_to_remove, node_id)
		end
	end

	for _, node_id in ipairs(nodes_to_remove) do
		M.data.nodes[node_id] = nil
		M.data.edges[node_id] = nil
		-- Remove from vision nodes if needed
		for i, vid in ipairs(M.data.vision_nodes) do
			if vid == node_id then
				table.remove(M.data.vision_nodes, i)
				break
			end
		end
	end

	-- Build backlinks
	M.build_backlinks()

	-- Calculate distances from visions
	M.calculate_distances()

	-- Find areas for all nodes
	M.assign_areas()
end

-- Add parsed file data to graph
function M.add_file_to_graph(file_data)
	-- Add all items as nodes
	for _, item in ipairs(file_data.items) do
		local node_id = M.get_node_id(item)

		-- Store node
		M.data.nodes[node_id] = item

		-- Initialize edges
		M.data.edges[node_id] = {}

		-- Add links as edges
		if item.links then
			for _, link in ipairs(item.links) do
				table.insert(M.data.edges[node_id], link)
			end
		end

		-- Track special node types
		if item.type == "vision" then
			table.insert(M.data.vision_nodes, node_id)
		elseif item.type == "area" then
			M.data.areas[item.name] = item
		end

		-- Add file-level connections
		if item.article then
			-- Connect to article node
			local article_id = item.article
			if not vim.tbl_contains(M.data.edges[node_id], article_id) then
				table.insert(M.data.edges[node_id], article_id)
			end
		end

		-- Special handling for project tasks
		if item.type == "task" and (item.in_project or item.file:match("project")) then
			-- Try to connect to project based on article or filename
			local project_name = item.project_name or item.article
			if not project_name and item.file then
				-- Extract project name from filename
				local filename = vim.fn.fnamemodify(item.file, ":t:r")
				if filename:match("project") then
					-- Remove "project" or "projects" to get the actual project name
					project_name = filename:gsub("projects?%-?", ""):gsub("%-", " ")
				end
			end

			-- If we found a project name, try to link to it
			if project_name then
				-- Look for existing project node
				local found_project = false
				for pid, pnode in pairs(M.data.nodes) do
					if
						pnode.type == "project"
						and (pnode.name == project_name or pnode.name:lower() == project_name:lower())
					then
						-- Add edge from task to project
						if not vim.tbl_contains(M.data.edges[node_id], pid) then
							table.insert(M.data.edges[node_id], pid)
						end
						found_project = true
						break
					end
				end

				-- If no project found, create implicit connection through article
				if not found_project and item.article then
					-- This helps tasks in project files get reasonable distances
					local article_node_id = item.file .. ":article:" .. item.article
					M.data.nodes[article_node_id] = {
						type = "article",
						name = item.article,
						file = item.file,
					}
					-- Connect task to article
					if not vim.tbl_contains(M.data.edges[node_id], article_node_id) then
						table.insert(M.data.edges[node_id], article_node_id)
					end
				end
			end
		end
	end
end

-- Build backlinks (reverse edges)
function M.build_backlinks()
	M.data.backlinks = {}

	for from_id, edges in pairs(M.data.edges) do
		for _, to_id in ipairs(edges) do
			if not M.data.backlinks[to_id] then
				M.data.backlinks[to_id] = {}
			end
			table.insert(M.data.backlinks[to_id], from_id)
		end
	end
end

-- Calculate minimum distance from any vision using BFS
function M.calculate_distances()
	local queue = {}
	local visited = {}
	local max_iterations = vim.tbl_count(M.data.nodes) * 2 -- Safety limit
	local iterations = 0

	-- Start from all vision nodes with distance 0
	for _, vision_id in ipairs(M.data.vision_nodes) do
		table.insert(queue, { node = vision_id, distance = 0 })
		M.data.distances[vision_id] = 0
		visited[vision_id] = true
	end

	-- BFS to calculate distances with loop protection
	while #queue > 0 and iterations < max_iterations do
		iterations = iterations + 1
		local current = table.remove(queue, 1)

		-- Skip if node doesn't exist
		if not M.data.nodes[current.node] then
			goto continue
		end

		-- Check all nodes that this node links to
		local edges = M.data.edges[current.node] or {}
		for _, neighbor in ipairs(edges) do
			-- Skip self-references
			if neighbor ~= current.node and not visited[neighbor] then
				visited[neighbor] = true
				M.data.distances[neighbor] = current.distance + 1
				table.insert(queue, { node = neighbor, distance = current.distance + 1 })
			end
		end

		-- Also check backlinks (nodes that link to this one)
		local backlinks = M.data.backlinks[current.node] or {}
		for _, neighbor in ipairs(backlinks) do
			-- Skip self-references
			if neighbor ~= current.node and not visited[neighbor] then
				visited[neighbor] = true
				M.data.distances[neighbor] = current.distance + 1
				table.insert(queue, { node = neighbor, distance = current.distance + 1 })
			end
		end

		::continue::
	end

	-- Warn if we hit the iteration limit
	if iterations >= max_iterations then
		vim.notify(
			"Warning: Graph traversal hit iteration limit. Possible circular references.",
			"warn",
			{ title = "Zortex XP" }
		)
	end

	-- Mark unvisited nodes as orphans (use large number instead of infinity for JSON compatibility)
	for node_id, _ in pairs(M.data.nodes) do
		if not visited[node_id] then
			M.data.distances[node_id] = 999999 -- Large number instead of math.huge
		end
	end
end

-- Assign areas to all nodes based on connections
function M.assign_areas()
	for node_id, node in pairs(M.data.nodes) do
		node.areas = M.find_node_areas(node_id)
	end
end

-- Get node ID
function M.get_node_id(item)
	if item.name then
		-- Named items (visions, objectives, etc)
		return item.name
	elseif item.text then
		-- Tasks
		return item.file .. ":" .. item.text
	elseif item.type == "resource" then
		-- Resources
		return item.file .. ":resource:" .. item.name .. ":" .. (item.action or "")
	elseif item.type == "habit" then
		-- Habits
		return item.file .. ":habit:" .. item.name
	else
		-- Fallback
		return item.file .. ":" .. (item.line_number or "unknown")
	end
end

-- Get node by ID
function M.get_node(node_id)
	return M.data.nodes[node_id]
end

-- Get distance from vision
function M.get_distance(node_id)
	if M.data.dirty then
		M.build()
	end
	return M.data.distances[node_id] or 999999
end

-- Get distance display string
function M.get_distance_display(node_id)
	local distance = M.get_distance(node_id)
	if distance >= 999999 then
		return "∞"
	else
		return tostring(distance)
	end
end

-- Find areas connected to a node
function M.find_node_areas(node_id, max_depth)
	max_depth = max_depth or 5
	local areas = {}
	local visited = {}
	local max_iterations = 100 -- Safety limit
	local iterations = 0

	local function traverse(id, depth)
		iterations = iterations + 1
		if depth > max_depth or visited[id] or iterations > max_iterations then
			return
		end
		visited[id] = true

		local node = M.data.nodes[id]
		if node and node.type == "area" then
			areas[node.name] = true
		end

		-- Check edges
		local edges = M.data.edges[id] or {}
		for _, edge_id in ipairs(edges) do
			if edge_id ~= id then -- Skip self-references
				traverse(edge_id, depth + 1)
			end
		end

		-- Check backlinks
		local backlinks = M.data.backlinks[id] or {}
		for _, backlink_id in ipairs(backlinks) do
			if backlink_id ~= id then -- Skip self-references
				traverse(backlink_id, depth + 1)
			end
		end
	end

	traverse(node_id, 0)

	-- Convert to list
	local area_list = {}
	for area, _ in pairs(areas) do
		table.insert(area_list, area)
	end

	return area_list
end

-- Find task areas (convenience function)
function M.find_task_areas(task)
	local node_id = M.get_node_id(task)
	return M.find_node_areas(node_id)
end

-- Find parent of specific type
function M.find_parent_of_type(node_id, parent_type, max_depth)
	max_depth = max_depth or 3
	local visited = {}
	local max_iterations = 50 -- Safety limit
	local iterations = 0

	local function search(id, depth)
		iterations = iterations + 1
		if depth > max_depth or visited[id] or iterations > max_iterations then
			return nil
		end
		visited[id] = true

		-- Check backlinks (parents)
		local backlinks = M.data.backlinks[id] or {}
		for _, parent_id in ipairs(backlinks) do
			if parent_id ~= id then -- Skip self-references
				local parent = M.data.nodes[parent_id]
				if parent and parent.type == parent_type then
					return parent_id
				end

				-- Recursive search
				local found = search(parent_id, depth + 1)
				if found then
					return found
				end
			end
		end

		return nil
	end

	return search(node_id, 0)
end

-- Find all connected nodes of type
function M.find_connected_of_type(node_id, node_type, max_depth)
	max_depth = max_depth or 3
	local found = {}
	local visited = {}
	local max_iterations = 100 -- Safety limit
	local iterations = 0

	local function search(id, depth)
		iterations = iterations + 1
		if depth > max_depth or visited[id] or iterations > max_iterations then
			return
		end
		visited[id] = true

		local node = M.data.nodes[id]
		if node and node.type == node_type then
			table.insert(found, id)
		end

		-- Search edges
		local edges = M.data.edges[id] or {}
		for _, edge_id in ipairs(edges) do
			if edge_id ~= id then -- Skip self-references
				search(edge_id, depth + 1)
			end
		end

		-- Search backlinks
		local backlinks = M.data.backlinks[id] or {}
		for _, backlink_id in ipairs(backlinks) do
			if backlink_id ~= id then -- Skip self-references
				search(backlink_id, depth + 1)
			end
		end
	end

	search(node_id, 0)
	return found
end

-- Get graph statistics
function M.get_stats()
	local stats = {
		total_nodes = vim.tbl_count(M.data.nodes),
		vision_nodes = #M.data.vision_nodes,
		area_nodes = vim.tbl_count(M.data.areas),
		orphan_nodes = 0,
		type_counts = {},
		distance_distribution = {},
	}

	-- Count node types and distances
	for node_id, node in pairs(M.data.nodes) do
		-- Type counts
		local node_type = node.type or "unknown"
		stats.type_counts[node_type] = (stats.type_counts[node_type] or 0) + 1

		-- Distance distribution
		local distance = M.data.distances[node_id] or 999999
		if distance >= 999999 then -- Changed from math.huge
			stats.orphan_nodes = stats.orphan_nodes + 1
		else
			stats.distance_distribution[distance] = (stats.distance_distribution[distance] or 0) + 1
		end
	end

	return stats
end

-- Mark graph as dirty (needs rebuilding)
function M.mark_dirty()
	M.data.dirty = true
end

-- Force rebuild on next access
function M.ensure_built()
	if M.data.dirty then
		M.build()
	end
end

return M
