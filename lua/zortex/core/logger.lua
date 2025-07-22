-- core/logger.lua
-- Performance logging and debugging utilities
local M = {}

-- Logger configuration
local config = {
  enabled = vim.g.zortex_debug or false,
  level = vim.g.zortex_log_level or "INFO",
  max_entries = 1000,
  log_file = vim.g.zortex_log_file,
  performance_threshold = 16, -- Log operations taking > 16ms
}

-- Log levels
local levels = {
  TRACE = 1,
  DEBUG = 2,
  INFO = 3,
  WARN = 4,
  ERROR = 5,
}

-- Current log level
local current_level = levels[config.level] or levels.INFO

-- In-memory log buffer
local log_buffer = {}

-- Performance tracking
local performance_stats = {}
local active_timers = {}

-- ANSI color codes for terminal output
local colors = {
  TRACE = "\27[90m",   -- Gray
  DEBUG = "\27[36m",   -- Cyan
  INFO = "\27[32m",    -- Green
  WARN = "\27[33m",    -- Yellow
  ERROR = "\27[31m",   -- Red
  RESET = "\27[0m",
  BOLD = "\27[1m",
}

-- Format log entry
local function format_entry(level, category, message, data)
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local level_str = level
  
  -- Format message with data
  local formatted_message = message
  if data then
    if type(data) == "table" then
      formatted_message = formatted_message .. " " .. vim.inspect(data, { 
        indent = "  ",
        depth = 3 
      })
    else
      formatted_message = formatted_message .. " " .. tostring(data)
    end
  end
  
  return string.format("[%s] %s [%s] %s", 
    timestamp, level_str, category, formatted_message)
end

-- Write to log file
local function write_to_file(entry)
  if not config.log_file then return end
  
  local file = io.open(config.log_file, "a")
  if file then
    file:write(entry .. "\n")
    file:close()
  end
end

-- Core logging function
local function log(level, category, message, data)
  if not config.enabled then return end
  if levels[level] < current_level then return end
  
  local entry = format_entry(level, category, message, data)
  
  -- Add to buffer
  table.insert(log_buffer, {
    timestamp = os.time(),
    level = level,
    category = category,
    message = message,
    data = data,
    formatted = entry,
  })
  
  -- Trim buffer if needed
  if #log_buffer > config.max_entries then
    table.remove(log_buffer, 1)
  end
  
  -- Write to file
  write_to_file(entry)
  
  -- Console output for warnings and errors
  if levels[level] >= levels.WARN then
    local color = colors[level] or ""
    local formatted = color .. colors.BOLD .. "[Zortex] " .. 
                     entry .. colors.RESET
    print(formatted)
  end
end

-- Public logging functions
function M.trace(category, message, data)
  log("TRACE", category, message, data)
end

function M.debug(category, message, data)
  log("DEBUG", category, message, data)
end

function M.info(category, message, data)
  log("INFO", category, message, data)
end

function M.warn(category, message, data)
  log("WARN", category, message, data)
end

function M.error(category, message, data)
  log("ERROR", category, message, data)
end

function M.log(category, data)
  -- Convenience function that auto-detects level
  local level = data.level or "INFO"
  local message = data.message or vim.inspect(data)
  log(level, category, message, data)
end

-- Performance tracking
function M.start_timer(operation_name)
  if not config.enabled then
    return function() end -- No-op
  end
  
  local timer_id = string.format("%s_%d", operation_name, os.time())
  active_timers[timer_id] = {
    name = operation_name,
    start = vim.loop.hrtime(),
  }
  
  -- Return stop function
  return function(extra_data)
    local timer = active_timers[timer_id]
    if not timer then return end
    
    local elapsed = (vim.loop.hrtime() - timer.start) / 1e6 -- Convert to ms
    active_timers[timer_id] = nil
    
    -- Track statistics
    if not performance_stats[operation_name] then
      performance_stats[operation_name] = {
        count = 0,
        total_time = 0,
        max_time = 0,
        min_time = math.huge,
        recent = {},
      }
    end
    
    local stats = performance_stats[operation_name]
    stats.count = stats.count + 1
    stats.total_time = stats.total_time + elapsed
    stats.max_time = math.max(stats.max_time, elapsed)
    stats.min_time = math.min(stats.min_time, elapsed)
    
    -- Keep recent samples
    table.insert(stats.recent, elapsed)
    if #stats.recent > 100 then
      table.remove(stats.recent, 1)
    end
    
    -- Log if over threshold
    if elapsed > config.performance_threshold then
      M.warn("performance", string.format(
        "%s took %.2fms (threshold: %dms)",
        operation_name, elapsed, config.performance_threshold
      ), extra_data)
    else
      M.debug("performance", string.format(
        "%s completed in %.2fms",
        operation_name, elapsed
      ), extra_data)
    end
    
    return elapsed
  end
end

-- Wrap a function with performance tracking
function M.wrap_function(name, fn)
  return function(...)
    local stop = M.start_timer(name)
    local results = { pcall(fn, ...) }
    local elapsed = stop()
    
    if not results[1] then
      M.error(name, "Function error", { 
        error = results[2],
        elapsed = elapsed 
      })
      error(results[2])
    end
    
    -- Return all results except the success flag
    return unpack(results, 2)
  end
