-- services/task_service.lua
-- Stateless service for task operations
local M = {}

local EventBus = require("zortex.core.event_bus")
local DocumentManager = require("zortex.core.document_manager")
local Logger = require("zortex.core.logger")
local Task = require("zortex.models.task")
local parser = require("zortex.core.parser")
local buffer_sync = require("zortex.core.buffer_sync")
local attributes = require("zortex.core.attributes")

-- =============================================================================
-- Task Operations (Pure Business Logic)
-- =============================================================================

-- Complete a task
function M.complete_task(task_id, context)
  local stop_timer = Logger.start_timer("task_service.complete_task")
  
  -- Get task from document
  local doc = DocumentManager.get_buffer(context.bufnr)
  if not doc then
    stop_timer()
    error("No document found for buffer: " .. context.bufnr)
  end
  
  local task, section = doc:get_task(task_id)
  if not task then
    stop_timer()
    error("Task not found: " .. task_id)
  end
  
  if task.completed then
    stop_timer()
    return nil, "Task already completed"
  end
  
  -- Build XP context for event
  local xp_context = {
    task_id = task_id,
    task_position = task.position or M.calculate_task_position(doc, task, section),
    total_tasks = M.count_project_tasks(doc, section),
    project_name = M.get_project_name(section),
    area_links = M.extract_area_links(doc, section)
  }
  
  -- Emit pre-completion event
  EventBus.emit("task:completing", {
    task = task,
    section = section,
    xp_context = xp_context,
    bufnr = context.bufnr
  })
  
  -- Update task state
  task.completed = true
  task.completed_at = os.time()
  
  -- Update document (will trigger buffer sync)
  doc:update_task(task_id, {
    completed = true,
    completed_at = task.completed_at
  })
  
  -- Queue buffer update
  buffer_sync.toggle_task(context.bufnr, task.line, true)
  
  -- Emit completion event
  EventBus.emit("task:completed", {
    task = task,
    section = section,
    xp_context = xp_context,
    bufnr = context.bufnr
  })
  
  stop_timer()
  return task
end

-- Uncomplete a task
function M.uncomplete_task(task_id, context)
  local stop_timer = Logger.start_timer("task_service.uncomplete_task")
  
  -- Get task from document
  local doc = DocumentManager.get_buffer(context.bufnr)
  if not doc then
    stop_timer()
    error("No document found for buffer: " .. context.bufnr)
  end
  
  local task, section = doc:get_task(task_id)
  if not task then
    stop_timer()
    error("Task not found: " .. task_id)
  end
  
  if not task.completed then
    stop_timer()
    return nil, "Task already incomplete"
  end
  
  -- Store XP info for reversal
  local xp_context = {
    task_id = task_id,
    xp_awarded = task.attributes.xp or 0,
    project_name = M.get_project_name(section),
    area_links = M.extract_area_links(doc, section)
  }
  
  -- Emit uncompleting event
  EventBus.emit("task:uncompleting", {
    task = task,
    section = section,
    xp_context = xp_context,
    bufnr = context.bufnr
  })
  
  -- Update task state
  task.completed = false
  task.completed_at = nil
  
  -- Update document
  doc:update_task(task_id, {
    completed = false,
    completed_at = nil
  })
  
  -- Queue buffer update
  buffer_sync.toggle_task(context.bufnr, task.line, false)
  
  -- Emit uncompleted event
  EventBus.emit("task:uncompleted", {
    task = task,
    section = section,
    xp_context = xp_context,
    bufnr = context.bufnr
  })
  
  stop_timer()
  return task
end

-- Toggle task at line
function M.toggle_task_at_line(context)
  local stop_timer = Logger.start_timer("task_service.toggle_task_at_line")
  
  local doc = DocumentManager.get_buffer(context.bufnr)
  if not doc then
    stop_timer()
    error("No document found for buffer: " .. context.bufnr)
  end
  
  local section = doc:get_section_at_line(context.lnum)
  if not section then
    stop_timer()
    return nil, "No section found at line"
  end
  
  -- Find task at this line
  local task = nil
  for _, t in ipairs(section.tasks) do
    if t.line == context.lnum then
      task = t
      break
    end
  end
  
  -- If not a task, try to convert line to task
  if not task then
    stop_timer()
    return M.convert_line_to_task(context)
  end
  
  -- Ensure task has ID
  if not task.attributes.id then
    task.attributes.id = Task.generate_id()
    doc:update_task_at_line(context.lnum, {
      attributes = { id = task.attributes.id }
    })
  end
  
  stop_timer()
  
  -- Toggle based on current state
  if task.completed then
    return M.uncomplete_task(task.attributes.id, context)
  else
    return M.complete_task(task.attributes.id, context)
  end
end

