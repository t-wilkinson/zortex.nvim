-- core/logger.lua - Small leveled logger with timers
--
--   Logger.info("calendar", "Loaded", { entries = 12 })
--   local stop = Logger.start_timer("xp.award"); ...; stop()
--
-- Entries go to an in-memory ring buffer (:ZortexDebug logs) and, when
-- core.logger.enabled is set, to zortex.log in this machine's state folder
-- (core/state device_dir). Timers record operations slower than
-- core.logger.performance_threshold ms (:ZortexDebug timers).
local M = {}

M.levels = { TRACE = 1, DEBUG = 2, INFO = 3, WARN = 4, ERROR = 5 }
local NAMES = { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }

local cfg = { enabled = false, level = 3, max_entries = 1000, performance_threshold = 16 }
local entries = {}
local timings = {} -- operation -> { count, total, max }

local function log_path()
	return require("zortex.core.state").device_dir() .. "/zortex.log"
end

local function record(level, category, message, data)
	if not cfg.enabled or level < cfg.level then
		return
	end
	local entry = { time = os.time(), level = level, category = category, message = message, data = data }
	entries[#entries + 1] = entry
	if #entries > cfg.max_entries then
		table.remove(entries, 1)
	end
	local line = string.format(
		"%s [%s] %s: %s%s",
		os.date("%Y-%m-%d %H:%M:%S", entry.time),
		NAMES[level],
		category,
		tostring(message),
		data and (" " .. vim.inspect(data, { newline = " ", indent = "" })) or ""
	)
	local path = log_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "a")
	if f then
		f:write(line, "\n")
		f:close()
	end
end

for name, level in pairs(M.levels) do
	M[name:lower()] = function(category, message, data)
		record(level, category, message, data)
	end
end

--- Start timing an operation; call the returned function when done.
function M.start_timer(operation)
	local start = vim.uv.hrtime()
	return function(data)
		local ms = (vim.uv.hrtime() - start) / 1e6
		local t = timings[operation] or { count = 0, total = 0, max = 0 }
		t.count, t.total, t.max = t.count + 1, t.total + ms, math.max(t.max, ms)
		timings[operation] = t
		if ms > cfg.performance_threshold then
			record(M.levels.WARN, "performance", string.format("%s took %.1fms", operation, ms), data)
		end
		return ms
	end
end

local function show(lines, name)
	vim.cmd("new")
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	pcall(vim.api.nvim_buf_set_name, buf, name)
end

function M.get_recent_logs(count)
	local out = {}
	for i = math.max(1, #entries - (count or 50) + 1), #entries do
		out[#out + 1] = entries[i]
	end
	return out
end

function M.show_logs(count)
	local lines = {}
	for _, e in ipairs(M.get_recent_logs(count)) do
		lines[#lines + 1] = string.format(
			"%s [%s] %s: %s%s",
			os.date("%H:%M:%S", e.time),
			NAMES[e.level],
			e.category,
			tostring(e.message),
			e.data and (" " .. vim.inspect(e.data, { newline = " ", indent = "" })) or ""
		)
	end
	if #lines == 0 then
		lines = { cfg.enabled and "No log entries" or "Logging is off (core.logger.enabled = false)" }
	end
	show(lines, "Zortex Logs")
end

function M.show_performance_report()
	local ops = vim.tbl_keys(timings)
	table.sort(ops, function(a, b)
		return timings[a].total > timings[b].total
	end)
	local lines = { string.format("%-32s %6s %10s %10s", "operation", "count", "avg ms", "max ms") }
	for _, op in ipairs(ops) do
		local t = timings[op]
		lines[#lines + 1] = string.format("%-32s %6d %10.2f %10.2f", op, t.count, t.total / t.count, t.max)
	end
	show(lines, "Zortex Performance")
end

function M.clear_logs()
	entries, timings = {}, {}
	os.remove(log_path())
end

function M.set_level(level)
	cfg.level = M.levels[level] or tonumber(level) or cfg.level
end

function M.setup(opts)
	cfg = vim.tbl_extend("force", cfg, opts or {})
	if type(cfg.level) == "string" then
		cfg.level = M.levels[cfg.level:upper()] or 3
	end
end

return M
