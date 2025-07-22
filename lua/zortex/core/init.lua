-- core/init.lua
-- Initialize core systems: EventBus, DocumentManager, and Services
local M = {}

local EventBus = require("zortex.core.event_bus")
local DocumentManager = require("zortex.core.document_manager")
local Logger = require("zortex.core.logger")
local buffer_sync = require("zortex.core.buffer_sync")

-- Services
local TaskService = require("zortex.services.task_service")
local XPService = require("zortex.services.xp_service")
local PersistenceManager = require("zortex.stores.persistence_manager")

-- State
local initialized = false

-- =============================================================================
-- System Initialization
-- =============================================================================

function M.init(config)
  if initialized then
    Logger.warn("core", "Already initialized")
    return
  end
  
  local stop_timer = Logger.start_timer("core.init")
  
  -- Initialize logger with config
  Logger.configure({
    level = config.debug and "debug" or "info",
    file = config.log_file,
  })
  
  -- Initialize XP core with config
  require("zortex.xp.core").setup(config.xp)
  
  -- Initialize DocumentManager
  DocumentManager.init()
  Logger.info("core", "DocumentManager initialized")
  
  -- Initialize buffer sync
  buffer_sync.configure({
    strategy = buffer_sync.strategies.BATCHED,
    batch_delay = 500,
    max_batch_size = 50,
  })
  buffer_sync.init()
  Logger.info("core", "Buffer sync initialized")
  
  -- Initialize services
  XPService.init()
  Logger.info("core", "XP Service initialized")
  
  -- Note: TaskService doesn't need init, it's stateless
  Logger.info("core", "Task Service ready")
  
  -- Initialize XP distributor
  require("zortex.domain.xp.distributor").init()
  Logger.info("core", "XP Distributor initialized")
  
  -- Initialize persistence manager
  PersistenceManager.configure({
    save_interval = config.persistence and config.persistence.save_interval or 5000,
    save_on_exit = true,
    save_on_events = true,
    batch_saves = true,
  })
  PersistenceManager.init()
  Logger.info("core", "Persistence Manager initialized")
  
  -- Set up global error handler for events
  EventBus.add_middleware(function(event, data)
    Logger.debug("event", event, data)
    return true, data -- Continue propagation
  end)
  
  initialized = true
  stop_timer()
  
  Logger.info("core", "All systems initialized")
  
  -- Emit initialization complete event
  EventBus.emit("core:initialized", {
    timestamp = os.time(),
    config = config,
  })
end

-- =============================================================================
-- Service Proxies (for backward compatibility)
-- =============================================================================

-- Task operations
M.toggle_task = function(bufnr, lnum)
  return TaskService.toggle_task_at_line({
    bufnr = bufnr or vim.api.nvim_get_current_buf(),
    lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  })
end

M.complete_task = function(task_id, bufnr)
  return TaskService.complete_task(task_id, {
    bufnr = bufnr or vim.api.nvim_get_current_buf()
  })
end

M.uncomplete_task = function(task_id, bufnr)
  return TaskService.uncomplete_task(task_id, {
    bufnr = bufnr or vim.api.nvim_get_current_buf()
  })
end

M.toggle_current_task = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  
  return TaskService.toggle_task_at_line({
    bufnr = bufnr,
    lnum = lnum
  })
end

-- =============================================================================
-- Status and Debugging
-- =============================================================================

-- Get system status
function M.get_status()
  return {
    initialized = initialized,
    event_bus = EventBus.get_performance_report(),
    document_manager = {
      buffer_count = vim.tbl_count(DocumentManager._instance.buffers),
      file_count = vim.tbl_count(DocumentManager._instance.files),
    },
    buffer_sync = buffer_sync.get_status(),
    persistence = PersistenceManager.get_status(),
  }
end

-- Print status report
function M.print_status()
  local status = M.get_status()
  print(vim.inspect(status))
end

-- Get service references (for direct access)
function M.get_services()
  return {
    task = TaskService,
    xp = XPService,
    document_manager = DocumentManager,
    persistence = PersistenceManager,
    event_bus = EventBus,
    buffer_sync = buffer_sync,
  }
end

return M