-- modules/progress.lua - Progress tracking using new service architecture
local M = {}

local TaskService = require("zortex.services.task_service")
local ProjectService = require("zortex.services.project_service")
local XPService = require("zortex.services.xp_service")
local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local fs = require("zortex.core.filesystem")
local parser = require("zortex.core.parser")
local objectives = require("zortex.modules.objectives")

-- =============================================================================
-- Task Progress (Using TaskService)
-- =============================================================================

-- Toggle task on current line
function M.toggle_current_task()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  
  local result, err = TaskService.toggle_task_at_line({
    bufnr = bufnr,
    lnum = lnum
  })
  
  if not result then
    if err then
      vim.notify(err, vim.log.levels.WARN)
    end
  end
  
  return result
end

-- Complete task on current line
function M.complete_current_task()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  
  -- First try to find existing task
  local doc = require("zortex.core.document_manager").get_buffer(bufnr)
  if not doc then
    vim.notify("No document found for current buffer", vim.log.levels.ERROR)
    return
  end
  
  local section = doc:get_section_at_line(lnum)
  if not section then
    -- Try to convert line to task
    return TaskService.convert_line_to_task({ bufnr = bufnr, lnum = lnum })
  end
  
  -- Find task at this line
  local task = nil
  for _, t in ipairs(section.tasks) do
    if t.line == lnum then
      task = t
      break
    end
  end
  
  if not task then
    -- Try to convert line to task
    return TaskService.convert_line_to_task({ bufnr = bufnr, lnum = lnum })
  end
  
  -- If already completed, do nothing
  if task.completed then
    vim.notify("Task already completed", vim.log.levels.INFO)
    return task
  end
  
  -- Complete the task
  if task.attributes and task.attributes.id then
    return TaskService.complete_task(task.attributes.id, { bufnr = bufnr })
  else
    vim.notify("Task has no ID", vim.log.levels.ERROR)
    return nil
  end
end

-- Uncomplete task on current line
function M.uncomplete_current_task()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  
  local doc = require("zortex.core.document_manager").get_buffer(bufnr)
  if not doc then
    vim.notify("No document found for current buffer", vim.log.levels.ERROR)
    return
  end
  
  local section = doc:get_section_at_line(lnum)
  if not section then
    vim.notify("No section found at current line", vim.log.levels.ERROR)
    return
  end
  
  -- Find task at this line
  local task = nil
  for _, t in ipairs(section.tasks) do
    if t.line == lnum then
      task = t
      break
    end
  end
  
  if not task or not task.completed then
    vim.notify("No completed task at current line", vim.log.levels.WARN)
    return nil
  end
  
  -- Uncomplete the task
  if task.attributes and task.attributes.id then
    return TaskService.uncomplete_task(task.attributes.id, { bufnr = bufnr })
  else
    vim.notify("Task has no ID", vim.log.levels.ERROR)
    return nil
  end
end

-- =============================================================================
-- Project Progress (Using ProjectService)
-- =============================================================================

