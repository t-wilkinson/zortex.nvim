-- services/project_service.lua
-- Project management service using DocumentManager
local M = {}

local DocumentManager = require("zortex.core.document_manager")
local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local TaskService = require("zortex.services.task_service")
local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local constants = require("zortex.constants")

-- =============================================================================
-- Project Detection
-- =============================================================================

-- Check if a section is a project
local function is_project_section(section)
  -- Projects are level 1 or 2 headings in projects.zortex
  return section.type == constants.SECTION_TYPE.HEADING and 
         section.level and section.level <= 2
end

-- Get project attributes from section
local function get_project_attributes(section)
  local attrs = {}
  
  -- Parse attributes from section text
  local text = section.raw_text or section.text or ""
  
  -- Priority
  local priority = text:match("@p%((%d)%)")
  if priority then
    attrs.priority = "p" .. priority
  end
  
  -- Importance
  local importance = text:match("@i%((%d)%)")
  if importance then
    attrs.importance = "i" .. importance
  end
  
  -- Status
  if text:match("@done") or text:match("@completed") then
    attrs.status = "completed"
  elseif text:match("@archived") then
    attrs.status = "archived"
  elseif text:match("@paused") then
    attrs.status = "paused"
  else
    attrs.status = "active"
  end
  
  -- Due date
  local due = text:match("@due%(([^)]+)%)")
  if due then
    attrs.due = due
  end
  
  -- Size
  local size = text:match("@size%((%w+)%)")
  if size then
    attrs.size = size
  end
  
  return attrs
end

-- =============================================================================
-- Project Operations
-- =============================================================================

-- Get all projects from document
function M.get_projects_from_document(doc)
  if not doc or not doc.sections then
    return {}
  end
  
  local projects = {}
  
  local function collect_projects(section, parent_project)
    if is_project_section(section) then
      -- Create project object
      local project = {
        id = section:get_id(),
        name = section.text,
        section = section,
        attributes = get_project_attributes(section),
        tasks = {},
        subprojects = {},
        parent = parent_project,
        line_num = section.start_line,
        stats = {
          total_tasks = 0,
          completed_tasks = 0,
          completion_rate = 0,
        }
      }
      
      -- Collect tasks in this project
      local all_tasks = section:get_all_tasks()
      for _, task in ipairs(all_tasks) do
        table.insert(project.tasks, task)
        project.stats.total_tasks = project.stats.total_tasks + 1
        if task.completed then
          project.stats.completed_tasks = project.stats.completed_tasks + 1
        end
      end
      
      -- Calculate completion rate
      if project.stats.total_tasks > 0 then
        project.stats.completion_rate = project.stats.completed_tasks / project.stats.total_tasks
      end
      
      -- Add to parent or root
      if parent_project then
        table.insert(parent_project.subprojects, project)
      else
        table.insert(projects, project)
      end
      
      -- Process children for subprojects
      for _, child in ipairs(section.children) do
        collect_projects(child, project)
      end
    else
      -- Not a project, but check children
      for _, child in ipairs(section.children) do
        collect_projects(child, parent_project)
      end
    end
  end
  
  -- Start from root children
  for _, child in ipairs(doc.sections.children) do
    collect_projects(child, nil)
  end
  
  return projects
end

-- Get all projects
function M.get_all_projects()
  local projects_file = fs.get_projects_file()
  if not projects_file then
    Logger.warn("project_service", "No projects file found")
    return {}
  end
  
  local doc = DocumentManager.get_file(projects_file)
  if not doc then
    Logger.error("project_service", "Failed to load projects file")
    return {}
  end
  
  return M.get_projects_from_document(doc)
end

-- Get project at line
function M.get_project_at_line(bufnr, line_num)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  line_num = line_num or vim.api.nvim_win_get_cursor(0)[1]
  
  local doc = DocumentManager.get_buffer(bufnr)
  if not doc then
    return nil
  end
  
  local section = doc:get_section_at_line(line_num)
  if not section then
    return nil
  end
  
  -- Walk up to find project section
  local current = section
  while current do
    if is_project_section(current) then
      -- Create project object
      return {
        id = current:get_id(),
        name = current.text,
        section = current,
        attributes = get_project_attributes(current),
        line_num = current.start_line,
      }
    end
    current = current.parent
  end
  
  return nil
