-- services/area.lua - Area management service
local M = {}

local Events = require("zortex.core.event_bus")
local Doc = require("zortex.core.document_manager")
local Logger = require("zortex.core.logger")
local parser = require("zortex.utils.parser")
local xp_store = require("zortex.stores.xp")
local xp_core = require("zortex.services.xp.calculator")
local constants = require("zortex.constants")

-- Cache for area tree
local area_cache = {
	tree = nil,
	last_update = 0,
	ttl = 300, -- 5 minutes
}

-- =============================================================================
-- Area Tree Management
-- =============================================================================

-- Parse areas file and build tree
function M.get_area_tree()
	-- Check cache
	if area_cache.tree and (os.time() - area_cache.last_update) < area_cache.ttl then
		return area_cache.tree
	end

	local doc = Doc.get_file(constants.FILES.AREAS)

	if not doc then
		Logger.warn("area_service", "Areas file not found", { file = constants.FILES.AREAS })
		return nil
	end

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

	-- Update cache
	area_cache.tree = root
	area_cache.last_update = os.time()

	return root
end

-- Invalidate area cache
function M.invalidate_cache()
	area_cache.tree = nil
	area_cache.last_update = 0
end

-- =============================================================================
-- XP Management
-- =============================================================================

-- Add XP to area with parent bubbling
function M.add_area_xp(area_path, xp_amount)
	if xp_amount <= 0 then
		return 0
	end

	local area_data = xp_store.get_area_xp(area_path)
	local old_level = area_data.level

	-- Add XP
	area_data.xp = area_data.xp + xp_amount
	area_data.level = xp_core.calculate_area_level(area_data.xp)

	-- Save
	xp_store.set_area_xp(area_path, area_data.xp, area_data.level)

	-- Level up notification
	if area_data.level > old_level then
		Events.emit("area:leveled_up", {
			path = area_path,
			old_level = old_level,
			new_level = area_data.level,
		})
	end

	-- Bubble to parents
	local parent_path = M._get_parent_path(area_path)
	if parent_path then
		local bubble_amount = xp_core.calculate_parent_bubble(xp_amount, 1)
		M.add_area_xp(parent_path, bubble_amount)
	end

	Logger.debug("area_service", "Added area XP", {
		path = area_path,
		amount = xp_amount,
		new_total = area_data.xp,
		new_level = area_data.level,
	})

	return xp_amount
end

-- Remove XP from area (for task uncomplete)
function M.remove_area_xp(area_path, xp_amount)
	if xp_amount <= 0 then
		return 0
	end

	local area_data = xp_store.get_area_xp(area_path)
	local old_level = area_data.level

	-- Remove XP (minimum 0)
	area_data.xp = math.max(0, area_data.xp - xp_amount)
	area_data.level = xp_core.calculate_area_level(area_data.xp)

	-- Save
	xp_store.set_area_xp(area_path, area_data.xp, area_data.level)

	-- Level down notification (rare but possible)
	if area_data.level < old_level then
		Events.emit("area:leveled_down", {
			path = area_path,
			old_level = old_level,
			new_level = area_data.level,
		})
	end

	-- Remove from parents too
	local parent_path = M._get_parent_path(area_path)
	if parent_path then
		local bubble_amount = xp_core.calculate_parent_bubble(xp_amount, 1)
		M.remove_area_xp(parent_path, bubble_amount)
	end

	return xp_amount
end

-- =============================================================================
-- Area Link Parsing
-- =============================================================================

-- Extract area links from text
function M.extract_area_links(text)
	if not text then
		return {}
	end

	local links = {}
	local all_links = parser.extract_all_links(text)

	for _, link_info in ipairs(all_links) do
		if link_info.type == "link" then
			local parsed = parser.parse_link_definition(link_info.definition)
			if parsed and M._is_area_link(parsed) then
				table.insert(links, link_info.definition)
			end
		end
	end

	return links
end

