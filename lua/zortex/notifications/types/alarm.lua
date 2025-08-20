-- notifications/types/alarm.lua - Comprehensive alarm implementation
local M = {}

local manager = require("zortex.notifications.manager")
local datetime = require("zortex.utils.datetime")
local store = require("zortex.stores.notifications")

local active_alarms = {}
local alarm_timers = {}
local cfg = {}

-- Alarm repeat modes
local REPEAT = {
	NONE = "none",
	DAILY = "daily",
	WEEKDAYS = "weekdays",
	WEEKENDS = "weekends",
	WEEKLY = "weekly",
	MONTHLY = "monthly",
	YEARLY = "yearly",
	CUSTOM = "custom", -- Custom days of week
}

-- Create alarm ID
local function create_alarm_id()
	return string.format("alarm_%s_%s", os.time(), math.random(10000))
end

-- Calculate next alarm time based on repeat mode
local function calculate_next_time(alarm_time, repeat_mode, custom_days)
	local now = os.time()
	local next_time = alarm_time

	-- If alarm time has passed, calculate next occurrence
	if next_time <= now then
		if repeat_mode == REPEAT.NONE then
			return nil -- One-time alarm that's passed
		elseif repeat_mode == REPEAT.DAILY then
			-- Add days until we're in the future
			while next_time <= now do
				next_time = next_time + 86400
			end
		elseif repeat_mode == REPEAT.WEEKDAYS then
			-- Find next weekday
			while next_time <= now do
				next_time = next_time + 86400
				local wday = os.date("*t", next_time).wday
				-- Skip Saturday (7) and Sunday (1)
				while wday == 1 or wday == 7 do
					next_time = next_time + 86400
					wday = os.date("*t", next_time).wday
				end
			end
		elseif repeat_mode == REPEAT.WEEKENDS then
			-- Find next weekend day
			while next_time <= now do
				next_time = next_time + 86400
				local wday = os.date("*t", next_time).wday
				-- Find Saturday (7) or Sunday (1)
				while wday ~= 1 and wday ~= 7 do
					next_time = next_time + 86400
					wday = os.date("*t", next_time).wday
				end
			end
		elseif repeat_mode == REPEAT.WEEKLY then
			-- Add weeks until we're in the future
			while next_time <= now do
				next_time = next_time + (7 * 86400)
			end
		elseif repeat_mode == REPEAT.MONTHLY then
			-- Add months
			local date = os.date("*t", next_time)
			while next_time <= now do
				date.month = date.month + 1
				if date.month > 12 then
					date.month = 1
					date.year = date.year + 1
				end
				-- Handle day overflow (e.g., Jan 31 -> Feb 31 doesn't exist)
				local max_day = datetime.get_days_in_month(date.year, date.month)
				if date.day > max_day then
					date.day = max_day
				end
				next_time = os.time(date)
			end
		elseif repeat_mode == REPEAT.YEARLY then
			-- Add years
			local date = os.date("*t", next_time)
			while next_time <= now do
				date.year = date.year + 1
				-- Handle Feb 29 on non-leap years
				if date.month == 2 and date.day == 29 and not datetime.is_leap_year(date.year) then
					date.day = 28
				end
				next_time = os.time(date)
			end
		elseif repeat_mode == REPEAT.CUSTOM and custom_days then
			-- Find next matching day of week
			while next_time <= now do
				next_time = next_time + 86400
				local wday = os.date("*t", next_time).wday
				-- Keep adding days until we find a matching day
				while not vim.tbl_contains(custom_days, wday) do
					next_time = next_time + 86400
					wday = os.date("*t", next_time).wday
				end
			end
		end
	end

	return next_time
end

-- Format alarm time for display
local function format_alarm_time(timestamp, include_date)
	local date = os.date("*t", timestamp)
	local time_str = string.format("%02d:%02d", date.hour, date.min)

	if include_date then
		local today = datetime.get_current_date()
		if datetime.is_same_day(date, today) then
			return "Today " .. time_str
		elseif datetime.is_same_day(date, datetime.add_days(today, 1)) then
			return "Tomorrow " .. time_str
		else
			return os.date("%b %d ", timestamp) .. time_str
		end
	end

	return time_str
end

-- Trigger alarm
local function trigger_alarm(alarm_id)
	local alarm = active_alarms[alarm_id]
	if not alarm then
		return
	end

	-- Send notification
	manager.send_notification(
		alarm.title or "Alarm",
		alarm.message or string.format("Alarm: %s", alarm.name or format_alarm_time(alarm.time, false)),
		{
			type = "alarm",
			sound = alarm.sound or cfg.default_sound,
			priority = alarm.priority or "urgent",
			actions = alarm.enable_snooze and {
				{
					label = "Snooze",
					action = function()
						M.snooze(alarm_id)
					end,
				},
				{
					label = "Dismiss",
					action = function()
						M.dismiss(alarm_id)
					end,
				},
			} or nil,
		}
	)

	-- Handle repeat or remove
	if alarm.repeat_mode ~= REPEAT.NONE then
		-- Calculate next occurrence
		local next_time = calculate_next_time(os.time() + 60, alarm.repeat_mode, alarm.custom_days)
		if next_time then
			alarm.time = next_time
			-- Reschedule timer
			schedule_alarm(alarm_id)
		else
			-- No next occurrence, remove alarm
			M.remove(alarm_id)
		end
	else
		-- One-time alarm, mark as triggered
		alarm.triggered = true
		if cfg.auto_remove_triggered then
			M.remove(alarm_id)
		end
	end

	-- Save state
	save_alarms()

	-- Execute callback if provided
	if alarm.callback then
		vim.schedule(alarm.callback)
	end
end

-- Schedule an alarm timer
function schedule_alarm(alarm_id)
	local alarm = active_alarms[alarm_id]
	if not alarm then
		return
	end

	-- Cancel existing timer if any
	if alarm_timers[alarm_id] then
		alarm_timers[alarm_id]:stop()
		alarm_timers[alarm_id]:close()
		alarm_timers[alarm_id] = nil
	end

	local now = os.time()
	local delay = (alarm.time - now) * 1000 -- Convert to milliseconds

	if delay > 0 then
		local timer = vim.loop.new_timer()
		timer:start(
			delay,
			0,
			vim.schedule_wrap(function()
				trigger_alarm(alarm_id)
			end)
		)
		alarm_timers[alarm_id] = timer
	elseif alarm.repeat_mode ~= REPEAT.NONE then
		-- Alarm time has passed but it's recurring, calculate next time
		local next_time = calculate_next_time(alarm.time, alarm.repeat_mode, alarm.custom_days)
		if next_time then
			alarm.time = next_time
			schedule_alarm(alarm_id)
		end
	end
end

-- Save alarms to persistent storage
function save_alarms()
	local alarms_data = {}
	for id, alarm in pairs(active_alarms) do
		if not alarm.triggered or alarm.repeat_mode ~= REPEAT.NONE then
			table.insert(alarms_data, {
				id = id,
				name = alarm.name,
				time = alarm.time,
				repeat_mode = alarm.repeat_mode,
				custom_days = alarm.custom_days,
				title = alarm.title,
				message = alarm.message,
				sound = alarm.sound,
				priority = alarm.priority,
				enable_snooze = alarm.enable_snooze,
				snooze_duration = alarm.snooze_duration,
				created_at = alarm.created_at,
			})
		end
	end
	store.save_alarms(alarms_data)
end

-- Load alarms from persistent storage
function load_alarms()
	local alarms_data = store.get_alarms() or {}
	for _, alarm_data in ipairs(alarms_data) do
		active_alarms[alarm_data.id] = alarm_data
		schedule_alarm(alarm_data.id)
	end
end

-- Set an alarm
function M.set(time_input, name, options)
	options = options or {}

	local alarm_time
	local now = os.time()

	-- Parse time input
	if type(time_input) == "string" then
		-- Try to parse as datetime first
		local dt = datetime.parse_datetime(time_input)
		if dt then
			alarm_time = os.time(dt)
		else
			-- Try to parse as time only
			local time = datetime.parse_time(time_input)
			if time then
				local today = os.date("*t")
				today.hour = time.hour
				today.min = time.min
				today.sec = 0
				alarm_time = os.time(today)

				-- If time has passed today, set for tomorrow
				if alarm_time <= now and not options.repeat_mode then
					alarm_time = alarm_time + 86400
				end
			else
				-- Try to parse as duration (e.g., "30m", "2h")
				local duration_mins = datetime.parse_duration(time_input)
				if duration_mins then
					alarm_time = now + (duration_mins * 60)
				else
					return nil, "Invalid time format"
				end
			end
		end
	elseif type(time_input) == "number" then
		-- Assume it's a timestamp
		alarm_time = time_input
	elseif type(time_input) == "table" then
		-- Assume it's a date table
		alarm_time = os.time(time_input)
	else
		return nil, "Invalid time input"
	end

	-- Validate repeat mode
	local repeat_mode = options.repeat_mode or REPEAT.NONE
	if repeat_mode ~= REPEAT.NONE and not vim.tbl_contains(vim.tbl_keys(REPEAT), repeat_mode:upper()) then
		return nil, "Invalid repeat mode"
	end

	-- Calculate next occurrence if recurring and time has passed
	if repeat_mode ~= REPEAT.NONE and alarm_time <= now then
		alarm_time = calculate_next_time(alarm_time, repeat_mode, options.custom_days)
		if not alarm_time then
			return nil, "Cannot calculate next occurrence"
		end
	end

	-- Create alarm
	local alarm_id = create_alarm_id()
	local alarm = {
		id = alarm_id,
		name = name or format_alarm_time(alarm_time, true),
		time = alarm_time,
		repeat_mode = repeat_mode,
		custom_days = options.custom_days,
		title = options.title,
		message = options.message,
		sound = options.sound,
		priority = options.priority,
		enable_snooze = options.enable_snooze ~= false,
		snooze_duration = options.snooze_duration or cfg.default_snooze_duration,
		callback = options.callback,
		created_at = os.time(),
		triggered = false,
	}

	active_alarms[alarm_id] = alarm
	schedule_alarm(alarm_id)
	save_alarms()

	-- Send confirmation notification
	local when_str = format_alarm_time(alarm_time, true)
	local repeat_str = repeat_mode ~= REPEAT.NONE and string.format(" (repeats %s)", repeat_mode:lower()) or ""
	manager.send_notification(
		"Alarm Set",
		string.format("Alarm '%s' set for %s%s", alarm.name, when_str, repeat_str),
		{ type = "alarm" }
	)

	return alarm_id
end

-- Remove an alarm
function M.remove(alarm_id)
	local alarm = active_alarms[alarm_id]
	if not alarm then
		-- Try to find by name
		for id, a in pairs(active_alarms) do
			if a.name == alarm_id then
				alarm = a
				alarm_id = id
				break
			end
		end
		if not alarm then
			return false, "Alarm not found"
		end
	end

	-- Cancel timer
	if alarm_timers[alarm_id] then
		alarm_timers[alarm_id]:stop()
		alarm_timers[alarm_id]:close()
		alarm_timers[alarm_id] = nil
	end

	active_alarms[alarm_id] = nil
	save_alarms()

	manager.send_notification(
		"Alarm Removed",
		string.format("Alarm '%s' has been removed", alarm.name),
		{ type = "alarm" }
	)

	return true
end

-- Snooze an alarm
function M.snooze(alarm_id, duration)
	local alarm = active_alarms[alarm_id]
	if not alarm then
		return false, "Alarm not found"
	end

	duration = duration or alarm.snooze_duration or cfg.default_snooze_duration

	-- Set new time
	alarm.time = os.time() + (duration * 60)
	alarm.snoozed = true
	alarm.snooze_count = (alarm.snooze_count or 0) + 1

	-- Reschedule
	schedule_alarm(alarm_id)
	save_alarms()

	manager.send_notification(
		"Alarm Snoozed",
		string.format("Alarm '%s' snoozed for %d minutes", alarm.name, duration),
		{ type = "alarm" }
	)

	return true
end

-- Dismiss an alarm (for recurring alarms)
function M.dismiss(alarm_id)
	local alarm = active_alarms[alarm_id]
	if not alarm then
		return false, "Alarm not found"
	end

	if alarm.repeat_mode == REPEAT.NONE then
		-- One-time alarm, remove it
		return M.remove(alarm_id)
	else
		-- Recurring alarm, just dismiss this instance
		-- Next occurrence is already scheduled by trigger_alarm
		manager.send_notification(
			"Alarm Dismissed",
			string.format("Alarm '%s' dismissed", alarm.name),
			{ type = "alarm" }
		)
		return true
	end
end

-- List all alarms
function M.list()
	local list = {}
	for id, alarm in pairs(active_alarms) do
		local time_until = alarm.time - os.time()
		table.insert(list, {
			id = id,
			name = alarm.name,
			time = alarm.time,
			time_formatted = format_alarm_time(alarm.time, true),
			repeat_mode = alarm.repeat_mode,
			time_until = time_until,
			time_until_formatted = time_until > 0 and datetime.format_duration(time_until) or "Passed",
			enabled = not alarm.triggered,
			snoozed = alarm.snoozed,
			snooze_count = alarm.snooze_count or 0,
		})
	end

	-- Sort by time
	table.sort(list, function(a, b)
		return a.time < b.time
	end)

	return list
end

-- Get alarm details
function M.get(alarm_id)
	return active_alarms[alarm_id]
end

-- Edit an existing alarm
function M.edit(alarm_id, updates)
	local alarm = active_alarms[alarm_id]
	if not alarm then
		return false, "Alarm not found"
	end

	-- Update fields
	if updates.name then
		alarm.name = updates.name
	end
	if updates.title then
		alarm.title = updates.title
	end
	if updates.message then
		alarm.message = updates.message
	end
	if updates.sound then
		alarm.sound = updates.sound
	end
	if updates.priority then
		alarm.priority = updates.priority
	end
	if updates.enable_snooze ~= nil then
		alarm.enable_snooze = updates.enable_snooze
	end
	if updates.snooze_duration then
		alarm.snooze_duration = updates.snooze_duration
	end

	-- Handle time changes
	if updates.time then
		local new_time
		if type(updates.time) == "string" then
			local dt = datetime.parse_datetime(updates.time)
			if dt then
				new_time = os.time(dt)
			else
				local time = datetime.parse_time(updates.time)
				if time then
					local date = os.date("*t", alarm.time)
					date.hour = time.hour
					date.min = time.min
					new_time = os.time(date)
				end
			end
		elseif type(updates.time) == "number" then
			new_time = updates.time
		end

		if new_time then
			alarm.time = new_time
			schedule_alarm(alarm_id)
		end
	end

	-- Handle repeat mode changes
	if updates.repeat_mode then
		alarm.repeat_mode = updates.repeat_mode
		if updates.custom_days then
			alarm.custom_days = updates.custom_days
		end
		schedule_alarm(alarm_id)
	end

	save_alarms()

	manager.send_notification(
		"Alarm Updated",
		string.format("Alarm '%s' has been updated", alarm.name),
		{ type = "alarm" }
	)

	return true
end

-- Quick alarm presets
function M.quick_alarm(preset, name)
	local presets = {
		morning = { time = "07:00", repeat_mode = REPEAT.DAILY },
		workday = { time = "09:00", repeat_mode = REPEAT.WEEKDAYS },
		lunch = { time = "12:00", repeat_mode = REPEAT.WEEKDAYS },
		evening = { time = "18:00", repeat_mode = REPEAT.DAILY },
		bedtime = { time = "22:00", repeat_mode = REPEAT.DAILY },
	}

	local preset_config = presets[preset:lower()]
	if not preset_config then
		return nil, "Unknown preset: " .. preset
	end

	return M.set(
		preset_config.time,
		name or preset:gsub("^%l", string.upper) .. " Alarm",
		{ repeat_mode = preset_config.repeat_mode }
	)
end

-- Setup
function M.setup(cfg)
	cfg = opts

	-- Load saved alarms
	load_alarms()
end

-- Cleanup
function M.cleanup()
	for id, timer in pairs(alarm_timers) do
		if timer then
			timer:stop()
			timer:close()
		end
	end
	alarm_timers = {}
	save_alarms()
end

return M