end

-- =============================================================================
-- Project Progress Updates
-- =============================================================================

-- Update progress indicators for a project
function M.update_project_progress(project)
  if not project.section or not project.section.raw_text then
    return false
  end
  
  local stop_timer = Logger.start_timer("project_service.update_progress")
  
  -- Calculate current stats
  local stats = project.stats or {}
  if not stats.total_tasks or not stats.completed_tasks then
    -- Recalculate
    local all_tasks = project.section:get_all_tasks()
    stats.total_tasks = #all_tasks
    stats.completed_tasks = 0
    
    for _, task in ipairs(all_tasks) do
      if task.completed then
        stats.completed_tasks = stats.completed_tasks + 1
      end
    end
  end
  
  -- Build new line text
  local original_text = project.section.raw_text
  local clean_text = original_text
  
  -- Remove existing progress indicator
  clean_text = clean_text:gsub("%s*%[%d+/%d+%]", "")
  clean_text = clean_text:gsub("%s*@done%b()", "")
  clean_text = clean_text:gsub("%s*@done", "")
  
  -- Add progress indicator
  local new_text = clean_text
  if stats.total_tasks > 0 then
    new_text = string.format("%s [%d/%d]", 
      clean_text, 
      stats.completed_tasks, 
      stats.total_tasks
    )
    
    -- Add @done if completed
    if stats.completed_tasks == stats.total_tasks then
      new_text = new_text .. " @done(" .. os.date("%Y-%m-%d") .. ")"
    end
  end
  
  -- Update buffer if changed
  if new_text ~= original_text then
    local bufnr = project.section.start_line and 
                  vim.fn.bufnr(fs.get_projects_file() or "")
    
    if bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_set_lines(
        bufnr,
        project.section.start_line - 1,
        project.section.start_line,
        false,
        { new_text }
      )
      
      -- Mark for reparse
      DocumentManager.mark_buffer_dirty(bufnr, 
        project.section.start_line,
        project.section.start_line
      )
    end
  end
  
  stop_timer()
  
  -- Emit event
  EventBus.emit("project:progress_updated", {
    project_id = project.id,
    project_name = project.name,
    stats = stats,
    completed = stats.total_tasks > 0 and stats.completed_tasks == stats.total_tasks,
  })
  
  return true
end

-- Update all project progress in document
function M.update_all_project_progress(bufnr)
  bufnr = bufnr or vim.fn.bufnr(fs.get_projects_file() or "")
  
  if not bufnr or bufnr < 0 then
    return 0
  end
  
  local stop_timer = Logger.start_timer("project_service.update_all_progress")
  
  local doc = DocumentManager.get_buffer(bufnr)
  if not doc then
    -- Try loading from file
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    doc = DocumentManager.load_buffer(bufnr, filepath)
  end
  
  if not doc then
    Logger.error("project_service", "Failed to load document for progress update")
    stop_timer()
    return 0
  end
  
  -- Get all projects
  local projects = M.get_projects_from_document(doc)
  local updated_count = 0
  
  -- Update each project
  for _, project in ipairs(projects) do
    if M.update_project_progress(project) then
      updated_count = updated_count + 1
    end
    
    -- Update subprojects
    local function update_subprojects(subprojects)
      for _, subproject in ipairs(subprojects) do
        if M.update_project_progress(subproject) then
          updated_count = updated_count + 1
        end
        if subproject.subprojects and #subproject.subprojects > 0 then
          update_subprojects(subproject.subprojects)
        end
      end
    end
    
    if project.subprojects and #project.subprojects > 0 then
      update_subprojects(project.subprojects)
    end
  end
  
  stop_timer({ updated_count = updated_count })
  
  return updated_count
end

