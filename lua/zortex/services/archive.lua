-- services/archive_service.lua
-- Archive service for completed projects and tasks
local M = {}

local DocumentManager = require("zortex.core.document_manager")
local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local ProjectService = require("zortex.services.project_service")
local fs = require("zortex.core.filesystem")
local datetime = require("zortex.core.datetime")
local constants = require("zortex.constants")

-- Configuration
local config = {
  archive_dir = "archive",
  archive_by_year = true,
  preserve_structure = true,
  add_archive_metadata = true,
  auto_archive_after_days = 30,
}

-- =============================================================================
-- Archive File Management
-- =============================================================================

-- Get archive file path for a date
local function get_archive_file_path(date, project_type)
  date = date or datetime.get_current_date()
  project_type = project_type or "projects"
  
  local notes_dir = fs.get_notes_dir()
  if not notes_dir then
    return nil
  end
  
  local archive_path = notes_dir .. "/" .. config.archive_dir
  
  if config.archive_by_year then
    archive_path = archive_path .. "/" .. date.year
  end
  
  -- Ensure directory exists
  vim.fn.mkdir(archive_path, "p")
  
  -- Build filename
  local filename = string.format("%s-archive-%04d-%02d.zortex",
    project_type, date.year, date.month)
  
  return archive_path .. "/" .. filename
end

-- Load or create archive document
local function get_or_create_archive_doc(date, project_type)
  local archive_path = get_archive_file_path(date, project_type)
  if not archive_path then
    return nil, "Failed to determine archive path"
  end
  
  -- Check if file exists
  if not fs.file_exists(archive_path) then
    -- Create new archive file
    local lines = {
      "@@ Archive: " .. project_type:gsub("^%l", string.upper),
      "@date(" .. os.date("%Y-%m-%d") .. ")",
      "",
      "# Archived " .. os.date("%B %Y"),
      "",
    }
    
    if not fs.write_lines(archive_path, lines) then
      return nil, "Failed to create archive file"
    end
  end
  
  -- Load document
  local doc = DocumentManager.get_file(archive_path)
  if not doc then
    return nil, "Failed to load archive document"
  end
  
  return doc, archive_path
end

-- =============================================================================
-- Project Archiving
-- =============================================================================

-- Archive a single project
function M.archive_project(project, opts)
  opts = opts or {}
  local stop_timer = Logger.start_timer("archive_service.archive_project")
  
  if not project or not project.section then
    stop_timer()
    return false, "Invalid project"
  end
  
  -- Get archive document
  local archive_doc, archive_path = get_or_create_archive_doc(
    datetime.get_current_date(),
    "projects"
  )
  
  if not archive_doc then
    stop_timer()
    return false, archive_path -- Contains error message
  end
  
  -- Extract project content
  local project_lines = {}
  
  -- Get the raw lines from the original document
  local source_doc = DocumentManager.get_file(fs.get_projects_file())
  if not source_doc then
    stop_timer()
    return false, "Failed to load source document"
  end
  
  -- Get lines from project section
  local lines = vim.api.nvim_buf_get_lines(
    source_doc.bufnr or 0,
    project.section.start_line - 1,
    project.section.end_line,
    false
  )
  
  if #lines == 0 and source_doc.filepath then
    -- Try reading from file
    local all_lines = fs.read_lines(source_doc.filepath)
    if all_lines then
      for i = project.section.start_line, project.section.end_line do
        if all_lines[i] then
          table.insert(project_lines, all_lines[i])
        end
      end
    end
  else
    project_lines = lines
  end
  
  -- Add archive metadata if configured
  if config.add_archive_metadata then
    table.insert(project_lines, 1, "")
    table.insert(project_lines, 1, 
      string.format("@archived(%s) @from(projects)",
        os.date("%Y-%m-%d")))
  end
  
  -- Append to archive file
  local archive_lines = fs.read_lines(archive_path) or {}
  
  -- Add separator if archive has content
  if #archive_lines > 0 and archive_lines[#archive_lines] ~= "" then
    table.insert(archive_lines, "")
    table.insert(archive_lines, "---")
    table.insert(archive_lines, "")
  end
  
  -- Add project lines
  for _, line in ipairs(project_lines) do
    table.insert(archive_lines, line)
  end
  
  -- Write archive file
  if not fs.write_lines(archive_path, archive_lines) then
    stop_timer()
    return false, "Failed to write archive file"
  end
  
  -- Remove from original file if requested
  if opts.remove_original then
    -- This would need buffer manipulation
    Logger.info("archive_service", "Original removal not yet implemented")
  end
  
  stop_timer()
  
  -- Emit event
  EventBus.emit("project:archived", {
    project = project,
    archive_path = archive_path,
    timestamp = os.time(),
  })
  
  return true
end

