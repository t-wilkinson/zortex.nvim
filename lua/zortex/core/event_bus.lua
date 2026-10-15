-- core/event_bus.lua - Domain events between services
--
--   Events.on("task:completed", function(data) ... end, { priority = 50, name = "xp" })
--   Events.emit("task:completed", { task = task, doc_context = ctx })
--
-- Handlers run asynchronously (vim.schedule) in priority order (higher
-- first); errors are reported, never raised into the emitter. Pass
-- { async = false } to on() for a synchronous handler.
--
-- Events in use:
--   task:completed, task:uncompleted, task:created   services/tasks  -> xp, digest
--   xp:awarded, xp:removed                           services/xp     -> xp notifications
--   season:started, season:ended, season:tier_reached  stores/xp  -> xp notifications
--   calendar:entry_added, _removed, _updated         stores/calendar -> digest
--   workspace:lines_changed                          core/workspace  -> digest live links
local M = {}

local handlers = {} -- event -> { { fn, priority, name, original } }
local middleware = {}
local stats = {} -- event -> { count, total_time, max_time }

local function track(event, ms)
	local s = stats[event] or { count = 0, total_time = 0, max_time = 0 }
	s.count, s.total_time, s.max_time = s.count + 1, s.total_time + ms, math.max(s.max_time, ms)
	stats[event] = s
end

function M.on(event, handler, opts)
	opts = opts or {}
	local name = opts.name or (event .. "#" .. (#(handlers[event] or {}) + 1))
	local function run(data)
		local start = vim.uv.hrtime()
		local ok, err = xpcall(handler, debug.traceback, data)
		track(event, (vim.uv.hrtime() - start) / 1e6)
		if not ok then
			vim.notify(string.format("[Zortex] %s handler '%s' failed: %s", event, name, err), vim.log.levels.ERROR)
		end
	end
	local list = handlers[event] or {}
	handlers[event] = list
	list[#list + 1] = {
		fn = opts.async == false and run or function(data)
			vim.schedule(function()
				run(data)
			end)
		end,
		priority = opts.priority or 50,
		original = handler,
	}
	table.sort(list, function(a, b)
		return a.priority > b.priority
	end)
	return {
		remove = function()
			M.off(event, handler)
		end,
	}
end

function M.off(event, handler)
	local list = handlers[event] or {}
	for i = #list, 1, -1 do
		if list[i].original == handler then
			table.remove(list, i)
		end
	end
end

function M.emit(event, data)
	for _, mw in ipairs(middleware) do
		local continue, new_data = mw(event, data)
		if not continue then
			return
		end
		data = new_data or data
	end
	for _, h in ipairs(handlers[event] or {}) do
		h.fn(data)
	end
end

--- fn(event, data) -> continue, data
function M.add_middleware(fn)
	middleware[#middleware + 1] = fn
end

function M.get_performance_report()
	local report = {}
	for event, s in pairs(stats) do
		report[event] = { count = s.count, avg_time = s.total_time / s.count, max_time = s.max_time }
	end
	return report
end

return M