-- Convert a line to a task
function M.convert_line_to_task(context)
  local stop_timer = Logger.start_timer("task_service.convert_line_to_task")
  
  local doc = DocumentManager.get_buffer(context.bufnr)
  local lines = vim.api.nvim_buf_get_lines(context.bufnr, context.lnum - 1, context.lnum, false)
  local line = lines[1]
  
  if not line or line:match("^%s*$") then
    stop_timer()
    return nil, "Cannot convert empty line to task"
  end
  
  -- Preserve indentation
  local indent, content = line:match("^(%s*)(.-)%s*$")
  
  -- Generate task ID
  local task_id = Task.generate_id()
  
  -- Build task line
  local task_line = string.format("%s- [ ] %s @id(%s)", indent, content, task_id)
  
  -- Update buffer
  buffer_sync.update_text(context.bufnr, context.lnum, context.lnum, { task_line })
  
  -- Get section and project info
  local section = doc:get_section_at_line(context.lnum)
  local project_name = M.get_project_name(section)
  
  -- Create task object
  local task = {
    attributes = { id = task_id },
    line = context.lnum,
    text = content,
    completed = false,
    project = project_name
  }
  
  -- Save to store
  Task.load(task_id) or Task:new({
    id = task_id,
    text = content,
    project = project_name,
    completed = false
  }):save()
  
  -- Emit event
  EventBus.emit("task:created", {
    task = task,
    section = section,
    bufnr = context.bufnr
  })
  
  -- Mark document dirty for reparse
  DocumentManager.mark_buffer_dirty(context.bufnr, context.lnum, context.lnum)
  
  stop_timer()
  return task
end

-- Update task attributes
function M.update_task_attributes(task_id, attributes, context)
  local doc = DocumentManager.get_buffer(context.bufnr)
  if not doc then
    error("No document found for buffer: " .. context.bufnr)
  end
  
  local task, section = doc:get_task(task_id)
  if not task then
    error("Task not found: " .. task_id)
  end
  
  -- Update document
  doc:update_task(task_id, { attributes = attributes })
  
  -- Queue buffer update
  buffer_sync.update_task(context.bufnr, task.line, attributes)
  
  -- Emit event
  EventBus.emit("task:updated", {
    task = task,
    section = section,
    updates = { attributes = attributes },
    bufnr = context.bufnr
  })
  
  return task
end

-- =============================================================================
-- Helper Functions
-- =============================================================================

-- Calculate task position within project
function M.calculate_task_position(doc, task, section)
  local project_section = M.find_project_section(section)
  if not project_section then
    return 1
  end
  
  local all_tasks = project_section:get_all_tasks()
  for i, t in ipairs(all_tasks) do
    if t.attributes and t.attributes.id == task.attributes.id then
      return i
    end
  end
  
  return 1
end

-- Count total tasks in project
function M.count_project_tasks(doc, section)
  local project_section = M.find_project_section(section)
  if not project_section then
    return 1
  end
  
  return #project_section:get_all_tasks()
end

-- Find the project section (heading) containing this task
function M.find_project_section(section)
  -- Walk up the tree to find the nearest heading
  local current = section
  while current do
    if current.type == "heading" then
      return current
    end
    current = current.parent
  end
  return nil
end

-- Get project name from section
function M.get_project_name(section)
  local project_section = M.find_project_section(section)
  return project_section and project_section.text or "Inbox"
end

-- Extract area links from section hierarchy
function M.extract_area_links(doc, section)
  local area_links = {}
  local seen = {}
  
  -- Check current section and parents for area links
  local current = section
  while current do
    -- Look for links in section text
    local links = parser.extract_all_links(current.raw_text or current.text)
    for _, link in ipairs(links) do
      if link.type == "link" then
        local parsed = parser.parse_link_definition(link.definition)
        if parsed and #parsed.components > 0 then
          -- Check if it's an area link
          local first = parsed.components[1]
          if first.type == "article" and 
             (first.text == "A" or first.text == "Areas" or 
              first.text:match("^A/") or first.text:match("^Areas/")) then
            local area_path = link.definition
            if not seen[area_path] then
              table.insert(area_links, area_path)
              seen[area_path] = true
            end
          end
        end
      end
    end
    
    current = current.parent
  end
  
  return area_links
end

-- =============================================================================
-- Batch Operations
-- =============================================================================

-- Process all tasks in a buffer
function M.process_buffer_tasks(bufnr)
  local doc = DocumentManager.get_buffer(bufnr)
  if not doc then
    return {}
  end
  
  local tasks = doc:get_all_tasks()
  local processed = {}
  
  for _, task in ipairs(tasks) do
    -- Ensure task has ID
    if not task.attributes.id then
      task.attributes.id = Task.generate_id()
      doc:update_task_at_line(task.line, {
        attributes = { id = task.attributes.id }
      })
    end
    
    -- Save to store if not exists
    local stored = Task.load(task.attributes.id)
    if not stored then
      Task:new({
        id = task.attributes.id,
        text = task.text,
        completed = task.completed,
        project = M.get_project_name(doc:get_section_at_line(task.line))
      }):save()
    end
    
    table.insert(processed, task)
  end
  
  return processed
end

return M