-- Archive all completed projects
function M.archive_completed_projects(opts)
  opts = opts or {}
  local stop_timer = Logger.start_timer("archive_service.archive_completed")
  
  -- Get all projects
  local projects = ProjectService.get_all_projects()
  local archived_count = 0
  local errors = {}
  
  local function should_archive(project)
    -- Check if completed
    if project.attributes.status ~= "completed" then
      return false
    end
    
    -- Check age if configured
    if config.auto_archive_after_days > 0 then
      local done_date = project.attributes.done_date
      if done_date then
        local done_time = os.time(datetime.parse_date(done_date))
        local days_old = (os.time() - done_time) / 86400
        
        if days_old < config.auto_archive_after_days then
          return false
        end
      end
    end
    
    return true
  end
  
  -- Process each project
  local function process_project(project)
    if should_archive(project) then
      local success, err = M.archive_project(project, opts)
      
      if success then
        archived_count = archived_count + 1
      else
        table.insert(errors, {
          project = project.name,
          error = err,
        })
      end
    end
    
    -- Process subprojects
    if project.subprojects then
      for _, subproject in ipairs(project.subprojects) do
        process_project(subproject)
      end
    end
  end
  
  for _, project in ipairs(projects) do
    process_project(project)
  end
  
  stop_timer({
    archived_count = archived_count,
    error_count = #errors,
  })
  
  -- Report results
  if archived_count > 0 then
    vim.notify(
      string.format("Archived %d completed project%s",
        archived_count,
        archived_count == 1 and "" or "s"
      ),
      vim.log.levels.INFO
    )
  end
  
  if #errors > 0 then
    local error_msg = "Archive errors:\n"
    for _, err in ipairs(errors) do
      error_msg = error_msg .. string.format("  %s: %s\n", err.project, err.error)
    end
    vim.notify(error_msg, vim.log.levels.ERROR)
  end
  
  return {
    archived = archived_count,
    errors = errors,
  }
end

-- =============================================================================
-- Task Archiving
-- =============================================================================

-- Archive old completed tasks
function M.archive_old_tasks(days_old, opts)
  days_old = days_old or 90
  opts = opts or {}
  
  local stop_timer = Logger.start_timer("archive_service.archive_old_tasks")
  
  -- Get task store
  local task_store = require("zortex.stores.tasks")
  local archived_count = task_store.archive_old_tasks(days_old)
  
  stop_timer({ archived_count = archived_count })
  
  if archived_count > 0 then
    vim.notify(
      string.format("Archived %d old task%s",
        archived_count,
        archived_count == 1 and "" or "s"
      ),
      vim.log.levels.INFO
    )
    
    EventBus.emit("tasks:archived", {
      count = archived_count,
      days_old = days_old,
      timestamp = os.time(),
    })
  end
  
  return archived_count
end

-- =============================================================================
-- Archive Browsing
-- =============================================================================

-- List all archive files
function M.list_archives()
  local notes_dir = fs.get_notes_dir()
  if not notes_dir then
    return {}
  end
  
  local archive_base = notes_dir .. "/" .. config.archive_dir
  local archives = {}
  
  -- Scan archive directory
  local function scan_dir(dir, prefix)
    local handle = vim.loop.fs_scandir(dir)
    if handle then
      while true do
        local name, type = vim.loop.fs_scandir_next(handle)
        if not name then break end
        
        local path = dir .. "/" .. name
        
        if type == "directory" and config.archive_by_year then
          -- Scan year directory
          scan_dir(path, name .. "/")
        elseif type == "file" and name:match("%.zortex$") then
          local stat = vim.loop.fs_stat(path)
          table.insert(archives, {
            filename = name,
            path = path,
            relative_path = prefix .. name,
            size = stat and stat.size or 0,
            mtime = stat and stat.mtime.sec or 0,
          })
        end
      end
    end
  end
  
  scan_dir(archive_base, "")
  
  -- Sort by modification time (newest first)
  table.sort(archives, function(a, b)
    return a.mtime > b.mtime
  end)
  
  return archives
end

-- Search in archives
function M.search_archives(query, opts)
  opts = opts or {}
  
  local archives = M.list_archives()
  local results = {}
  
  for _, archive in ipairs(archives) do
    -- Load archive document
    local doc = DocumentManager.get_file(archive.path)
    
    if doc then
      -- Use search service to search document
      local SearchService = require("zortex.services.search_service")
      local doc_results = SearchService.search_document(doc, { query }, "section")
      
      for _, result in ipairs(doc_results) do
        table.insert(results, {
          archive = archive,
          result = result,
          score = result.score,
        })
      end
    end
  end
  
  -- Sort by score
  table.sort(results, function(a, b)
    return a.score > b.score
  end)
  
  return results
end

-- =============================================================================
-- Archive Restoration
-- =============================================================================

-- Restore a project from archive
function M.restore_project(archive_path, project_section, opts)
  opts = opts or {}
  
  -- This would extract the project from archive and add it back to projects.zortex
  vim.notify("Project restoration not yet implemented", vim.log.levels.INFO)
  
  return false, "Not implemented"
end

-- =============================================================================
-- Configuration
-- =============================================================================

-- Update configuration
function M.configure(opts)
  config = vim.tbl_extend("force", config, opts or {})
end

-- Get configuration
function M.get_config()
  return vim.deepcopy(config)
end

return M