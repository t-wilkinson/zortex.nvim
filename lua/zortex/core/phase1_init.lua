-- core/phase1_init.lua
-- Phase 1 initialization - sets up new infrastructure alongside existing code
local M = {}

local EventBus = require("zortex.core.event_bus")
local DocumentManager = require("zortex.core.document_manager")
local Logger = require("zortex.core.logger")

-- Phase 1 status tracking
M.initialized = false
M.components = {
  event_bus = false,
  document_manager = false,
  logger = false,
}

-- Initialize Phase 1 components
function M.init(opts)
  if M.initialized then
    return true
  end
  
  opts = opts or {}
  
  -- Configure logger first
  Logger.configure({
    enabled = opts.debug or vim.g.zortex_debug or false,
    level = opts.log_level or vim.g.zortex_log_level or "INFO",
    log_file = opts.log_file or vim.g.zortex_log_file,
    performance_threshold = opts.performance_threshold or 16,
  })
  Logger.setup_commands()
  M.components.logger = true
  Logger.info("phase1", "Initializing Phase 1 components")
  
  -- Initialize EventBus
  local init_eventbus = Logger.wrap_function("phase1.init_eventbus", function()
    -- Set up core event logging middleware
    if opts.log_events or vim.g.zortex_log_events then
      EventBus.add_middleware(function(event, data)
        Logger.debug("event", event, data)
        return true, data
      end)
    end
    
    -- Set up event handlers for existing features
    M.setup_compatibility_handlers()
    
    M.components.event_bus = true
    Logger.info("phase1", "EventBus initialized")
  end)
  init_eventbus()
  
  -- Initialize DocumentManager
  local init_docmanager = Logger.wrap_function("phase1.init_docmanager", function()
    DocumentManager.init()
    M.components.document_manager = true
    Logger.info("phase1", "DocumentManager initialized")
  end)
  init_docmanager()
  
  -- Set up performance monitoring
  M.setup_performance_monitoring()
  
  -- Set up development commands
  if opts.dev_mode or vim.g.zortex_dev_mode then
    M.setup_dev_commands()
  end
  
  M.initialized = true
  Logger.info("phase1", "Phase 1 initialization complete", M.components)
  
  -- Emit initialization event
  EventBus.emit("phase1:initialized", {
    components = M.components,
    opts = opts,
  })
  
  return true
end

-- Set up compatibility handlers to work with existing code
function M.setup_compatibility_handlers()
  -- Listen for document changes and update existing modules
  EventBus.on("document:changed", function(data)
    -- This is where we'll bridge to existing code in later phases
    Logger.debug("compat", "Document changed", {
      bufnr = data.bufnr,
      filepath = data.document.filepath,
    })
    
    -- For now, just log - in Phase 2 we'll update task/XP modules
  end, {
    priority = 100, -- High priority for compatibility
    name = "compat_document_changed",
  })
  
  -- Listen for task events (will be emitted in Phase 2)
  EventBus.on("task:completed", function(data)
    Logger.debug("compat", "Task completed", data)
    -- Phase 2 will wire this to XP system
  end, {
    priority = 90,
    name = "compat_task_completed",
  })
end

-- Set up performance monitoring
function M.setup_performance_monitoring()
  -- Monitor parse times
  EventBus.on("document:parsed", function(data)
    if data.parse_time > 50 then
      Logger.warn("performance", "Slow parse detected", {
        parse_time = data.parse_time,
        full_parse = data.full_parse,
        filepath = data.document.filepath,
      })
    end
  end, {
    priority = 10,
    name = "perf_monitor_parse",
  })
  
  -- Monitor event processing
  local slow_events = {}
  EventBus.add_middleware(function(event, data)
    local timer = Logger.start_timer("event:" .. event)
    
    -- Schedule cleanup after event processing
    vim.schedule(function()
      local elapsed = timer()
      if elapsed > 100 then
        slow_events[event] = (slow_events[event] or 0) + 1
        if slow_events[event] % 10 == 0 then
          Logger.warn("performance", "Frequent slow event", {
            event = event,
            count = slow_events[event],
          })
        end
      end
    end)
    
    return true, data
  end)
end

