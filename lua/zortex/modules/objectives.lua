-- modules/objectives.lua - OKR management
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local constants = require("zortex.constants")
local areas = require("zortex.modules.areas")
local projects = require("zortex.modules.projects")
local xp_notifs = require("zortex.xp.notifications")

-- =============================================================================
-- OKR Structure
-- =============================================================================

local function create_objective(date_info, line_num)
    -- Generate ID from date and title
    local id = string.format("%s_%d_%d_%s",
        date_info.span,
        date_info.year,
        date_info.month,
        date_info.title:gsub("[^%w]", "_")
    )
    
    return {
        id = id,
        span = date_info.span,
        year = date_info.year,
        month = date_info.month,
        title = date_info.title,
        line_num = line_num,
        key_results = {},
        area_links = {},
        completed = false,
        created_date = nil,
    }
end

local function create_key_result(text, line_num)
    return {
        text = text,
        line_num = line_num,
        linked_projects = {},
        completed = false,
    }
end

-- =============================================================================
-- OKR Parsing
-- =============================================================================

function M.parse_okr_file()
    local okr_file = fs.get_okr_file()
    if not okr_file or not fs.file_exists(okr_file) then
        return nil
    end
    
    local lines = fs.read_lines(okr_file)
    if not lines then
        return nil
    end
    
    local objectives = {}
    local current_objective = nil
    
    for i, line in ipairs(lines) do
        -- Check for objective heading
        local okr_date = parser.parse_okr_date(line)
        if okr_date then
            -- Save previous objective
            if current_objective then
                table.insert(objectives, current_objective)
            end
            
            -- Create new objective
            current_objective = create_objective(okr_date, i)
            
            -- Get area links (next line)
            if i < #lines then
                current_objective.area_links = areas.extract_area_links(lines[i + 1])
            end
            
            -- Extract created date if present
            local created_date = parser.extract_attribute(line, "created")
            if created_date then
                -- Parse date
                local date_parsed = parser.parse_attributes(
                    "@created(" .. created_date .. ")",
                    { created = { type = "date" } }
                )
                if date_parsed.created then
                    current_objective.created_date = os.time({
                        year = date_parsed.created.year,
                        month = date_parsed.created.month,
                        day = date_parsed.created.day,
                    })
                end
            end
            
            -- Check if completed
            current_objective.completed = parser.extract_attribute(line, "done") ~= nil
            
        elseif line:match(constants.PATTERNS.KEY_RESULT) and current_objective then
            -- Parse key result
            local kr_text = line:match("^%s*- KR%-(.+)$")
            if kr_text then
                local kr = create_key_result(kr_text, i)
                
                -- Extract linked projects
                local all_links = parser.extract_all_links(kr_text)
                for _, link_info in ipairs(all_links) do
                    if link_info.type == "link" then
                        local parsed = parser.parse_link_definition(link_info.definition)
                        if parsed and #parsed.components > 0 then
                            for _, component in ipairs(parsed.components) do
                                if component.type == "article" then
                                    table.insert(kr.linked_projects, component.text)
                                end
                            end
                        end
                    end
                end
                
                table.insert(current_objective.key_results, kr)
            end
        end
    end
    
    -- Add last objective
    if current_objective then
        table.insert(objectives, current_objective)
    end
    
    return objectives
end

-- =============================================================================
-- Progress Checking
-- =============================================================================

local function is_project_completed(project_name)
    -- Load projects
    projects.load()
    
    -- Check in active projects
    local project = projects.find_project(project_name)
    if project then
        return project.attributes.done ~= nil
    end
    
    -- Check in archive
    local archive_file = fs.get_archive_file()
    if archive_file and fs.file_exists(archive_file) then
        local lines = fs.read_lines(archive_file)
        if lines then
            for _, line in ipairs(lines) do
                local heading = parser.parse_heading(line)
                if heading then
                    local clean_name, _ = parser.parse_attributes(heading.text)
                    if clean_name:lower() == project_name:lower() then
                        return true
                    end
                end
            end
        end
    end
    
    return false
end

function M.update_okr_progress()
    local okr_file = fs.get_okr_file()
    if not okr_file or not fs.file_exists(okr_file) then
        return false
    end
    
    local lines = fs.read_lines(okr_file)
    if not lines then
        return false
    end
    
    local modified = false
    local objectives = M.parse_okr_file()
    
    -- Process each objective
    for _, objective in ipairs(objectives) do
        local completed_krs = 0
        local total_krs = #objective.key_results
        
        -- Check each key result
        for _, kr in ipairs(objective.key_results) do
            local all_completed = true
            local has_projects = #kr.linked_projects > 0
            
            for _, project_name in ipairs(kr.linked_projects) do
                if not is_project_completed(project_name) then
                    all_completed = false
                    break
                end
            end
            
            if has_projects and all_completed then
                completed_krs = completed_krs + 1
                kr.completed = true
            end
        end
        
        -- Update objective line
        local old_line = lines[objective.line_num]
        local new_line = parser.update_attribute(
            old_line, 
            "progress", 
            string.format("%d/%d", completed_krs, total_krs)
        )
        
        -- Check if objective is now complete
        local was_completed = objective.completed
        local is_completed = total_krs > 0 and completed_krs == total_krs
        
        if is_completed and not was_completed then
            new_line = parser.update_attribute(new_line, "done", os.date("%Y-%m-%d"))
            
            -- Award XP for objective completion
            if #objective.area_links > 0 then
                local xp_awarded = areas.process_objective_completion(
                    objective.id,
                    objective.title,
                    objective.span,
                    objective.area_links,
                    objective.created_date
                )
                
                -- Get area awards for notification
                local area_awards = {}
                local xp_per_area = math.floor(xp_awarded / #objective.area_links)
                for _, link in ipairs(objective.area_links) do
                    local path = require("zortex.xp.areas").parse_area_path(link)
                    if path then
                        table.insert(area_awards, {
                            path = path,
                            xp = xp_per_area
                        })
                    end
                end
                
                xp_notifs.notify_objective_completion(
                    objective.title,
                    xp_awarded,
                    area_awards
                )
            end
        elseif not is_completed and was_completed then
            new_line = parser.remove_attribute(new_line, "done")
        end
        
        if new_line ~= old_line then
            lines[objective.line_num] = new_line
            modified = true
        end
    end
    
    if modified then
        fs.write_lines(okr_file, lines)
    end
    
    return modified
end

-- =============================================================================
-- Query Functions
-- =============================================================================

function M.get_current_objectives()
    local objectives = M.parse_okr_file()
    if not objectives then
        return {}
    end
    
    -- Filter to current/active objectives
    local current_time = os.time()
    local current = {}
    
    for _, obj in ipairs(objectives) do
        if not obj.completed then
            table.insert(current, obj)
        end
    end
    
    return current
end

function M.get_objective_stats()
    local objectives = M.parse_okr_file()
    if not objectives then
        return nil
    end
    
    local stats = {
        total = #objectives,
        completed = 0,
        by_span = {},
        completion_rate = 0,
    }
    
    for _, obj in ipairs(objectives) do
        if obj.completed then
            stats.completed = stats.completed + 1
        end
        
        -- Count by span
        if not stats.by_span[obj.span] then
            stats.by_span[obj.span] = { total = 0, completed = 0 }
        end
        stats.by_span[obj.span].total = stats.by_span[obj.span].total + 1
        if obj.completed then
            stats.by_span[obj.span].completed = stats.by_span[obj.span].completed + 1
        end
    end
    
    if stats.total > 0 then
        stats.completion_rate = stats.completed / stats.total
    end
    
    return stats
end

return M