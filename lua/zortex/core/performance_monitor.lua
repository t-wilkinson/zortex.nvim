-- core/performance_monitor.lua - Advanced performance monitoring for Zortex
local M = {}

local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")

-- Performance thresholds (in milliseconds)
local thresholds = {
	parse_full = 100, -- Full document parse
	parse_incremental = 20, -- Incremental parse
	event_processing = 16, -- Single event handler
	task_toggle = 10, -- Task completion toggle
	search = 50, -- Search operations
	buffer_sync = 5, -- Buffer synchronization
	ui_update = 16, -- UI updates (60fps target)
}

-- Performance metrics storage
local metrics = {
	operations = {}, -- operation -> { samples, p50, p95, p99 }
	slow_operations = {}, -- operation -> count
	memory_usage = {}, -- timestamp -> usage
	event_queue_size = {}, -- timestamp -> size
}

-- Sampling configuration
local sampling_config = {
	max_samples = 1000, -- Max samples per operation
	memory_interval = 5000, -- Memory sampling interval (ms)
	report_interval = 60000, -- Auto-report interval (ms)
}

-- Active monitoring
local monitoring_active = false
local memory_timer = nil
local report_timer = nil

-- Calculate percentiles
local function calculate_percentiles(samples)
	if #samples == 0 then
		return { p50 = 0, p95 = 0, p99 = 0, min = 0, max = 0, avg = 0 }
	end

	-- Sort samples
	local sorted = vim.tbl_extend("force", {}, samples)
	table.sort(sorted)

	local p50_idx = math.floor(#sorted * 0.5)
	local p95_idx = math.floor(#sorted * 0.95)
	local p99_idx = math.floor(#sorted * 0.99)

	-- Calculate average
	local sum = 0
	for _, v in ipairs(sorted) do
		sum = sum + v
	end

	return {
		p50 = sorted[math.max(1, p50_idx)],
		p95 = sorted[math.max(1, p95_idx)],
		p99 = sorted[math.max(1, p99_idx)],
		min = sorted[1],
		max = sorted[#sorted],
		avg = sum / #sorted,
		count = #sorted,
	}
end

-- Track operation performance
local function track_operation(operation, duration_ms)
	if not metrics.operations[operation] then
		metrics.operations[operation] = {
			samples = {},
			total_time = 0,
			count = 0,
		}
	end

	local op_metrics = metrics.operations[operation]

	-- Add sample
	table.insert(op_metrics.samples, duration_ms)
	op_metrics.total_time = op_metrics.total_time + duration_ms
	op_metrics.count = op_metrics.count + 1

	-- Trim samples if needed
	if #op_metrics.samples > sampling_config.max_samples then
		table.remove(op_metrics.samples, 1)
	end

	-- Check threshold
	local threshold = thresholds[operation] or 50
	if duration_ms > threshold then
		metrics.slow_operations[operation] = (metrics.slow_operations[operation] or 0) + 1

		Logger.warn("performance", "Slow operation detected", {
			operation = operation,
			duration = duration_ms,
			threshold = threshold,
			slow_count = metrics.slow_operations[operation],
		})
	end
end

-- Sample memory usage
local function sample_memory()
	local memory_info = vim.api.nvim_eval("execute('memory')")
	local used_match = memory_info:match("Used:%s*(%d+)")

	if used_match then
		local used_kb = tonumber(used_match)
		local timestamp = os.time()

		table.insert(metrics.memory_usage, {
			timestamp = timestamp,
			used_kb = used_kb,
		})

		-- Keep only last hour of samples
		local one_hour_ago = timestamp - 3600
		metrics.memory_usage = vim.tbl_filter(function(sample)
			return sample.timestamp > one_hour_ago
		end, metrics.memory_usage)

		-- Check for memory growth
		if #metrics.memory_usage > 10 then
			local old_sample = metrics.memory_usage[#metrics.memory_usage - 10]
			local growth_kb = used_kb - old_sample.used_kb
			local growth_percent = (growth_kb / old_sample.used_kb) * 100

			if growth_percent > 20 then
				Logger.warn("performance", "High memory growth detected", {
					growth_kb = growth_kb,
					growth_percent = growth_percent,
					current_kb = used_kb,
				})
			end
		end
	end
end

-- Generate performance report
local function generate_report()
	local report = {
		timestamp = os.date("%Y-%m-%d %H:%M:%S"),
		operations = {},
		slow_operations = metrics.slow_operations,
		memory = {},
		recommendations = {},
	}

	-- Calculate operation statistics
	for operation, data in pairs(metrics.operations) do
		local stats = calculate_percentiles(data.samples)
		stats.total_time = data.total_time
		stats.slow_count = metrics.slow_operations[operation] or 0
		stats.slow_rate = stats.count > 0 and (stats.slow_count / stats.count * 100) or 0

		report.operations[operation] = stats

		-- Add recommendations
		if stats.p95 > (thresholds[operation] or 50) * 2 then
			table.insert(report.recommendations, {
				severity = "high",
				operation = operation,
				message = string.format(
					"%s is consistently slow (p95: %.1fms, threshold: %dms)",
					operation,
					stats.p95,
					thresholds[operation] or 50
				),
			})
		end
	end

	-- Memory statistics
	if #metrics.memory_usage > 0 then
		local memory_values = vim.tbl_map(function(s)
			return s.used_kb
		end, metrics.memory_usage)
		report.memory = calculate_percentiles(memory_values)
		report.memory.samples = #metrics.memory_usage

		-- Memory growth analysis
		if #metrics.memory_usage > 2 then
			local first = metrics.memory_usage[1].used_kb
			local last = metrics.memory_usage[#metrics.memory_usage].used_kb
			local growth = last - first
			local duration = metrics.memory_usage[#metrics.memory_usage].timestamp - metrics.memory_usage[1].timestamp

			report.memory.growth_kb = growth
			report.memory.growth_rate_kb_per_min = (growth / duration) * 60

			if report.memory.growth_rate_kb_per_min > 100 then
				table.insert(report.recommendations, {
					severity = "high",
					category = "memory",
					message = string.format(
						"High memory growth rate: %.1f KB/min",
						report.memory.growth_rate_kb_per_min
					),
				})
			end
		end
	end

	return report
end

-- Monitor specific operations
local function setup_operation_monitoring()
	-- Document parsing
	EventBus.on("document:parsed", function(data)
		local operation = data.full_parse and "parse_full" or "parse_incremental"
		track_operation(operation, data.parse_time)
	end, {
		priority = 10,
		name = "perf_monitor_parse",
	})

	-- Task operations
	EventBus.on("task:toggled", function(data)
		if data.elapsed then
			track_operation("task_toggle", data.elapsed)
		end
	end, {
		priority = 10,
		name = "perf_monitor_task",
	})

	-- Buffer sync
	EventBus.on("buffer:synced", function(data)
		if data.elapsed then
			track_operation("buffer_sync", data.elapsed)
		end
	end, {
		priority = 10,
		name = "perf_monitor_sync",
	})

	-- Event processing (via middleware)
	local event_timers = {}

	EventBus.add_middleware(function(event, data)
		local timer_id = string.format("%s_%d", event, vim.loop.hrtime())
		event_timers[timer_id] = {
			event = event,
			start = vim.loop.hrtime(),
		}

		-- Track completion in next tick
		vim.schedule(function()
			local timer = event_timers[timer_id]
			if timer then
				local elapsed = (vim.loop.hrtime() - timer.start) / 1e6
				track_operation("event:" .. event, elapsed)

				-- Track event queue size
				local queue_size = vim.tbl_count(event_timers)
				table.insert(metrics.event_queue_size, {
					timestamp = os.time(),
					size = queue_size,
				})

				-- Cleanup
				event_timers[timer_id] = nil

				-- Warn on large queue
				if queue_size > 50 then
					Logger.warn("performance", "Large event queue", {
						size = queue_size,
						event = event,
					})
				end
			end
		end)

		return true, data
	end)
end

-- Public API

-- Start monitoring
function M.start()
	if monitoring_active then
		return
	end

	monitoring_active = true

	-- Setup operation monitoring
	setup_operation_monitoring()

	-- Start memory sampling
	memory_timer = vim.fn.timer_start(sampling_config.memory_interval, function()
		vim.schedule(sample_memory)
	end, { ["repeat"] = -1 })

	-- Start periodic reporting
	report_timer = vim.fn.timer_start(sampling_config.report_interval, function()
		vim.schedule(function()
			local report = generate_report()
			if #report.recommendations > 0 then
				Logger.warn("performance", "Performance issues detected", report)
			end
		end)
	end, { ["repeat"] = -1 })

	Logger.info("performance_monitor", "Started monitoring")
end

-- Stop monitoring
function M.stop()
	monitoring_active = false

	if memory_timer then
		vim.fn.timer_stop(memory_timer)
		memory_timer = nil
	end

	if report_timer then
		vim.fn.timer_stop(report_timer)
		report_timer = nil
	end

	Logger.info("performance_monitor", "Stopped monitoring")
end

-- Get current report
function M.get_report()
	return generate_report()
end

-- Show report in buffer
function M.show_report()
	local report = generate_report()

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_name(buf, "Zortex Performance Report")

	local lines = {
		"Zortex Performance Report",
		"Generated: " .. report.timestamp,
		"",
	}

	-- Operation statistics
	table.insert(lines, "Operation Performance")
	table.insert(lines, "====================")
	table.insert(lines, "")
	table.insert(
		lines,
		string.format(
			"%-30s %8s %8s %8s %8s %8s %8s %8s",
			"Operation",
			"Count",
			"Avg(ms)",
			"P50(ms)",
			"P95(ms)",
			"P99(ms)",
			"Slow",
			"Rate(%)"
		)
	)
	table.insert(lines, string.rep("-", 110))

	-- Sort by slow rate
	local sorted_ops = {}
	for op, _ in pairs(report.operations) do
		table.insert(sorted_ops, op)
	end
	table.sort(sorted_ops, function(a, b)
		local a_stats = report.operations[a]
		local b_stats = report.operations[b]
		return a_stats.slow_rate > b_stats.slow_rate
	end)

	for _, op in ipairs(sorted_ops) do
		local stats = report.operations[op]
		local line = string.format(
			"%-30s %8d %8.1f %8.1f %8.1f %8.1f %8d %8.1f",
			op,
			stats.count,
			stats.avg,
			stats.p50,
			stats.p95,
			stats.p99,
			stats.slow_count,
			stats.slow_rate
		)

		-- Highlight slow operations
		if stats.slow_rate > 10 then
			line = "! " .. line
		end

		table.insert(lines, line)
	end

	-- Memory statistics
	if report.memory.samples then
		table.insert(lines, "")
		table.insert(lines, "Memory Usage")
		table.insert(lines, "============")
		table.insert(lines, "")
		table.insert(lines, string.format("Current: %.1f MB", report.memory.max / 1024))
		table.insert(lines, string.format("Average: %.1f MB", report.memory.avg / 1024))
		table.insert(lines, string.format("Min: %.1f MB", report.memory.min / 1024))
		table.insert(lines, string.format("Max: %.1f MB", report.memory.max / 1024))

		if report.memory.growth_rate_kb_per_min then
			table.insert(lines, string.format("Growth Rate: %.1f KB/min", report.memory.growth_rate_kb_per_min))
		end
	end

	-- Recommendations
	if #report.recommendations > 0 then
		table.insert(lines, "")
		table.insert(lines, "Recommendations")
		table.insert(lines, "===============")
		table.insert(lines, "")

		for _, rec in ipairs(report.recommendations) do
			table.insert(lines, string.format("[%s] %s", string.upper(rec.severity), rec.message))
		end
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	-- Open in split
	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)
end

-- Reset metrics
function M.reset()
	metrics = {
		operations = {},
		slow_operations = {},
		memory_usage = {},
		event_queue_size = {},
	}
	Logger.info("performance_monitor", "Reset metrics")
end

-- Configure thresholds
function M.configure(opts)
	if opts.thresholds then
		thresholds = vim.tbl_extend("force", thresholds, opts.thresholds)
	end

	if opts.sampling then
		sampling_config = vim.tbl_extend("force", sampling_config, opts.sampling)
	end

	Logger.info("performance_monitor", "Configured", {
		thresholds = thresholds,
		sampling = sampling_config,
	})
end

-- Get status
function M.get_status()
	local total_samples = 0
	local total_operations = vim.tbl_count(metrics.operations)

	for _, data in pairs(metrics.operations) do
		total_samples = total_samples + #data.samples
	end

	return {
		active = monitoring_active,
		operations_tracked = total_operations,
		total_samples = total_samples,
		memory_samples = #metrics.memory_usage,
		slow_operations = vim.tbl_count(metrics.slow_operations),
	}
end

-- Setup commands
function M.setup_commands()
	vim.api.nvim_create_user_command("ZortexPerfReport", function()
		M.show_report()
	end, {})

	vim.api.nvim_create_user_command("ZortexPerfReset", function()
		M.reset()
		vim.notify("Performance metrics reset")
	end, {})

	vim.api.nvim_create_user_command("ZortexPerfStart", function()
		M.start()
		vim.notify("Performance monitoring started")
	end, {})

	vim.api.nvim_create_user_command("ZortexPerfStop", function()
		M.stop()
		vim.notify("Performance monitoring stopped")
	end, {})
end

return M

