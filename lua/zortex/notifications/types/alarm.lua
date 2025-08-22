-- notifications/types/alarm.lua - Simplified alarm using unified scheduler
local M = {}

local manager = require("zortex.notifications.manager")
local datetime = require("zortex.utils.datetime")

local cfg = {}

-- Parse alarm time input
local function parse_alarm_time(time_input, repeat_mode)
	local alarm_time
	local now = os.time()

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

				-- If time has passed today and not repeating, set for tomorrow
				if alarm_time <= now and not repeat_mode then
					alarm_time = alarm_time + 86400
				end
			else
				-- Try to parse as duration (e.g., "30m", "2h")
				local duration_mins = datetime.parse_duration(time_input)
				if duration_mins then
					alarm_time = now + (duration_mins * 60)
				else
					return nil
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
		return nil
	end

	return alarm_time
end

-- Format alarm time for display
local function format_alarm_time(timestamp)
	local date = os.date("*t", timestamp)
	local today = datetime.get_current_date()

	if datetime.is_same_day(date, today) then
		return string.format("Today %02d:%02d", date.hour, date.min)
	elseif datetime.is_same_day(date, datetime.add_days(today, 1)) then
		return string.format("Tomorrow %02d:%02d", date.hour, date.min)
	else
		return os.date("%b %d %H:%M", timestamp)
	end
end

-- Set an alarm
function M.set(time_input, name, options)
	options = options or {}

	-- Parse time input
	local trigger_time = parse_alarm_time(time_input, options.repeat_mode)
	if not trigger_time then
		return nil, "Invalid time format"
	end

	local alarm_id = "alarm_" .. os.time() .. "_" .. math.random(10000)
	name = name or format_alarm_time(trigger_time)

	-- Create notification object
	local notification = {
		id = alarm_id,
		title = options.title or "Alarm",
		message = options.message or string.format("Alarm: %s", name),
		trigger_time = trigger_time,
		type = "alarm",
		channels = options.channels, -- Uses default alarm channels if nil
		options = {
			repeat_mode = options.repeat_mode,
			repeat_interval = options.repeat_interval,
			custom_days = options.custom_days,
			priority = options.priority or "urgent",
			sound = options.sound or cfg.default_sound,
			enable_snooze = options.enable_snooze ~= false,
			snooze_duration = options.snooze_duration or cfg.default_snooze_duration,
			deduplication_key = nil, -- Alarms don't deduplicate
		},
		source = {
			type = "alarm",
			data = {
				name = name,
				original_options = options,
			},
		},
	}

	-- Schedule it
	local id = manager.schedule_notification(notification)

	if id then
		-- Send confirmation
		manager.send_notification(
			"Alarm Set",
			string.format("Alarm '%s' set for %s", name, format_alarm_time(trigger_time)),
			{ type = "alarm", channels = { "vim" } }
		)
	end

	return id
end

-- Remove an alarm
function M.remove(alarm_id)
	-- Try to find by ID first
	if manager.cancel_notification(alarm_id) then
		manager.send_notification("Alarm Removed", "Alarm has been removed", { type = "alarm", channels = { "vim" } })
		return true
	end

	-- Try to find by name
	local alarms = M.list()
	for _, alarm in ipairs(alarms) do
		if alarm.source and alarm.source.data and alarm.source.data.name == alarm_id then
			if manager.cancel_notification(alarm.id) then
				manager.send_notification(
					"Alarm Removed",
					string.format("Alarm '%s' has been removed", alarm.source.data.name),
					{ type = "alarm", channels = { "vim" } }
				)
				return true
			end
		end
	end

	return false, "Alarm not found"
end

-- Snooze an alarm
function M.snooze(alarm_id, minutes)
	minutes = minutes or cfg.default_snooze_duration or 10

	local alarms = M.list()
	for _, alarm in ipairs(alarms) do
		if alarm.id == alarm_id or (alarm.source and alarm.source.data and alarm.source.data.name == alarm_id) then
			-- Cancel current alarm
			manager.cancel_notification(alarm.id)

			-- Reschedule with new time
			alarm.trigger_time = os.time() + (minutes * 60)
			alarm.id = nil -- Get a new ID
			manager.schedule_notification(alarm)

			manager.send_notification(
				"Alarm Snoozed",
				string.format("Alarm snoozed for %d minutes", minutes),
				{ type = "alarm", channels = { "vim" } }
			)
			return true
		end
	end

	return false, "Alarm not found"