-- Update project progress indicators
function M.update_project_progress(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  
  -- Check if this is the projects file
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local projects_file = fs.get_projects_file()
  
  if filepath ~= projects_file then
    return 0
  end
  
  -- Use ProjectService to update all progress
  local updated = ProjectService.update_all_project_progress(bufnr)
  
  if updated > 0 then
    Logger.info("progress", "Updated project progress", {
      count = updated,
      bufnr = bufnr
    })
  end
  
  return updated
end

-- Update progress for all projects and OKRs
function M.update_all_progress()
  local stop_timer = Logger.start_timer("progress.update_all")
  
  -- Update projects
  local projects_file = fs.get_projects_file()
  if projects_file then
    local bufnr = vim.fn.bufnr(projects_file)
    if bufnr > 0 then
      M.update_project_progress(bufnr)
    else
      -- Load file and update
      vim.cmd("edit " .. projects_file)
      vim.schedule(function()
        M.update_project_progress()
        vim.cmd("write")
      end)
    end
  end
  
  -- Update OKRs
  objectives.update_okr_progress()
  
  stop_timer()
  
  vim.notify("Updated all progress indicators", vim.log.levels.INFO)
end

-- =============================================================================
-- Statistics (Using Services)
-- =============================================================================

-- Get task statistics
function M.get_task_stats()
  local task_store = require("zortex.stores.tasks")
  return task_store.get_stats()
end

-- Get project statistics
function M.get_project_stats()
  return ProjectService.get_all_stats()
end

-- Get overall progress statistics
function M.get_overall_stats()
  local task_stats = M.get_task_stats()
  local project_stats = M.get_project_stats()
  local xp_stats = XPService.get_stats()
  
  return {
    tasks = task_stats,
    projects = project_stats,
    xp = xp_stats,
  }
end

-- =============================================================================
-- Progress Visualization
-- =============================================================================

-- Show progress dashboard
function M.show_dashboard()
  local stats = M.get_overall_stats()
  local lines = {}
  
  -- Header
  table.insert(lines, "╔═══════════════════════════════════════╗")
  table.insert(lines, "║        ZORTEX PROGRESS DASHBOARD      ║")
  table.insert(lines, "╚═══════════════════════════════════════╝")
  table.insert(lines, "")
  
  -- Task Stats
  table.insert(lines, "━━━ TASKS ━━━")
  table.insert(lines, string.format("Total: %d", stats.tasks.total_tasks))
  table.insert(lines, string.format("Completed: %d (%.1f%%)", 
    stats.tasks.completed_tasks,
    stats.tasks.total_tasks > 0 and 
      (stats.tasks.completed_tasks / stats.tasks.total_tasks * 100) or 0
  ))
  table.insert(lines, string.format("Total XP Awarded: %d", stats.tasks.total_xp_awarded))
  table.insert(lines, "")
  
  -- Project Stats
  table.insert(lines, "━━━ PROJECTS ━━━")
  table.insert(lines, string.format("Total: %d", stats.projects.project_count))
  table.insert(lines, string.format("Active: %d", stats.projects.active_projects))
  table.insert(lines, string.format("Completed: %d", stats.projects.completed_projects))
  table.insert(lines, string.format("Archived: %d", stats.projects.archived_projects))
  
  -- Priority breakdown
  if vim.tbl_count(stats.projects.projects_by_priority) > 0 then
    table.insert(lines, "")
    table.insert(lines, "By Priority:")
    for priority, count in pairs(stats.projects.projects_by_priority) do
      table.insert(lines, string.format("  %s: %d", priority, count))
    end
  end
  
  table.insert(lines, "")
  
  -- XP Stats
  if stats.xp and stats.xp.season then
    table.insert(lines, "━━━ SEASON XP ━━━")
    table.insert(lines, string.format("Season: %s", stats.xp.season.season.name))
    table.insert(lines, string.format("Level: %d", stats.xp.season.level))
    table.insert(lines, string.format("XP: %s", 
      require("zortex.xp.core").format_xp(stats.xp.season.xp)
    ))
    
    if stats.xp.season.current_tier then
      table.insert(lines, string.format("Tier: %s", stats.xp.season.current_tier.name))
    end
    
    table.insert(lines, "")
  end
  
  -- Top Areas
  if stats.xp and stats.xp.areas then
    table.insert(lines, "━━━ TOP AREAS ━━━")
    local area_list = {}
    for path, data in pairs(stats.xp.areas) do
      table.insert(area_list, {
        path = path,
        xp = data.xp,
        level = data.level
      })
    end
    
    table.sort(area_list, function(a, b) return a.xp > b.xp end)
    
    for i = 1, math.min(5, #area_list) do
      local area = area_list[i]
      table.insert(lines, string.format("%d. %s - Lvl %d (%s XP)",
        i,
        area.path,
        area.level,
        require("zortex.xp.core").format_xp(area.xp)
      ))
    end
  end
  
  -- Show in buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "filetype", "zortex-dashboard")
  vim.api.nvim_buf_set_name(buf, "Zortex Progress Dashboard")
  
  -- Create window
  local width = 60
  local height = #lines + 2
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    border = "rounded",
    style = "minimal",
  })
  
  -- Keymaps
  vim.keymap.set("n", "q", ":close<CR>", { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", ":close<CR>", { buffer = buf, silent = true })
  vim.keymap.set("n", "r", function()
    vim.api.nvim_win_close(win, true)
    M.show_dashboard()
  end, { buffer = buf, silent = true, desc = "Refresh dashboard" })
end

-- =============================================================================
-- Event Listeners
-- =============================================================================

-- Listen for project changes
EventBus.on("project:progress_updated", function(data)
  Logger.debug("progress", "Project progress updated", data)
end, {
  priority = 30,
  name = "progress.project_updated"
})

-- Listen for task completions
EventBus.on("task:completed", function(data)
  -- Show quick stats notification
  if data.xp_context and data.xp_context.task_position and data.xp_context.total_tasks then
    vim.notify(string.format(
      "Task %d/%d completed in %s",
      data.xp_context.task_position,
      data.xp_context.total_tasks,
      data.xp_context.project_name or "project"
    ), vim.log.levels.INFO)
  end
end, {
  priority = 30,
  name = "progress.task_completed"
})

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup(config)
  -- Configuration if needed
  Logger.info("progress", "Progress module initialized with service architecture")
end

return M