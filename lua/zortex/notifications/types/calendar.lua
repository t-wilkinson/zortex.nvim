-- notifications/types/calendar.lua - Calendar sync using unified scheduler
local M = {}

local manager = require("zortex.notifications.manager")
local datetime = require("zortex.utils.datetime")
local calendar_store = require("zortex.stores.calendar")
local Logger = require("zortex.core.logger")

local cfg = {}

-- Parse notify attribute value
local function parse_notify_value(notify_attr)
	if type(notify_attr) == "string" and notify_attr == "no" then
		return nil
	elseif type(notify_attr) == "table" then
		return notify_attr
	else
		return { cfg.default_advance_minutes }
	end
end

-- Create a deduplication key for a calendar notification
local function create_dedup_key(entry, date_str, event_type, advance_minutes)
	-- Include all relevant parts to make it unique
	local text_part = entry.display_text:sub(1, 20):gsub("%s+", "_"):gsub("[^%w_-]", "")
	return string.format(
		"cal_%s_%s_%s_%d",
		date_str,
		text_part,
		event_type, -- "start" or "end"
		advance_minutes
	)
end

-- Format notification message based on event type
local function format_notification(entry, event_type, minutes_until)
	local time_str
	if minutes_until <= 0 then
		time_str = "now"
	elseif minutes_until == 1 then
		time_str = "in 1 minute"
	elseif minutes_until < 60 then
		time_str = string.format("in %d minutes", minutes_until)
	elseif minutes_until == 60 then
		time_str = "in 1 hour"
	elseif minutes_until < 120 then
		time_str = string.format("in 1 hour %d minutes", minutes_until - 60)
	else
		time_str = string.format("in %d hours", math.floor(minutes_until / 60))
	end

	local verb = event_type == "end" and "ending" or "starting"
	local title = string.format("Calendar: %s %s %s", entry.display_text, verb, time_str)
	local message = entry:format()

	return title, message
end

-- Sync calendar notifications
function M.sync()
	-- Load calendar data
	calendar_store.load()

	local today = datetime.get_current_date()
	local scan_days = cfg.sync_days
	local now = os.time()
	local scheduled_count = 0

	local function create_notification(entry, notify_values, date_str, notification_time, event_type)
		local notification_timestamp = os.time(notification_time)

		for _, advance_minutes in ipairs(notify_values) do
			local trigger_time = notification_timestamp - (advance_minutes * 60)

			-- Only schedule future notifications
			if trigger_time > now then
				local dedup_key = create_dedup_key(entry, date_str, event_type, advance_minutes)
				local minutes_until = math.floor((notification_timestamp - now) / 60)
				local title, message = format_notification(entry, event_type, minutes_until)

				local notification = {
					title = title,
					message = message,
					trigger_time = trigger_time,
					type = "calendar",
					options = {
						priority = entry.attributes.p and ("p" .. entry.attributes.p) or "normal",
						sound = entry.attributes.sound,
						deduplication_key = dedup_key,
						event_type = event_type,
						entry_text = entry.display_text,
					},
				}

				local id = manager.schedule_notification(notification)
				if id then
					scheduled_count = scheduled_count + 1
				end
			end
		end
	end

	-- Scan future dates
	for day_offset = 0, scan_days do
		local check_date = datetime.add_days(today, day_offset)
		local date_str = datetime.format_datetime(check_date, "YYYY-MM-DD")
		local entries = calendar_store.get_entries_for_date(date_str)

		for _, entry in ipairs(entries) do
			local start_time = entry:get_start_time()
			local end_time = entry:get_end_time()
			local notify_values = parse_notify_value(entry.attributes.notify)

			if notify_values then
				-- Process START time notifications
				if start_time then
					create_notification(entry, notify_values, date_str, start_time, "start")
				end

				-- Process END time notifications (if different from start)
				if end_time and (not start_time or os.time(end_time) ~= os.time(start_time)) then
					create_notification(entry, notify_values, date_str, end_time, "end")
				end
			end
		end
	end

	-- Send confirmation if notifications were scheduled
	if scheduled_count > 0 then
		Logger.info("calendar", "syncheduled " .. scheduled_count .. " notifications")
		manager.send_notification(
			"Calendar Sync Complete",
			string.format("Scheduled %d calendar notifications", scheduled_count),
			{ type = "calendar", channels = { "vim" } }
		)
	end

	return scheduled_count
end

-- Get pending notifications for a specific date
function M.get_pending_for_date(date_str)
	local entries = calendar_store.get_entries_for_date(date_str)
	local pending = {}

	for _, entry in ipairs(entries) do
		local notify_values = parse_notify_value(entry.attributes.notify)

		if notify_values then
			-- Check start time
			local start_time = entry:get_start_time()
			if start_time then
				for _, advance_minutes in ipairs(notify_values) do
					table.insert(pending, {
						time = os.date("%H:%M", os.time(start_time) - (advance_minutes * 60)),
						title = entry.display_text,
						advance_minutes = advance_minutes,
						type = "start",
					})
				end
			end

			-- Check end time
			local end_time = entry:get_end_time()
			if end_time and (not start_time or os.time(end_time) ~= os.time(start_time)) then
				for _, advance_minutes in ipairs(notify_values) do
					table.insert(pending, {
						time = os.date("%H:%M", os.time(end_time) - (advance_minutes * 60)),
						title = entry.display_text,
						advance_minutes = advance_minutes,
						type = "end",
					})
				end
			end
		end
	end

	-- Sort by time
	table.sort(pending, function(a, b)
		return a.time < b.time
	end)

	return pending
end

-- Setup
function M.setup(opts)
	cfg = opts

	-- Perform initial calendar sync
	vim.defer_fn(function()
		M.sync()
	end, 100)
end

return M
