-- services/area.lua - Area management service
local M = {}

local workspace = require("zortex.core.workspace")
local xp_store = require("zortex.stores.xp")

function M.get_area_links(attrs)
	local area_links = {}
	if attrs and attrs.area then
		for _, area_obj in ipairs(attrs.area) do
			table.insert(area_links, area_obj.path)
		end
	end

	if #area_links == 0 then
		return nil
	else
		return area_links
	end
end

-- =============================================================================
-- Area Tree Management
-- =============================================================================

-- Parse areas file and build tree
function M.get_area_tree()
	local doc = workspace.areas()

	-- Build area tree from document sections
	local root = {
		name = "Areas",
		path = "",
		level = 0,
		children = {},
		xp_data = nil,
	}

	-- Convert document sections to area tree
	M._build_area_tree_from_sections(doc.sections, root)

	-- Apply XP data
	M._apply_xp_to_tree(root)

	return root
end

-- =============================================================================
-- Area Link Parsing
-- =============================================================================

-- Helper to extract area paths from various objects/attributes
function M.extract_area_paths(...)
	local sources = { ... }
	local paths = {}

	for _, source in ipairs(sources) do
		if source and source.attributes and source.attributes.area then
			for _, area_obj in ipairs(source.attributes.area) do
				table.insert(paths, area_obj.path)
			end
		end
	end

	return paths
end

-- =============================================================================
-- Private Helper Functions
-- =============================================================================

function M._build_area_tree_from_sections(section, parent)
	if not section then
		return
	end

	for _, child in ipairs(section.children or {}) do
		if child.type == "heading" or child.type == "label" then
			local node = {
				name = child.text,
				path = parent.path ~= "" and (parent.path .. "/" .. child.text) or child.text,
				level = child.level or parent.level + 1,
				children = {},
				parent = parent,
				xp_data = nil,
			}

			table.insert(parent.children, node)
			M._build_area_tree_from_sections(child, node)
		end
	end
end

function M._apply_xp_to_tree(node)
	if node.path and node.path ~= "" then
		node.xp_data = xp_store.get_area_xp(node.path)
	end

	for _, child in ipairs(node.children) do
		M._apply_xp_to_tree(child)
	end
end

-- function M._get_parent_path(area_path)
-- 	local parts = vim.split(area_path, "/")
-- 	if #parts <= 1 then
-- 		return nil
-- 	end
--
-- 	table.remove(parts)
-- 	return table.concat(parts, "/")
-- end

return M