-- Parse area link to path
function M.parse_area_path(area_link)
	if type(area_link) == "string" and not area_link:match("^%[") then
		-- Already a path
		return area_link:gsub("^A/", ""):gsub("^Areas/", "")
	end

	local parsed = parser.parse_link_definition(area_link)
	if not parsed or not M._is_area_link(parsed) then
		return nil
	end

	-- Build path from components
	local parts = {}
	for i = 2, #parsed.components do -- Skip A/Areas prefix
		local comp = parsed.components[i]
		if comp.type == "heading" or comp.type == "label" or comp.type == "article" then
			table.insert(parts, comp.text)
		end
	end

	return table.concat(parts, "/")
end

-- =============================================================================
-- Objective Completion
-- =============================================================================

-- Complete objective and award area XP
function M.complete_objective(objective_id, objective_data)
	if xp_store.is_objective_completed(objective_id) then
		return 0
	end

	-- Calculate XP
	local total_xp = xp_core.calculate_objective_xp(objective_data.time_horizon, objective_data.created_date)

	-- Distribute to areas
	local distribution = {
		objective_id = objective_id,
		total_xp = total_xp,
		areas = {},
	}

	if objective_data.area_links and #objective_data.area_links > 0 then
		local xp_per_area = math.floor(total_xp / #objective_data.area_links)

		for _, area_link in ipairs(objective_data.area_links) do
			local area_path = M.parse_area_path(area_link)
			if area_path then
				M.add_area_xp(area_path, xp_per_area)
				table.insert(distribution.areas, {
					path = area_path,
					xp = xp_per_area,
				})
			end
		end
	end

	-- Mark completed
	xp_store.mark_objective_completed(objective_id, total_xp)

	-- Emit event
	Events.emit("objective:completed", {
		objective = objective_data,
		distribution = distribution,
	})

	Logger.info("area_service", "Objective completed", {
		id = objective_id,
		xp = total_xp,
		areas = #distribution.areas,
	})

	return total_xp
end

-- =============================================================================
-- Statistics
-- =============================================================================

-- Get area statistics
function M.get_area_stats(area_path)
	if area_path then
		-- Single area stats
		local data = xp_store.get_area_xp(area_path)
		local progress = xp_core.get_level_progress(data.xp, data.level, xp_core.calculate_area_level_xp)

		return {
			path = area_path,
			xp = data.xp,
			level = data.level,
			progress = progress,
		}
	else
		-- All areas
		return xp_store.get_all_area_xp()
	end
end

-- Get top areas by XP
function M.get_top_areas(limit)
	limit = limit or 10
	local all_areas = xp_store.get_all_area_xp()
	local sorted = {}

	for path, data in pairs(all_areas) do
		table.insert(sorted, {
			path = path,
			xp = data.xp,
			level = data.level,
		})
	end

	table.sort(sorted, function(a, b)
		return a.xp > b.xp
	end)

	-- Return top N
	local result = {}
	for i = 1, math.min(limit, #sorted) do
		table.insert(result, sorted[i])
	end

	return result
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

function M._is_area_link(parsed_link)
	if #parsed_link.components == 0 then
		return false
	end

	local first = parsed_link.components[1]
	return first.type == "article" and (first.text == "A" or first.text == "Areas")
end

function M._get_parent_path(area_path)
	local parts = vim.split(area_path, "/")
	if #parts <= 1 then
		return nil
	end

	table.remove(parts)
	return table.concat(parts, "/")
end

-- =============================================================================
-- Initialization
-- =============================================================================

-- Set up event listeners
function M.init()
	-- Listen for document changes to invalidate cache
	Events.on("document:changed", function(data)
		if data.document and data.document.filepath then
			local filename = vim.fn.fnamemodify(data.document.filepath, ":t")
			if filename == "areas.zortex" then
				M.invalidate_cache()
			end
		end
	end, {
		priority = 50,
		name = "area_service.cache_invalidator",
	})
end

return M