-- Development commands for testing Phase 1
function M.setup_dev_commands()
  -- Test document parsing
  vim.api.nvim_create_user_command("ZortexTestParse", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local doc = DocumentManager.get_buffer(bufnr)
    
    if not doc then
      vim.notify("No document loaded for current buffer", vim.log.levels.WARN)
      return
    end
    
    print("Document Stats:")
    print("  Article: " .. doc.article_name)
    print("  Sections: " .. doc.stats.sections)
    print("  Tasks: " .. doc.stats.tasks)
    print("  Completed: " .. doc.stats.completed)
    print("  Parse Time: " .. string.format("%.2fms", doc.stats.parse_time))
    
    -- Show section tree
    print("\nSection Tree:")
    local function print_section(section, indent)
      local prefix = string.rep("  ", indent)
      print(prefix .. section:format_display() .. 
            " (lines " .. section.start_line .. "-" .. section.end_line .. ")")
      for _, child in ipairs(section.children) do
        print_section(child, indent + 1)
      end
    end
    
    if doc.sections then
      for _, child in ipairs(doc.sections.children) do
        print_section(child, 0)
      end
    end
  end, {})
  
  -- Test event emission
  vim.api.nvim_create_user_command("ZortexTestEvent", function(opts)
    local event = opts.args or "test:event"
    EventBus.emit(event, {
      timestamp = os.time(),
      source = "dev_command",
      test = true,
    })
    print("Emitted event: " .. event)
  end, { nargs = "?" })
  
  -- Show current section
  vim.api.nvim_create_user_command("ZortexShowSection", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local doc = DocumentManager.get_buffer(bufnr)
    
    if not doc then
      vim.notify("No document loaded for current buffer", vim.log.levels.WARN)
      return
    end
    
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = doc:get_section_at_line(line)
    
    if section then
      print("Current Section:")
      print("  Type: " .. section.type)
      print("  Text: " .. section.text)
      print("  Level: " .. (section.level or "n/a"))
      print("  Lines: " .. section.start_line .. "-" .. section.end_line)
      print("  Path: " .. section:get_breadcrumb())
      print("  Priority: " .. section:get_priority())
      
      local stats = section:get_stats()
      print("  Stats:")
      print("    Tasks: " .. stats.total_tasks)
      print("    Completed: " .. stats.completed_tasks)
      print("    Children: " .. stats.child_count)
      print("    Depth: " .. stats.depth)
    else
      print("No section at line " .. line)
    end
  end, {})
  
  -- Force reparse
  vim.api.nvim_create_user_command("ZortexReparse", function()
    local bufnr = vim.api.nvim_get_current_buf()
    DocumentManager.mark_buffer_dirty(bufnr, 1, -1)
    print("Marked buffer for reparse")
  end, {})
  
  -- Dump document state
  vim.api.nvim_create_user_command("ZortexDumpDocument", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local doc = DocumentManager.get_buffer(bufnr)
    
    if not doc then
      vim.notify("No document loaded for current buffer", vim.log.levels.WARN)
      return
    end
    
    -- Create debug buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_name(buf, "Zortex Document Dump")
    
    local lines = vim.split(vim.inspect(doc, {
      depth = 4,
      process = function(item, path)
        -- Skip circular references
        if type(item) == "table" and item.parent then
          return "<parent>"
        end
        return item
      end
    }), "\n")
    
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(buf, 'filetype', 'lua')
    
    vim.cmd('split')
    vim.api.nvim_win_set_buf(0, buf)
  end, {})
end

-- Get Phase 1 status
function M.get_status()
  return {
    initialized = M.initialized,
    components = M.components,
    document_count = #DocumentManager.get_all_documents(),
    event_stats = EventBus.get_performance_report(),
    performance_stats = Logger.get_performance_report(),
  }
end

-- Healthcheck for Phase 1
function M.healthcheck()
  local health = {}
  
  -- Check initialization
  health.initialized = M.initialized
  
  -- Check components
  health.components = {}
  for component, initialized in pairs(M.components) do
    health.components[component] = {
      initialized = initialized,
      status = initialized and "OK" or "Not initialized",
    }
  end
  
  -- Check document manager
  local docs = DocumentManager.get_all_documents()
  health.documents = {
    count = #docs,
    buffers = vim.tbl_count(DocumentManager._instance.buffers),
    files = vim.tbl_count(DocumentManager._instance.files),
  }
  
  -- Check event bus
  local event_stats = EventBus.get_performance_report()
  health.events = {
    handlers = vim.tbl_count(EventBus._instance.handlers),
    total_events = vim.tbl_count(event_stats),
  }
  
  -- Performance summary
  local perf_stats = Logger.get_performance_report()
  health.performance = {
    operations = vim.tbl_count(perf_stats),
    slow_operations = vim.tbl_filter(function(op)
      return op.avg_time > 16
    end, perf_stats),
  }
  
  return health
end

return M