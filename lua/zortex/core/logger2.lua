-- core/logger.lua
-- Centralized logging with performance tracking
local M = {}

-- Log levels
M.levels = {
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
}

-- Configuration
local config = {
  level = M.levels.INFO,
  file = nil,
  format = "[%s] %s: %s",
  performance_tracking = true,
  max_log_size = 10000, -- lines
}

-- State
local log_buffer = {}
local timers = {}

-- =============================================================================
-- Core Logging
-- =============================================================================

-- Format log message
local function format_message(level, component, message, data)
  local level_names = { "DEBUG", "INFO", "WARN", "ERROR" }
  local level_name = level_names[level] or "UNKNOWN"
  
  local base_msg = string.format(config.format, level_name, component, message)
  
  if data then
    base_msg = base_msg .. " " .. vim.inspect(data, { indent = "", newline = " " })
  end
  
  return os.date("%Y-%m-%d %H:%M:%S") .. " " .. base_msg
end

-- Write to log
local function write_log(message)
  -- Add to buffer
  table.insert(log_buffer, message)
  
  -- Trim buffer if too large
  if #log_buffer > config.max_log_size then
    -- Keep last 80% of max size
    local keep_from = math.floor(config.max_log_size * 0.2)
    local new_buffer = {}
    for i = keep_from, #log_buffer do
      table.insert(new_buffer, log_buffer[i])
    end
    log_buffer = new_buffer
  end
  
  -- Write to file if configured
  if config.file then
    local file = io.open(config.file, "a")
    if file then
      file:write(message .. "\n")
      file:close()
    end
  end
  
  -- Also print debug messages to vim messages
  if config.level == M.levels.DEBUG then
    print(message)
  end
end

-- Main log function
local function log(level, component, message, data)
  if level < config.level then
    return
  end
  
  local formatted = format_message(level, component, message, data)
  write_log(formatted)
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Log at different levels
function M.debug(component, message, data)
  log(M.levels.DEBUG, component, message, data)
end

function M.info(component, message, data)
  log(M.levels.INFO, component, message, data)
end

function M.warn(component, message, data)
  log(M.levels.WARN, component, message, data)
end

function M.error(component, message, data)
  log(M.levels.ERROR, component, message, data)
end

-- Generic log function
function M.log(level_name, data)
  local level = M.levels[level_name:upper()] or M.levels.INFO
  local component = data.component or "zortex"
  local message = data.message or ""
  
  log(level, component, message, data)
end

-- =============================================================================
-- Performance Tracking
-- =============================================================================

-- Start a timer
function M.start_timer(name)
  if not config.performance_tracking then
    return function() end -- No-op
  end
  
  local timer_id = name .. "_" .. vim.loop.hrtime()
  timers[timer_id] = {
    name = name,
    start = vim.loop.hrtime(),
  }
  
  -- Return stop function
  return function(data)
    M.stop_timer(timer_id, data)
  end
end

-- Stop a timer
function M.stop_timer(timer_id, data)
  local timer = timers[timer_id]
  if not timer then
    return
  end
  
  local elapsed = (vim.loop.hrtime() - timer.start) / 1e6 -- Convert to ms
  timers[timer_id] = nil
  
  -- Log if took significant time
  if elapsed > 10 then -- More than 10ms
    M.debug("performance", timer.name, vim.tbl_extend("force", data or {}, {
      elapsed_ms = elapsed,
      slow = elapsed > 50,
    }))
  end
  
  return elapsed
end

-- =============================================================================
-- Buffer Management
-- =============================================================================

-- Get log buffer
function M.get_buffer()
  return vim.deepcopy(log_buffer)
end

-- Clear log buffer
function M.clear_buffer()
  log_buffer = {}
end

-- Search log buffer
function M.search(pattern)
  local results = {}
  local regex = vim.regex(pattern)
  
  for i, line in ipairs(log_buffer) do
    if regex:match_str(line) then
      table.insert(results, {
        line = i,
        text = line,
      })
    end
  end
  
  return results
end

-- =============================================================================
-- Configuration
-- =============================================================================

-- Configure logger
function M.configure(opts)
  config = vim.tbl_extend("force", config, opts or {})
  
  -- Validate level
  if type(config.level) == "string" then
    config.level = M.levels[config.level:upper()] or M.levels.INFO
  end
  
  -- Create log directory if needed
  if config.file then
    local dir = vim.fn.fnamemodify(config.file, ":h")
    vim.fn.mkdir(dir, "p")
  end
end

-- Get configuration
function M.get_config()
  return vim.deepcopy(config)
end

-- =============================================================================
-- Vim Commands
-- =============================================================================

-- Show log in new buffer
function M.show_log()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, log_buffer)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_name(buf, "Zortex Log")
  
  -- Open in new window
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
  
  -- Go to end
  vim.cmd("normal! G")
end

-- Filter log
function M.filter_log(pattern)
  local results = M.search(pattern)
  local lines = {}
  
  for _, result in ipairs(results) do
    table.insert(lines, result.text)
  end
  
  if #lines == 0 then
    vim.notify("No log entries match pattern: " .. pattern, vim.log.levels.WARN)
    return
  end
  
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_name(buf, "Zortex Log (Filtered: " .. pattern .. ")")
  
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
end

-- =============================================================================
-- Performance Report
-- =============================================================================

-- Get performance statistics
function M.get_performance_stats()
  local stats = {}
  
  -- Parse log buffer for performance entries
  for _, line in ipairs(log_buffer) do
    if line:match("%[DEBUG%] performance:") then
      local name = line:match("performance: ([^%s]+)")
      local elapsed = line:match("elapsed_ms = ([%d%.]+)")
      
      if name and elapsed then
        elapsed = tonumber(elapsed)
        
        if not stats[name] then
          stats[name] = {
            count = 0,
            total = 0,
            min = math.huge,
            max = 0,
          }
        end
        
        local stat = stats[name]
        stat.count = stat.count + 1
        stat.total = stat.total + elapsed
        stat.min = math.min(stat.min, elapsed)
        stat.max = math.max(stat.max, elapsed)
      end
    end
  end
  
  -- Calculate averages
  for name, stat in pairs(stats) do
    stat.avg = stat.total / stat.count
  end
  
  return stats
end

-- Show performance report
function M.show_performance_report()
  local stats = M.get_performance_stats()
  local lines = { "Zortex Performance Report", "========================", "" }
  
  -- Sort by total time
  local sorted = {}
  for name, stat in pairs(stats) do
    table.insert(sorted, { name = name, stat = stat })
  end
  table.sort(sorted, function(a, b)
    return a.stat.total > b.stat.total
  end)
  
  -- Format report
  table.insert(lines, string.format("%-40s %6s %6s %6s %6s %6s",
    "Operation", "Count", "Total", "Avg", "Min", "Max"))
  table.insert(lines, string.rep("-", 80))
  
  for _, entry in ipairs(sorted) do
    table.insert(lines, string.format("%-40s %6d %6.1f %6.1f %6.1f %6.1f",
      entry.name,
      entry.stat.count,
      entry.stat.total,
      entry.stat.avg,
      entry.stat.min,
      entry.stat.max
    ))
  end
  
  -- Show in buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_name(buf, "Zortex Performance Report")
  
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
end

return M