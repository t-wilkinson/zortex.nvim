-- stores/areas.lua - Optional area hierarchy cache
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