end

-- Dismiss an alarm
function M.dismiss(alarm_id)
	local alarms = M.list()
	for _, alarm in ipairs(alarms) do
		if alarm.id == alarm_id or (alarm.source and alarm.source.data and alarm.source.data.name == alarm_id) then
			if alarm.options and alarm.options.repeat_mode and alarm.options.repeat_mode ~= "none" then
				-- For recurring alarms, just acknowledge dismissal
				manager.send_notification(
					"Alarm Dismissed",
					"Alarm dismissed. Next occurrence will trigger as scheduled.",
					{ type = "alarm", channels = { "vim" } }
				)
				return true
			else
				-- For one-time alarms, remove it
				return M.remove(alarm.id)
			end
		end
	end

	return false, "Alarm not found"
end

-- List all alarms
function M.list()
	local alarms = manager.list_scheduled({ type = "alarm" })

	-- Enhance with display info
	for _, alarm in ipairs(alarms) do
		local time_until = alarm.trigger_time - os.time()
		alarm.time_formatted = format_alarm_time(alarm.trigger_time)
		alarm.time_until = time_until
		alarm.time_until_formatted = time_until > 0 and datetime.format_duration(time_until / 60) or "Passed"

		if alarm.source and alarm.source.data then
			alarm.name = alarm.source.data.name
		end

		alarm.repeat_mode = alarm.options and alarm.options.repeat_mode or "none"
		alarm.snoozed = false -- Could track this in source data if needed
	end

	return alarms
end

-- Get alarm details
function M.get(alarm_id)
	local alarms = M.list()
	for _, alarm in ipairs(alarms) do
		if alarm.id == alarm_id or (alarm.name and alarm.name == alarm_id) then
			return alarm
		end
	end
	return nil
end

-- Edit an existing alarm
function M.edit(alarm_id, updates)
	local alarms = M.list()

	for _, alarm in ipairs(alarms) do
		if alarm.id == alarm_id or (alarm.source and alarm.source.data and alarm.source.data.name == alarm_id) then
			-- Cancel current alarm
			manager.cancel_notification(alarm.id)

			-- Update fields
			if updates.name and alarm.source and alarm.source.data then
				alarm.source.data.name = updates.name
			end
			if updates.title then
				alarm.title = updates.title
			end
			if updates.message then
				alarm.message = updates.message
			end
			if updates.sound and alarm.options then
				alarm.options.sound = updates.sound
			end
			if updates.priority and alarm.options then
				alarm.options.priority = updates.priority
			end
			if updates.repeat_mode and alarm.options then
				alarm.options.repeat_mode = updates.repeat_mode
			end

			-- Handle time changes
			if updates.time then
				local new_time = parse_alarm_time(updates.time, alarm.options and alarm.options.repeat_mode)
				if new_time then
					alarm.trigger_time = new_time
				end
			end

			-- Reschedule with updates
			alarm.id = nil -- Get a new ID
			manager.schedule_notification(alarm)

			manager.send_notification(
				"Alarm Updated",
				string.format("Alarm has been updated"),
				{ type = "alarm", channels = { "vim" } }
			)

			return true
		end
	end

	return false, "Alarm not found"
end

-- Quick alarm presets
function M.quick_alarm(preset, name)
	local presets = {
		morning = { time = "07:00", repeat_mode = "daily" },
		workday = { time = "09:00", repeat_mode = "weekdays" },
		lunch = { time = "12:00", repeat_mode = "weekdays" },
		evening = { time = "18:00", repeat_mode = "daily" },
		bedtime = { time = "22:00", repeat_mode = "daily" },
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
function M.setup(opts)
	cfg = opts or {}
	cfg.default_sound = cfg.default_sound or "default"
	cfg.default_snooze_duration = cfg.default_snooze_duration or 10
	cfg.auto_remove_triggered = cfg.auto_remove_triggered ~= false
end

-- Cleanup
function M.cleanup()
	-- All cleanup is handled by manager
end

return M
