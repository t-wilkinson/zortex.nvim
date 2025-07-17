-- xp/areas.lua - Area XP management
local M = {}

local xp_core = require("zortex.xp.core")
local xp_store = require("zortex.stores.xp")
local parser = require("zortex.core.parser")

-- =============================================================================
-- Area XP Management
-- =============================================================================

-- Add XP to an area with bubbling to parents
function M.add_xp(area_path, xp_amount, parent_links)
    if xp_amount <= 0 then
        return 0
    end
    
    -- Get current area data
    local area_data = xp_store.get_area_xp(area_path)
    local old_level = area_data.level
    
    -- Add XP
    area_data.xp = area_data.xp + xp_amount
    area_data.level = xp_core.calculate_area_level(area_data.xp)
    
    -- Save updated data
    xp_store.set_area_xp(area_path, area_data.xp, area_data.level)
    
    -- Notify if leveled up
    if area_data.level > old_level then
        vim.notify(
            string.format("🎯 Area Level Up! %s is now level %d", area_path, area_data.level), 
            vim.log.levels.INFO
        )
    end
    
    -- Bubble XP to parent areas
    if parent_links and #parent_links > 0 then
        local bubble_xp = xp_core.calculate_parent_bubble(xp_amount, #parent_links)
        
        for _, parent_link in ipairs(parent_links) do
            local parent_path = M.parse_area_path(parent_link)
            if parent_path and parent_path ~= area_path then
                -- Recursive call without further parents to prevent infinite loops
                M.add_xp(parent_path, bubble_xp, nil)
            end
        end
    end
    
    return xp_amount
end

-- Remove XP from an area (for task uncomplete)
function M.remove_xp(area_path, xp_amount)
    if xp_amount <= 0 then
        return 0
    end
    
    local area_data = xp_store.get_area_xp(area_path)
    
    -- Remove XP (never go below 0)
    area_data.xp = math.max(0, area_data.xp - xp_amount)
    area_data.level = xp_core.calculate_area_level(area_data.xp)
    
    -- Save updated data
    xp_store.set_area_xp(area_path, area_data.xp, area_data.level)
    
    return -xp_amount
end

-- =============================================================================
-- Area Path Parsing
-- =============================================================================

-- Parse area link into path
function M.parse_area_path(area_link)
    if not area_link then
        return nil
    end
    
    -- Handle string that's already a path
    if type(area_link) == "string" and not area_link:match("^%[") then
        -- Check if it starts with common area prefixes
        if area_link:match("^A/") or area_link:match("^Areas/") then
            return area_link:gsub("^A/", ""):gsub("^Areas/", "")
        end
        return area_link
    end
    
    -- Parse link definition
    local parsed = parser.parse_link_definition(area_link)
    if not parsed or #parsed.components == 0 then
        return nil
    end
    
    return M.build_area_path(parsed.components)
end

-- Build area path from parsed components
function M.build_area_path(components)
    local path_parts = {}
    
    -- Skip the leading article "A" / "Areas" if present
    local start_idx = 1
    if #components > 0 and components[1].type == "article" and 
       (components[1].text == "A" or components[1].text == "Areas") then
        start_idx = 2
    end
    
    -- Build path from remaining components
    for i = start_idx, #components do
        local comp = components[i]
        if comp.type == "heading" or comp.type == "label" or comp.type == "article" then
            table.insert(path_parts, comp.text)
        end
    end
    
    return #path_parts > 0 and table.concat(path_parts, "/") or nil
end

-- =============================================================================
-- Area Statistics
-- =============================================================================

-- Get stats for a specific area
function M.get_area_stats(area_path)
    local area_data = xp_store.get_area_xp(area_path)
    local progress = xp_core.get_level_progress(
        area_data.xp, 
        area_data.level, 
        xp_core.calculate_area_level_xp
    )
    
    return {
        path = area_path,
        xp = area_data.xp,
        level = area_data.level,
        progress = progress.progress,
        xp_to_next = progress.xp_to_next,
        next_threshold = progress.next_threshold
    }
end

-- Get all area stats
function M.get_all_stats()
    local all_xp = xp_store.get_all_area_xp()
    local stats = {}
    
    for path, data in pairs(all_xp) do
        local progress = xp_core.get_level_progress(
            data.xp,
            data.level,
            xp_core.calculate_area_level_xp
        )
        
        stats[path] = {
            xp = data.xp,
            level = data.level,
            progress = progress.progress,
            xp_to_next = progress.xp_to_next
        }
    end
    
    return stats
end

-- Get top areas by XP
function M.get_top_areas(limit)
    limit = limit or 10
    local all_stats = M.get_all_stats()
    local sorted = {}
    
    for path, stats in pairs(all_stats) do
        table.insert(sorted, {
            path = path,
            xp = stats.xp,
            level = stats.level
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
-- Objective Completion
-- =============================================================================

-- Complete an objective and award area XP
function M.complete_objective(objective_id, objective_text, time_horizon, area_links, created_date)
    -- Check if already completed
    if xp_store.is_objective_completed(objective_id) then
        return 0
    end
    
    -- Calculate total XP
    local total_xp = xp_core.calculate_objective_xp(time_horizon, created_date)
    
    -- Award XP to linked areas
    if area_links and #area_links > 0 then
        local xp_per_area = math.floor(total_xp / #area_links)
        
        for _, area_link in ipairs(area_links) do
            local area_path = M.parse_area_path(area_link)
            if area_path then
                -- Add XP with parent bubbling
                M.add_xp(area_path, xp_per_area, area_links)
            end
        end
    end
    
    -- Mark objective as completed
    xp_store.mark_objective_completed(objective_id, total_xp)
    
    return total_xp
end

return M