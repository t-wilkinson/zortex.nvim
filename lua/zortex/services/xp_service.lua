-- services/xp_service.lua
-- Service for XP orchestration and calculation
local M = {}

local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local xp_core = require("zortex.xp.core")
local xp_areas = require("zortex.xp.areas")
local xp_projects = require("zortex.xp.projects")
local xp_store = require("zortex.stores.xp")
local task_store = require("zortex.stores.tasks")

-- =============================================================================
-- XP Calculation (delegates to xp_core)
-- =============================================================================

-- Calculate XP for a task completion
function M.calculate_task_xp(xp_context)
  local stop_timer = Logger.start_timer("xp_service.calculate_task_xp")
  
  local xp = xp_core.calculate_task_xp(
    xp_context.task_position,
    xp_context.total_tasks
  )
  
  Logger.debug("xp_service", "Calculated task XP", {
    task_id = xp_context.task_id,
    position = xp_context.task_position,
    total = xp_context.total_tasks,
    xp = xp
  })
  
  stop_timer()
  return xp
end

-- Calculate XP for an objective completion
function M.calculate_objective_xp(time_horizon, created_date)
  return xp_core.calculate_objective_xp(time_horizon, created_date)
end

-- =============================================================================
-- XP Distribution
-- =============================================================================

-- Distribute XP from task completion
function M.distribute_task_xp(task_id, xp_amount, xp_context)
  local stop_timer = Logger.start_timer("xp_service.distribute_task_xp")
  
  local distributions = {
    summary = {
      task_id = task_id,
      total_xp = xp_amount,
      distributions = {}
    }
  }
  
  -- 1. Award to project
  if xp_context.project_name then
    xp_projects.complete_task(
      xp_context.project_name,
      xp_context.task_position,
      xp_context.total_tasks,
      xp_context.area_links
    )
    
    table.insert(distributions.summary.distributions, {
      type = "project",
      target = xp_context.project_name,
      amount = xp_amount
    })
  end
  
  -- 2. Award to season (handled by xp_projects)
  local season_data = xp_store.get_season_data()
  if season_data.current_season then
    table.insert(distributions.summary.distributions, {
      type = "season",
      target = season_data.current_season.name,
      amount = xp_amount
    })
  end
  
  -- 3. Transfer to areas (10% of task XP)
  if xp_context.area_links and #xp_context.area_links > 0 then
    local area_transfer = xp_core.calculate_area_transfer(xp_amount, #xp_context.area_links)
    
    for _, area_link in ipairs(xp_context.area_links) do
      table.insert(distributions.summary.distributions, {
        type = "area",
        target = area_link,
        amount = area_transfer
      })
    end
  end
  
  -- Update task record with XP awarded
  task_store.update_task(task_id, { xp_awarded = xp_amount })
  
  Logger.info("xp_service", "Distributed task XP", distributions.summary)
  
  stop_timer()
  return distributions.summary
end

-- Reverse XP distribution for task uncomplete
function M.reverse_task_xp(task_id, xp_context)
  local stop_timer = Logger.start_timer("xp_service.reverse_task_xp")
  
  local xp_to_remove = xp_context.xp_awarded or 0
  if xp_to_remove <= 0 then
    stop_timer()
    return { reversed = 0 }
  end
  
  -- Reverse XP from project, season, and areas
  xp_projects.uncomplete_task(
    xp_context.project_name,
    xp_to_remove,
    xp_context.area_links
  )
  
  -- Update task record
  task_store.update_task(task_id, { xp_awarded = 0 })
  
  Logger.info("xp_service", "Reversed task XP", {
    task_id = task_id,
    amount = xp_to_remove
  })
  
  stop_timer()
  return { reversed = xp_to_remove }
end

-- =============================================================================
-- Event Handlers
-- =============================================================================

-- Handle task completion
local function handle_task_completing(data)
  local stop_timer = Logger.start_timer("xp_service.handle_task_completing")
  
  -- Calculate XP
  local xp = M.calculate_task_xp(data.xp_context)
  
  -- Store XP amount for distribution after completion
  EventBus.emit("xp:calculated", {
    source = "task",
    task_id = data.task.attributes.id,
    amount = xp,
    xp_context = data.xp_context
  })
  
  stop_timer()
end

-- Handle task completed (distribute XP)
local function handle_task_completed(data)
  local stop_timer = Logger.start_timer("xp_service.handle_task_completed")
  
  -- Get calculated XP (would be better with a temporary store)
  local xp = M.calculate_task_xp(data.xp_context)
  
  -- Distribute XP
  local distribution = M.distribute_task_xp(
    data.task.attributes.id,
    xp,
    data.xp_context
  )
  
  -- Emit XP awarded event
  EventBus.emit("xp:awarded", {
    source = "task",
    task_id = data.task.attributes.id,
    amount = xp,
    distribution = distribution
  })
  
  stop_timer()
end

-- Handle task uncomplete
local function handle_task_uncompleted(data)
  local stop_timer = Logger.start_timer("xp_service.handle_task_uncompleted")
  
  -- Reverse XP
  local result = M.reverse_task_xp(
    data.task.attributes.id,
    data.xp_context
  )
  
  -- Emit XP reversed event
  EventBus.emit("xp:reversed", {
    source = "task",
    task_id = data.task.attributes.id,
    amount = result.reversed
  })
  
  stop_timer()
end

-- Handle objective completion
local function handle_objective_completed(data)
  local stop_timer = Logger.start_timer("xp_service.handle_objective_completed")
  
  -- Complete objective and distribute XP
  local xp = xp_areas.complete_objective(
    data.objective_id,
    data.objective_text,
    data.time_horizon,
    data.area_links,
    data.created_date
  )
  
  -- Emit XP awarded event
  EventBus.emit("xp:awarded", {
    source = "objective",
    objective_id = data.objective_id,
    amount = xp,
    area_links = data.area_links
  })
  
  stop_timer()
end

-- =============================================================================
-- Initialization
-- =============================================================================

function M.init()
  local stop_timer = Logger.start_timer("xp_service.init")
  
  -- Set up XP core with config
  local config = require("zortex.config").config
  xp_core.setup(config.xp)
  
  -- Register event handlers
  EventBus.on("task:completing", handle_task_completing, {
    priority = 80,
    name = "xp_service.task_completing"
  })
  
  EventBus.on("task:completed", handle_task_completed, {
    priority = 80,
    name = "xp_service.task_completed"
  })
  
  EventBus.on("task:uncompleted", handle_task_uncompleted, {
    priority = 80,
    name = "xp_service.task_uncompleted"
  })
  
  EventBus.on("objective:completed", handle_objective_completed, {
    priority = 80,
    name = "xp_service.objective_completed"
  })
  
  -- Listen for XP notifications
  EventBus.on("xp:awarded", function(data)
    local msg = string.format("✨ +%d XP", data.amount)
    if data.source == "task" then
      msg = msg .. " for task completion!"
    elseif data.source == "objective" then
      msg = msg .. " for objective completion!"
    end
    
    vim.notify(msg, vim.log.levels.INFO)
  end, {
    priority = 10,
    name = "xp_service.notify_award"
  })
  
  Logger.info("xp_service", "XP Service initialized")
  stop_timer()
end

-- =============================================================================
-- Status and Statistics
-- =============================================================================

-- Get XP statistics
function M.get_stats()
  local season_status = xp_projects.get_season_status()
  local area_stats = xp_areas.get_all_stats()
  local project_stats = xp_projects.get_all_project_stats()
  
  return {
    season = season_status,
    areas = area_stats,
    projects = project_stats
  }
end

-- Get XP leaderboard
function M.get_leaderboard(type, limit)
  type = type or "areas"
  limit = limit or 10
  
  if type == "areas" then
    return xp_areas.get_top_areas(limit)
  elseif type == "projects" then
    -- Get top projects by XP
    local all_projects = xp_projects.get_all_project_stats()
    local sorted = {}
    
    for name, stats in pairs(all_projects) do
      table.insert(sorted, {
        name = name,
        xp = stats.xp,
        level = stats.level,
        completed = stats.is_completed
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
  
  return {}
end

return M