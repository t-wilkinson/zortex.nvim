-- modules/projects.lua - Project module using new service architecture
local M = {}

local ProjectService = require("zortex.services.project_service")
local DocumentManager = require("zortex.core.document_manager")
local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local fs = require("zortex.core.filesystem")
local datetime = require("zortex.core.datetime")
local parser = require("zortex.core.parser")

-- Cache for backward compatibility
local projects_cache = nil
local cache_timestamp = 0
local CACHE_DURATION = 5 -- seconds

-- =============================================================================
-- Project Loading (Delegating to Service)
-- =============================================================================

-- Load projects (backward compatibility wrapper)
function M.load()
  local stop_timer = Logger.start_timer("projects.load")
  
  -- Check cache
  local now = os.time()
  if projects_cache and (now - cache_timestamp) < CACHE_DURATION then
    stop_timer({ cached = true })
    return projects_cache
  end
  
  -- Load through service
  local projects = ProjectService.get_all_projects()
  
  -- Transform to legacy format if needed
  projects_cache = {}
  for _, project in ipairs(projects) do
    table.insert(projects_cache, M._transform_to_legacy(project))
  end
  
  cache_timestamp = now
  stop_timer({ count = #projects_cache })
  
  -- Emit loaded event
  EventBus.emit("projects:loaded", {
    count = #projects_cache,
    timestamp = now,
  })
  
  return projects_cache
end

-- Transform service project to legacy format
function M._transform_to_legacy(project)
  return {
    name = project.name,
    line_num = project.line_num,
    level = project.section and project.section.level or 1,
    tasks = project.tasks,
    attributes = project.attributes,
    stats = project.stats,
    -- Additional legacy fields
    text = project.section and project.section.raw_text or project.name,
    children = {}, -- Would need to process subprojects
  }
end

-- =============================================================================
-- Project Queries (Using Service)
-- =============================================================================

-- Get all projects
function M.get_all_projects()
  M.load() -- Ensure loaded
  return projects_cache or {}
end

-- Get project by name
function M.get_project_by_name(name)
  local projects = ProjectService.get_all_projects()
  
  local function find_project(project_list, target_name)
    for _, project in ipairs(project_list) do
      if project.name == target_name then
        return project
      end
      if project.subprojects then
        local found = find_project(project.subprojects, target_name)
        if found then return found end
      end
    end
    return nil
  end
  
  local project = find_project(projects, name)
  return project and M._transform_to_legacy(project) or nil
end

-- Get project at line
function M.get_project_at_line(line_num, bufnr)
  local project = ProjectService.get_project_at_line(bufnr, line_num)
  return project and M._transform_to_legacy(project) or nil
end

-- Get project stats
function M.get_project_stats(project)
  -- If passed a project object, use its stats
  if project and project.stats then
    return project.stats
  end
  
  -- If passed a name, look it up
  if type(project) == "string" then
    local proj = M.get_project_by_name(project)
    return proj and proj.stats or {
      total_tasks = 0,
      completed_tasks = 0,
      completion_rate = 0,
    }
  end
  
  return {
    total_tasks = 0,
    completed_tasks = 0,
    completion_rate = 0,
  }
end

-- =============================================================================
-- Project Progress (Using Service)
-- =============================================================================

-- Update project progress
function M.update_project_progress(bufnr)
  return ProjectService.update_all_project_progress(bufnr)
end

-- Get all project statistics
function M.get_all_stats()
  return ProjectService.get_all_stats()
end

-- =============================================================================
-- Project Tree (Using Service)
-- =============================================================================

-- Get project tree
function M.get_project_tree()
  return ProjectService.get_project_tree()
end

-- Get project path
function M.get_project_path(project)
  if type(project) == "string" then
    project = M.get_project_by_name(project)
  end
  
  if not project then
    return nil
  end
  
  -- Build path manually for legacy format
  local parts = { project.name }
  -- Would need parent traversal for full path
  return table.concat(parts, " / ")
end

-- =============================================================================
-- Project Filtering
-- =============================================================================

-- Get active projects
function M.get_active_projects()
  local all_projects = M.get_all_projects()
  local active = {}
  
  for _, project in ipairs(all_projects) do
    if not project.attributes or 
       (project.attributes.status ~= "completed" and 
        project.attributes.status ~= "archived") then
      table.insert(active, project)
    end
  end
  
  return active
end

-- Get projects by priority
function M.get_projects_by_priority(priority)
  local all_projects = M.get_all_projects()
  local filtered = {}
  
  for _, project in ipairs(all_projects) do
    if project.attributes and project.attributes.priority == priority then
      table.insert(filtered, project)
    end
  end
  
  return filtered
end

-- Get projects with due dates
function M.get_projects_with_due_dates()
  local all_projects = M.get_all_projects()
  local with_due = {}
  
  for _, project in ipairs(all_projects) do
    if project.attributes and project.attributes.due then
      local due_date = datetime.parse_date(project.attributes.due)
      if due_date then
        table.insert(with_due, {
          project = project,
          due_date = due_date,
          due_str = project.attributes.due,
          days_until = math.floor((os.time(due_date) - os.time()) / 86400),
        })
      end
    end
  end
  
  -- Sort by due date
  table.sort(with_due, function(a, b)
    return os.time(a.due_date) < os.time(b.due_date)
  end)
  
  return with_due
end

-- =============================================================================
-- Project Creation/Modification
-- =============================================================================

-- Create new project (would need buffer manipulation)
function M.create_project(name, attributes)
  vim.notify("Project creation through module not yet implemented", vim.log.levels.INFO)
  return false
end

-- Archive project
function M.archive_project(project_name)
  local project = M.get_project_by_name(project_name)
  if not project then
    return false, "Project not found"
  end
  
  -- Use archive service
  local ArchiveService = require("zortex.services.archive_service")
  return ArchiveService.archive_project(project, { remove_original = true })
end

-- =============================================================================
-- Utility Functions
-- =============================================================================

-- Check if file is projects file
function M.is_projects_file(filepath)
  local projects_file = fs.get_projects_file()
  return filepath == projects_file
end

-- Open projects file
function M.open_projects_file()
  local filepath = fs.get_projects_file()
  if filepath then
    vim.cmd("edit " .. filepath)
    return true
  end
  return false
end

-- =============================================================================
-- Event Handlers
-- =============================================================================

-- Clear cache on document changes
EventBus.on("document:changed", function(data)
  if data.document and data.document.filepath then
    local projects_file = fs.get_projects_file()
    if data.document.filepath == projects_file then
      -- Clear cache
      projects_cache = nil
      cache_timestamp = 0
      
      Logger.debug("projects", "Cache cleared due to document change")
    end
  end
end, {
  priority = 50,
  name = "projects.cache_clear"
})

-- Listen for project updates
EventBus.on("project:progress_updated", function(data)
  -- Update cache if loaded
  if projects_cache then
    for _, project in ipairs(projects_cache) do
      if project.name == data.project_name then
        project.stats = data.stats
        break
      end
    end
  end
end, {
  priority = 40,
  name = "projects.cache_update"
})

-- =============================================================================
-- Legacy Support
-- =============================================================================

-- These functions maintain backward compatibility

function M.get_project_children(project)
  -- In new architecture, would get subprojects
  return project.children or {}
end

function M.get_project_level(project)
  return project.level or 1
end

function M.is_project_line(line)
  -- Check if line looks like a project heading
  return parser.is_heading_line(line) or parser.is_bold_heading_line(line)
end

return M