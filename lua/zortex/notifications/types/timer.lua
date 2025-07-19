-- notifications/types/timer.lua - Timer/alarm implementation
local M = {}

local manager = require("zortex.notifications.manager")
local datetime = require("zortex.core.datetime")

local active_timers = {}
local config = {}

-- Create timer ID
local function create_timer_id()
	return string.format("timer_%s_%s", os.time(), math.random(1000))
end

-- Format time
local function format_time(seconds)
	if seconds < 60 then
		return string.format("%d seconds", seconds)
	elseif seconds < 3600 then
		return string.format("%d minutes", math.floor(seconds / 60))
	else
		local hours = math.floor(seconds / 3600)
		local mins = math.floor((seconds % 3600) / 60)
		if mins > 0 then
			return string.format("%d hours %d minutes", hours, mins)
		else
			return string.format("%d hours", hours)
		end
	end
end

-- Timer tick function
local function create_timer_tick(timer_id)
	return function()
		local timer = active_timers[timer_id]
		if not timer then
			return
		end

		timer.remaining = timer.remaining - 1

		-- Warning notifications
		if config.warnings then
			for _, warning_time in ipairs(config.warnings) do
				if timer.remaining == warning_time and not timer.warnings_sent[warning_time] then
					timer.warnings_sent[warning_time] = true
					manager.send_notification(
						timer.name .. " - " .. format_time(warning_time) .. " remaining",
						format_time(warning_time) .. " remaining for " .. timer.name,
						{ type = "timer", priority = "low" }
					)
				end
			end
		end

		if timer.remaining <= 0 then
			-- Timer complete
			manager.send_notification(
				timer.title or "Timer Complete",
				timer.message or string.format("Timer '%s' has finished!", timer.name),
				{
					type = "timer",
					sound = timer.sound or config.default_sound,
					priority = "urgent",
				}
			)

			-- Clean up
			if timer.handle then
				timer.handle:stop()
				timer.handle:close()
			end
			active_timers[timer_id] = nil

			-- Execute callback if provided
			if timer.callback then
				vim.schedule(timer.callback)
			end
		end
	end
end

-- Start a timer
function M.start(duration, name, options)
	options = options or {}

	if not config.allow_multiple and next(active_timers) then
		return nil, "Multiple timers not allowed"
	end

	local timer_id = create_timer_id()
	local duration_seconds = duration

	-- Parse duration if string
	if type(duration) == "string" then
		local minutes = datetime.parse_duration(duration)
		if not minutes then
			return nil, "Invalid duration format"
		end
		duration_seconds = minutes * 60
	elseif type(duration) == "number" then
		-- If less than 180, assume minutes; otherwise seconds
		if duration < 180 then
			duration_seconds = duration * 60
		end
	end

	local timer = {
		id = timer_id,
		name = name or string.format("Timer (%s)", format_time(duration_seconds)),
		duration = duration_seconds,
		remaining = duration_seconds,
		started_at = os.time(),
		title = options.title,
		message = options.message,
		sound = options.sound,
		callback = options.callback,
		warnings_sent = {},
	}

	-- Create timer handle
	timer.handle = vim.loop.new_timer()
	timer.handle:start(0, 1000, vim.schedule_wrap(create_timer_tick(timer_id)))

	active_timers[timer_id] = timer

	-- Send start notification
	manager.send_notification(
		"Timer Started",
		string.format("Timer '%s' started for %s", timer.name, format_time(duration_seconds)),
		{ type = "timer" }
	)

	return timer_id
end

-- Start an alarm (timer for specific time)
function M.alarm(time_str, name, options)
	options = options or {}

	-- Parse time
	local target_time
	local now = os.time()

	if type(time_str) == "string" then
		-- Try to parse as time (HH:MM)
		local time = datetime.parse_time(time_str)
		if time then
			local today = os.date("*t")
			today.hour = time.hour
			today.min = time.min
			today.sec = 0
			target_time = os.time(today)

			-- If time has passed today, set for tomorrow
			if target_time <= now then
				target_time = target_time + 86400
			end
		else
			-- Try to parse as datetime
			local dt = datetime.parse_datetime(time_str)
			if dt then
				target_time = os.time(dt)
			else
				return nil, "Invalid time format"
			end
		end
	else
		return nil, "Time must be a string"
	end

	local duration_seconds = target_time - now
	if duration_seconds <= 0 then
		return nil, "Time is in the past"
	end

	-- Use timer with calculated duration
	options.title = options.title or "Alarm"
	options.message = options.message or string.format("Alarm '%s' at %s", name or time_str, time_str)

	return M.start(duration_seconds, name or "Alarm at " .. time_str, options)
end

-- Stop a timer
function M.stop(timer_id)
	local timer = active_timers[timer_id]
	if not timer then
		-- Try to find by name
		for id, t in pairs(active_timers) do
			if t.name == timer_id then
				timer = t
				timer_id = id
				break
			end
		end
		if not timer then
			return false, "Timer not found"
		end
	end

	if timer.handle then
		timer.handle:stop()
		timer.handle:close()
	end

	active_timers[timer_id] = nil

	manager.send_notification("Timer Stopped", string.format("Timer '%s' was stopped", timer.name), { type = "timer" })

	return true
end

-- List active timers
function M.list()
	local list = {}
	for id, timer in pairs(active_timers) do
		table.insert(list, {
			id = id,
			name = timer.name,
			remaining = timer.remaining,
			remaining_formatted = string.format("%02d:%02d", math.floor(timer.remaining / 60), timer.remaining % 60),
			duration = timer.duration,
			started_at = timer.started_at,
			progress = 1 - (timer.remaining / timer.duration),
		})
	end

	-- Sort by remaining time
	table.sort(list, function(a, b)
		return a.remaining < b.remaining
	end)

	return list
end

-- Get remaining time
function M.get_remaining(timer_id)
	local timer = active_timers[timer_id]
	if timer then
		return timer.remaining, timer.remaining_formatted
	end
	return nil
end

-- Setup
function M.setup(cfg)
	config = cfg or {}
	config.default_sound = config.default_sound or "default"
	config.allow_multiple = config.allow_multiple ~= false
	config.warnings = config.warnings or { 300, 60 } -- 5 min, 1 min warnings
end

-- Cleanup all timers
function M.cleanup()
	for id, timer in pairs(active_timers) do
		if timer.handle then
			timer.handle:stop()
			timer.handle:close()
		end
	end
	active_timers = {}
end

return M