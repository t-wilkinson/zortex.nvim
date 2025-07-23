-- services/area.lua
local M = {}

local EventBus = require("zortex.core.event_bus")
local DocumentManager = require("zortex.core.document_manager")
local parser = require("zortex.core.parser")
local xp_store = require("zortex.stores.xp")
local xp_core = require("zortex.xp.core")

-- Parse areas file and build tree
function M.get_area_tree()
    local areas_file = vim.g.zortex_notes_dir .. "/areas.zortex"
    local doc = DocumentManager.get_file(areas_file)
    if not doc then
        return nil
    end

    -- Build area tree from document sections
    local root = {
        name = "Areas",
        path = "",
        level = 0,
        children = {},
        xp_data = nil
    }

    -- Convert document sections to area tree
    M._build_area_tree_from_sections(doc.sections, root)

    -- Apply XP data
    M._apply_xp_to_tree(root)

    return root
end

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
        EventBus.emit("area:leveled_up", {
            path = area_path,
            old_level = old_level,
            new_level = area_data.level
        })
    end

    -- Bubble to parents
    local parent_path = M._get_parent_path(area_path)
    if parent_path then
        local bubble_amount = xp_core.calculate_parent_bubble(xp_amount, 1)
        M.add_area_xp(parent_path, bubble_amount)
    end

    return xp_amount
end

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

-- Complete objective and award area XP
function M.complete_objective(objective_id, objective_data)
    if xp_store.is_objective_completed(objective_id) then
        return 0
    end

    -- Calculate XP
    local total_xp = xp_core.calculate_objective_xp(
        objective_data.time_horizon,
        objective_data.created_date
    )

    -- Distribute to areas
    local distribution = {
        objective_id = objective_id,
        total_xp = total_xp,
        areas = {}
    }

    if objective_data.area_links and #objective_data.area_links > 0 then
        local xp_per_area = math.floor(total_xp / #objective_data.area_links)

        for _, area_link in ipairs(objective_data.area_links) do
            local area_path = M.parse_area_path(area_link)
            if area_path then
                M.add_area_xp(area_path, xp_per_area)
                table.insert(distribution.areas, {
                    path = area_path,
                    xp = xp_per_area
                })
            end
        end
    end

    -- Mark completed
    xp_store.mark_objective_completed(objective_id, total_xp)

    -- Emit event
    EventBus.emit("objective:completed", {
        objective = objective_data,
        distribution = distribution
    })

    return total_xp
end

-- Get area statistics
function M.get_area_stats(area_path)
    if area_path then
        -- Single area stats
        local data = xp_store.get_area_xp(area_path)
        local progress = xp_core.get_level_progress(
            data.xp,
            data.level,
            xp_core.calculate_area_level_xp
        )

        return {
            path = area_path,
            xp = data.xp,
            level = data.level,
            progress = progress
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
            level = data.level
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

-- Private helper functions
function M._build_area_tree_from_sections(section, parent)
    for _, child in ipairs(section.children) do
        if child.type == "heading" or child.type == "label" then
            local node = {
                name = child.text,
                path = parent.path ~= "" and (parent.path .. "/" .. child.text) or child.text,
                level = child.level or parent.level + 1,
                children = {},
                parent = parent,
                xp_data = nil
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

return M-- stores/areas.lua - Optional area hierarchy cache
local M = {}

local BaseStore = require("zortex.stores.base")
local constants = require("zortex.constants")

-- Create the singleton store
local store = BaseStore:new(".z/area_cache.json")

-- Override init_empty
function store:init_empty()
    self.data = {
        tree = nil,              -- Cached area tree structure
        last_modified = 0,       -- Last modification time of areas.zortex
        area_to_parent = {},     -- area_path -> parent_path mapping
        shortcuts = {},          -- Short name -> full path mapping
    }
    self.loaded = true
end

-- =============================================================================
-- Cache Management
-- =============================================================================

-- Check if cache is valid
function M.is_cache_valid()
    store:ensure_loaded()

    local areas_file = require("zortex.core.filesystem").get_areas_file()
    if not areas_file then
        return false
    end

    local stat = vim.loop.fs_stat(areas_file)
    if not stat then
        return false
    end

    return stat.mtime.sec <= store.data.last_modified
end

-- Update cache with new tree
function M.update_cache(tree)
    store:ensure_loaded()

    -- Clear existing data
    store.data.area_to_parent = {}
    store.data.shortcuts = {}

    -- Build mappings
    local function process_node(node, parent_path)
        if node.path and node.path ~= "" then
            -- Store parent mapping
            if parent_path then
                store.data.area_to_parent[node.path] = parent_path
            end

            -- Store shortcut (last component -> full path)
            local last_component = node.path:match("([^/]+)$")
            if last_component then
                -- Only store if unique
                if not store.data.shortcuts[last_component:lower()] then
                    store.data.shortcuts[last_component:lower()] = node.path
                end
            end
        end

        -- Process children
        for _, child in ipairs(node.children or {}) do
            process_node(child, node.path)
        end
    end

    if tree then
        store.data.tree = tree
        process_node(tree, nil)

        -- Update timestamp
        local areas_file = require("zortex.core.filesystem").get_areas_file()
        if areas_file then
            local stat = vim.loop.fs_stat(areas_file)
            if stat then
                store.data.last_modified = stat.mtime.sec
            end
        end

        store:save()
    end
end

-- Get cached tree
function M.get_cached_tree()
    if M.is_cache_valid() then
        store:ensure_loaded()
        return store.data.tree
    end
    return nil
end

-- =============================================================================
-- Quick Lookups
-- =============================================================================

-- Get parent path for an area
function M.get_parent_path(area_path)
    store:ensure_loaded()
    return store.data.area_to_parent[area_path]
end

-- Get all parent paths up to root
function M.get_all_parents(area_path)
    store:ensure_loaded()
    local parents = {}
    local current = area_path

    while current do
        local parent = store.data.area_to_parent[current]
        if parent then
            table.insert(parents, parent)
            current = parent
        else
            break
        end
    end

    return parents
end

-- Resolve shortcut to full path
function M.resolve_shortcut(shortcut)
    store:ensure_loaded()
    return store.data.shortcuts[shortcut:lower()]
end

-- Get all shortcuts
function M.get_all_shortcuts()
    store:ensure_loaded()
    return vim.deepcopy(store.data.shortcuts)
end

-- =============================================================================
-- Statistics
-- =============================================================================

-- Get area count
function M.get_area_count()
    store:ensure_loaded()
    return vim.tbl_count(store.data.area_to_parent) + 1 -- +1 for root
end

-- Clear cache
function M.clear_cache()
    store:init_empty()
    store:save()
end

return M
