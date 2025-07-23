-- core/event_bus.lua - Event system with priority handling and async execution
local M = {}

-- Priority queue implementation
local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

function PriorityQueue:new()
	return setmetatable({ items = {} }, self)
end

function PriorityQueue:push(item, priority)
	table.insert(self.items, { item = item, priority = priority })
	table.sort(self.items, function(a, b)
		return a.priority > b.priority
	end)
end

function PriorityQueue:pop()
	return table.remove(self.items, 1)
end

function PriorityQueue:is_empty()
	return #self.items == 0
end

-- EventBus implementation
local EventBus = {
	handlers = {}, -- event -> handler_list
	middleware = {}, -- Global processors
	is_processing = false,
	stats = { -- Performance tracking
		events = {}, -- event -> { count, total_time, max_time }
	},
}

-- Internal: ensure handler list exists
function EventBus:ensure_handler_list(event)
	if not self.handlers[event] then
		self.handlers[event] = {}
	end
	return self.handlers[event]
end

-- Register an event handler
function EventBus:on(event, handler, opts)
	opts = vim.tbl_extend("keep", opts or {}, {
		priority = 50, -- Default priority (0-100)
		async = true, -- Default async execution
		max_time = 100, -- Warn if handler takes >100ms
		name = nil, -- Optional handler name for debugging
	})

	-- Create wrapped handler with error handling and timing
	local wrapped_handler = function(data)
		local start = vim.loop.hrtime()
		local handler_name = opts.name or string.format("%s_handler_%d", event, #self:ensure_handler_list(event) + 1)

		local function run()
			-- Execute with error handling
			local ok, err = xpcall(handler, debug.traceback, data)

			-- Track performance
			local elapsed = (vim.loop.hrtime() - start) / 1e6 -- Convert to ms
			self:track_performance(event, elapsed)

			-- Warn on slow handlers
			if elapsed > opts.max_time then
				vim.notify(
					string.format("[EventBus] Slow handler '%s' for event '%s': %.1fms", handler_name, event, elapsed),
					vim.log.levels.WARN
				)
			end

			-- Report errors
			if not ok then
				vim.notify(
					string.format("[EventBus] Handler '%s' error for event '%s': %s", handler_name, event, err),
					vim.log.levels.ERROR
				)
			end
		end

		-- Execute based on async setting
		if opts.async then
			vim.schedule(run)
		else
			run()
		end
	end

	-- Store handler with metadata
	local handlers = self:ensure_handler_list(event)
	table.insert(handlers, {
		fn = wrapped_handler,
		priority = opts.priority,
		name = opts.name,
		original = handler, -- For removal
	})

	-- Sort by priority (higher priority first)
	table.sort(handlers, function(a, b)
		return a.priority > b.priority
	end)

	-- Return handle for removal
	return {
		event = event,
		handler = handler,
		remove = function()
			self:off(event, handler)
		end,
	}
end

-- Remove an event handler
function EventBus:off(event, handler)
	local handlers = self.handlers[event]
	if not handlers then
		return
	end

	for i = #handlers, 1, -1 do
		if handlers[i].original == handler then
			table.remove(handlers, i)
			break
		end
	end
end

-- Emit an event
function EventBus:emit(event, data, opts)
	opts = opts or {}
	local handlers = self.handlers[event] or {}

	-- Apply middleware
	for _, mw in ipairs(self.middleware) do
		local continue, new_data = mw(event, data)
		if not continue then
			return -- Middleware can stop propagation
		end
		data = new_data or data
	end

	-- Debug logging
	if vim.g.zortex_debug_events then
		vim.notify(string.format("[EventBus] Emit '%s' with %d handlers", event, #handlers), vim.log.levels.DEBUG)
	end

	-- Execute handlers
	if opts.sync then
		-- Rare case: execute immediately in order
		for _, h in ipairs(handlers) do
			h.fn(data)
		end
	else
		-- Normal case: let handlers self-schedule
		for _, h in ipairs(handlers) do
			h.fn(data)
		end
	end
end

-- Add middleware
function EventBus:add_middleware(fn)
	table.insert(self.middleware, fn)
end

-- Track performance statistics
function EventBus:track_performance(event, elapsed_ms)
	if not self.stats.events[event] then
		self.stats.events[event] = {
			count = 0,
			total_time = 0,
			max_time = 0,
			min_time = math.huge,
		}
	end

	local stats = self.stats.events[event]
	stats.count = stats.count + 1
	stats.total_time = stats.total_time + elapsed_ms
	stats.max_time = math.max(stats.max_time, elapsed_ms)
	stats.min_time = math.min(stats.min_time, elapsed_ms)
end

-- Get performance report
function EventBus:get_performance_report()
	local report = {}
	for event, stats in pairs(self.stats.events) do
		report[event] = {
			count = stats.count,
			avg_time = stats.total_time / stats.count,
			max_time = stats.max_time,
			min_time = stats.min_time,
			total_time = stats.total_time,
		}
	end
	return report
end

-- Clear all handlers (useful for tests)
function EventBus:clear()
	self.handlers = {}
	self.middleware = {}
	self.stats.events = {}
end

-- Create singleton instance
M._instance = EventBus

-- Public API
function M.on(event, handler, opts)
	return M._instance:on(event, handler, opts)
end

function M.off(event, handler)
	return M._instance:off(event, handler)
end

function M.emit(event, data, opts)
	return M._instance:emit(event, data, opts)
end

function M.add_middleware(fn)
	return M._instance:add_middleware(fn)
end

function M.get_performance_report()
	return M._instance:get_performance_report()
end

function M.clear()
	return M._instance:clear()
end

-- Example middleware: Event logging
if vim.g.zortex_log_events then
	M.add_middleware(function(event, data)
		require("zortex.core.logger").log("event", {
			event = event,
			data = data,
			timestamp = os.time(),
		})
		return true, data -- Continue propagation
	end)
end

return M