-- =============================================================================
-- Project Statistics
-- =============================================================================

-- Get statistics for all projects
function M.get_all_stats()
  local projects = M.get_all_projects()
  
  local stats = {
    project_count = 0,
    active_projects = 0,
    completed_projects = 0,
    archived_projects = 0,
    total_tasks = 0,
    completed_tasks = 0,
    projects_by_priority = {},
    projects_by_importance = {},
  }
  
  local function process_project(project)
    stats.project_count = stats.project_count + 1
    
    -- Status counts
    if project.attributes.status == "completed" then
      stats.completed_projects = stats.completed_projects + 1
    elseif project.attributes.status == "archived" then
      stats.archived_projects = stats.archived_projects + 1
    else
      stats.active_projects = stats.active_projects + 1
    end
    
    -- Task counts
    if project.stats then
      stats.total_tasks = stats.total_tasks + project.stats.total_tasks
      stats.completed_tasks = stats.completed_tasks + project.stats.completed_tasks
    end
    
    -- Priority/Importance counts
    if project.attributes.priority then
      stats.projects_by_priority[project.attributes.priority] = 
        (stats.projects_by_priority[project.attributes.priority] or 0) + 1
    end
    
    if project.attributes.importance then
      stats.projects_by_importance[project.attributes.importance] = 
        (stats.projects_by_importance[project.attributes.importance] or 0) + 1
    end
    
    -- Process subprojects
    if project.subprojects then
      for _, subproject in ipairs(project.subprojects) do
        process_project(subproject)
      end
    end
  end
  
  -- Process all projects
  for _, project in ipairs(projects) do
    process_project(project)
  end
  
  return stats
end

-- Get project hierarchy as tree
function M.get_project_tree()
  local projects = M.get_all_projects()
  
  -- Build tree structure
  local tree = {
    name = "Projects",
    children = {},
  }
  
  local function build_tree_node(project)
    local node = {
      name = project.name,
      id = project.id,
      attributes = project.attributes,
      stats = project.stats,
      children = {},
    }
    
    if project.subprojects then
      for _, subproject in ipairs(project.subprojects) do
        table.insert(node.children, build_tree_node(subproject))
      end
    end
    
    return node
  end
  
  for _, project in ipairs(projects) do
    table.insert(tree.children, build_tree_node(project))
  end
  
  return tree
end

-- =============================================================================
-- Project Path
-- =============================================================================

-- Get full project path (including parent projects)
function M.get_project_path(project)
  local parts = {}
  
  -- Walk up parent chain
  local current = project
  while current do
    table.insert(parts, 1, current.name)
    current = current.parent
  end
  
  return table.concat(parts, " / ")
end

-- =============================================================================
-- Archive Operations
-- =============================================================================

-- Archive a completed project
function M.archive_project(project_id)
  -- This would move the project to an archive file
  -- For now, just emit event
  EventBus.emit("project:archived", {
    project_id = project_id,
    timestamp = os.time(),
  })
  
  vim.notify("Project archiving not yet implemented", vim.log.levels.INFO)
  return false
end

-- =============================================================================
-- Event Handlers
-- =============================================================================

-- Listen for task completion to update project progress
EventBus.on("task:completed", function(data)
  if data.bufnr then
    -- Check if this is in projects file
    local filepath = vim.api.nvim_buf_get_name(data.bufnr)
    local projects_file = fs.get_projects_file()
    
    if filepath == projects_file then
      -- Schedule progress update
      vim.schedule(function()
        M.update_all_project_progress(data.bufnr)
      end)
    end
  end
end, {
  priority = 50,
  name = "project_service.task_completed"
})

EventBus.on("task:uncompleted", function(data)
  if data.bufnr then
    local filepath = vim.api.nvim_buf_get_name(data.bufnr)
    local projects_file = fs.get_projects_file()
    
    if filepath == projects_file then
      vim.schedule(function()
        M.update_all_project_progress(data.bufnr)
      end)
    end
  end
end, {
  priority = 50,
  name = "project_service.task_uncompleted"
})

return M