end

-- Get performance report
function M.get_performance_report()
  local report = {}
  
  for operation, stats in pairs(performance_stats) do
    local avg_time = stats.total_time / stats.count
    
    -- Calculate percentiles from recent samples
    local sorted_recent = vim.tbl_extend("force", {}, stats.recent)
    table.sort(sorted_recent)
    
    local p50 = sorted_recent[math.floor(#sorted_recent * 0.5)] or 0
    local p95 = sorted_recent[math.floor(#sorted_recent * 0.95)] or 0
    local p99 = sorted_recent[math.floor(#sorted_recent * 0.99)] or 0
    
    report[operation] = {
      count = stats.count,
      avg_time = avg_time,
      max_time = stats.max_time,
      min_time = stats.min_time,
      total_time = stats.total_time,
      p50 = p50,
      p95 = p95,
      p99 = p99,
    }
  end
  
  return report
end

-- Show performance report in a buffer
function M.show_performance_report()
  local report = M.get_performance_report()
  
  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_name(buf, "Zortex Performance Report")
  
  -- Format report
  local lines = {
    "Zortex Performance Report",
    "========================",
    "",
    string.format("%-30s %8s %8s %8s %8s %8s %8s %8s",
      "Operation", "Count", "Avg(ms)", "Min(ms)", "Max(ms)", 
      "P50(ms)", "P95(ms)", "P99(ms)"),
    string.rep("-", 110),
  }
  
  -- Sort by total time
  local sorted_ops = {}
  for op, _ in pairs(report) do
    table.insert(sorted_ops, op)
  end
  table.sort(sorted_ops, function(a, b)
    return report[a].total_time > report[b].total_time
  end)
  
  for _, op in ipairs(sorted_ops) do
    local stats = report[op]
    table.insert(lines, string.format(
      "%-30s %8d %8.2f %8.2f %8.2f %8.2f %8.2f %8.2f",
      op, stats.count, stats.avg_time, stats.min_time, stats.max_time,
      stats.p50, stats.p95, stats.p99
    ))
  end
  
  -- Also show EventBus stats
  local event_report = require("zortex.core.event_bus").get_performance_report()
  if next(event_report) then
    table.insert(lines, "")
    table.insert(lines, "Event Performance")
    table.insert(lines, "-----------------")
    table.insert(lines, string.format("%-30s %8s %8s %8s %8s",
      "Event", "Count", "Avg(ms)", "Min(ms)", "Max(ms)"))
    table.insert(lines, string.rep("-", 70))
    
    for event, stats in pairs(event_report) do
      table.insert(lines, string.format(
        "%-30s %8d %8.2f %8.2f %8.2f",
        event, stats.count, stats.avg_time, stats.min_time, stats.max_time
      ))
    end
  end
  
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  
  -- Open in split
  vim.cmd('split')
  vim.api.nvim_win_set_buf(0, buf)
end

-- Get recent log entries
function M.get_recent_logs(count, level_filter)
  count = count or 50
  local filtered = {}
  
  for i = #log_buffer, 1, -1 do
    local entry = log_buffer[i]
    if not level_filter or entry.level == level_filter then
      table.insert(filtered, 1, entry)
      if #filtered >= count then
        break
      end
    end
  end
  
  return filtered
end

-- Show logs in buffer
function M.show_logs(count, level_filter)
  local logs = M.get_recent_logs(count, level_filter)
  
  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_name(buf, "Zortex Logs")
  
  -- Format logs
  local lines = {}
  for _, entry in ipairs(logs) do
    table.insert(lines, entry.formatted)
  end
  
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  
  -- Open in split
  vim.cmd('split')
  vim.api.nvim_win_set_buf(0, buf)
  
  -- Go to end
  vim.cmd('normal! G')
end

-- Clear logs
function M.clear_logs()
  log_buffer = {}
  performance_stats = {}
  M.info("logger", "Logs cleared")
end

-- Enable/disable logging
function M.enable()
  config.enabled = true
  M.info("logger", "Logging enabled")
end

function M.disable()
  M.info("logger", "Logging disabled")
  config.enabled = false
end

function M.set_level(level)
  if levels[level] then
    config.level = level
    current_level = levels[level]
    M.info("logger", "Log level set to " .. level)
  else
    M.error("logger", "Invalid log level: " .. level)
  end
end

-- Configuration
function M.configure(opts)
  config = vim.tbl_extend("force", config, opts or {})
  current_level = levels[config.level] or levels.INFO
  
  if config.enabled then
    M.info("logger", "Logger configured", config)
  end
end

-- Commands
function M.setup_commands()
  vim.api.nvim_create_user_command("ZortexLogs", function(opts)
    local count = tonumber(opts.args) or 50
    M.show_logs(count)
  end, { nargs = "?" })
  
  vim.api.nvim_create_user_command("ZortexPerformance", function()
    M.show_performance_report()
  end, {})
  
  vim.api.nvim_create_user_command("ZortexLogLevel", function(opts)
    M.set_level(opts.args:upper())
  end, { 
    nargs = 1,
    complete = function()
      return { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }
    end
  })
  
  vim.api.nvim_create_user_command("ZortexClearLogs", function()
    M.clear_logs()
  end, {})
end

return M