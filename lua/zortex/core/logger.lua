-- core/logger.lua - Performance logging and debugging utilities
local constants = require("zortex.constants")

local M = {}

-- Logger configuration
local cfg = {} -- Config.core.logger

-- Log levels
local levels = {
	TRACE = 1,
	DEBUG = 2,
	INFO = 3,
	WARN = 4,
	ERROR = 5,
}

-- In-memory log buffer
local log_buffer = {}

-- Performance tracking
local performance_stats = {}
local active_timers = {}

-- ANSI color codes for terminal output
local colors = {
	TRACE = "\27[90m", -- Gray
	DEBUG = "\27[36m", -- Cyan
	INFO = "\27[32m", -- Green
	WARN = "\27[33m", -- Yellow
	ERROR = "\27[31m", -- Red
	RESET = "\27[0m",
	BOLD = "\27[1m",
}

local function format_value(value)
	if value then
		if type(value) == "table" then
			return vim.inspect(value, {
				indent = "  ",
				depth = 3,
			})
		else
			return tostring(value)
		end
	else
		return ""
	end
end

-- Format log entry
local function format_entry(level, category, message, data)
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	local level_str = level

	-- Format message with data
	local formatted_message = format_value(message) .. " " .. format_value(data)

	return string.format("[%s] %s [%s] %s", timestamp, level_str, category, formatted_message)
end

-- Write to log file
local function write_to_file(entry)
	local file = io.open(constants.FILES.LOG, "a")
	if file then
		file:write(entry .. "\n")
		file:close()
	end
end

-- Core logging function
local function log(level, category, message, data)
	if not cfg.enabled then
		return
	end
	if levels[level] < cfg.level then
		return
	end

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
	if #log_buffer > cfg.max_entries then
		table.remove(log_buffer, 1)
	end

	-- Write to file
	write_to_file(entry)
	vim.notify(entry, levels[level])

	-- Console output for warnings and errors
	if levels[level] >= levels.WARN then
		local color = colors[level] or ""
		local formatted = color .. colors.BOLD .. "[Zortex] " .. entry .. colors.RESET
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
	if not cfg.enabled then
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
		if not timer then
			return
		end

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
		if elapsed > cfg.performance_threshold then
			M.warn(
				"performance",
				string.format("%s took %.2fms (threshold: %dms)", operation_name, elapsed, cfg.performance_threshold),
				extra_data
			)
		else
			M.debug("performance", string.format("%s completed in %.2fms", operation_name, elapsed), extra_data)
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
				elapsed = elapsed,
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
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_name(buf, "Zortex Performance Report")

	-- Format report
	local lines = {
		"Zortex Performance Report",
		"========================",
		"",
		string.format(
			"%-30s %8s %8s %8s %8s %8s %8s %8s",
			"Operation",
			"Count",
			"Avg(ms)",
			"Min(ms)",
			"Max(ms)",
			"P50(ms)",
			"P95(ms)",
			"P99(ms)"
		),
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
		table.insert(
			lines,
			string.format(
				"%-30s %8d %8.2f %8.2f %8.2f %8.2f %8.2f %8.2f",
				op,
				stats.count,
				stats.avg_time,
				stats.min_time,
				stats.max_time,
				stats.p50,
				stats.p95,
				stats.p99
			)
		)
	end

	-- Also show Events stats
	local event_report = require("zortex.core.event_bus").get_performance_report()
	if next(event_report) then
		table.insert(lines, "")
		table.insert(lines, "Event Performance")
		table.insert(lines, "-----------------")
		table.insert(lines, string.format("%-30s %8s %8s %8s %8s", "Event", "Count", "Avg(ms)", "Min(ms)", "Max(ms)"))
		table.insert(lines, string.rep("-", 70))

		for event, stats in pairs(event_report) do
			table.insert(
				lines,
				string.format(
					"%-30s %8d %8.2f %8.2f %8.2f",
					event,
					stats.count,
					stats.avg_time,
					stats.min_time,
					stats.max_time
				)
			)
		end
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	-- Open in split
	vim.cmd("split")
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
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_name(buf, "Zortex Logs")

	-- Format logs
	local lines = {}
	for _, entry in ipairs(logs) do
		table.insert(lines, entry.formatted)
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	-- Open in split
	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)

	-- Go to end
	vim.cmd("normal! G")
end

-- Clear logs
function M.clear_logs()
	log_buffer = {}
	performance_stats = {}
	M.info("logger", "Logs cleared")
end

-- Enable/disable logging
function M.enable()
	cfg.enabled = true
	M.info("logger", "Logging enabled")
end

function M.disable()
	M.info("logger", "Logging disabled")
	cfg.enabled = false
end

function M.set_level(level)
	if levels[level] then
		cfg.level = level
		M.info("logger", "Log level set to " .. level)
	else
		M.error("logger", "Invalid log level: " .. level)
	end
end

-- Configuration
function M.setup(opts)
	cfg = opts

	if cfg.enabled then
		M.info("logger", "Logger configured", cfg)
	end
end

return M

--[[
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
local cfg = {
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

	local base_msg = string.format(cfg.format, level_name, component, message)

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
	if #log_buffer > cfg.max_log_size then
		-- Keep last 80% of max size
		local keep_from = math.floor(cfg.max_log_size * 0.2)
		local new_buffer = {}
		for i = keep_from, #log_buffer do
			table.insert(new_buffer, log_buffer[i])
		end
		log_buffer = new_buffer
	end

	-- Write to file if configured
	if cfg.file then
		local file = io.open(cfg.file, "a")
		if file then
			file:write(message .. "\n")
			file:close()
		end
	end

	-- Also print debug messages to vim messages
	if cfg.level == M.levels.DEBUG then
		print(message)
	end
end

-- Main log function
local function log(level, component, message, data)
	if level < cfg.level then
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
	if not cfg.performance_tracking then
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
		M.debug(
			"performance",
			timer.name,
			vim.tbl_extend("force", data or {}, {
				elapsed_ms = elapsed,
				slow = elapsed > 50,
			})
		)
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
	cfg = vim.tbl_extend("force", cfg, opts or {})

	-- Validate level
	if type(cfg.level) == "string" then
		cfg.level = M.levels[cfg.level:upper()] or M.levels.INFO
	end

	-- Create log directory if needed
	if cfg.file then
		local dir = vim.fn.fnamemodify(cfg.file, ":h")
		vim.fn.mkdir(dir, "p")
	end
end

-- Get configuration
function M.get_config()
	return vim.deepcopy(cfg)
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
	table.insert(lines, string.format("%-40s %6s %6s %6s %6s %6s", "Operation", "Count", "Total", "Avg", "Min", "Max"))
	table.insert(lines, string.rep("-", 80))

	for _, entry in ipairs(sorted) do
		table.insert(
			lines,
			string.format(
				"%-40s %6d %6.1f %6.1f %6.1f %6.1f",
				entry.name,
				entry.stat.count,
				entry.stat.total,
				entry.stat.avg,
				entry.stat.min,
				entry.stat.max
			)
		)
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

--]]
