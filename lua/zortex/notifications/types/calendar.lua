-- notifications/types/calendar.lua - Calendar notification handler
local M = {}

local manager = require("zortex.notifications.manager")
local calendar = require("zortex.features.calendar")
local datetime = require("zortex.utils.datetime")
local store = require("zortex.stores.notifications")

local cfg = {}
local sent_notifications = {}

-- Create notification ID for deduplication
local function create_notification_id(entry, date_str)
	local parts = {
		date_str,
		entry.attributes.at or "allday",
		entry.display_text:sub(1, 20),
	}
	return table.concat(parts, "_"):gsub("%s+", "_"):gsub("[^%w_-]", "")
end

-- Parse notify attribute value
local function parse_notify_value(notify_attr)
	if not notify_attr then
		return cfg.default_advance_minutes or 15
	end

	if type(notify_attr) == "boolean" then
		return cfg.default_advance_minutes or 15
	elseif type(notify_attr) == "number" then
		return notify_attr
	elseif type(notify_attr) == "string" then
		local minutes = datetime.parse_duration(notify_attr)
		return minutes or cfg.default_advance_minutes or 15
	elseif type(notify_attr) == "table" then
		-- Support multiple notification times
		local times = {}
		for _, v in ipairs(notify_attr) do
			local minutes = parse_notify_value(v)
			if minutes then
				table.insert(times, minutes)
			end
		end
		return times
	end

	return cfg.default_advance_minutes or 15
end

-- Format notification message
local function format_notification_message(entry, minutes_until)
	local time_str = ""
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

	local message = calendar.format_entry(entry)
	return message, time_str
end

-- Convert entry to notification format
local function entry_to_notification(entry, date_str, notify_minutes)
	local event_datetime = datetime.parse_date(date_str)
	if not event_datetime then
		return nil
	end

	-- Set default time
	event_datetime.hour = 9
	event_datetime.min = 0
	event_datetime.sec = 0

	-- Parse event time if specified
	if entry.attributes.at then
		local time = datetime.parse_time(entry.attributes.at)
		if time then
			event_datetime.hour = time.hour
			event_datetime.min = time.min
		end
	end

	local event_time = os.time(event_datetime)
	local notify_time = event_time - (notify_minutes * 60)

	return {
		id = create_notification_id(entry, date_str),
		title = entry.display_text,
		message = calendar.format_entry(entry),
		event_time = event_time,
		notify_time = notify_time,
		notify_minutes = notify_minutes,
		entry = entry,
		date_str = date_str,
		priority = entry.attributes.p and ("p" .. entry.attributes.p) or "default",
		tags = { "calendar", entry.type or "event" },
	}
end

-- Check and send due notifications
function M.check_and_notify()
	local now = os.time()
	local sent_count = 0
	local today = datetime.get_current_date()
	local did_send = false

	-- Check next 2 days
	for day_offset = 0, 1 do
		local check_date = datetime.add_days(today, day_offset)
		local date_str = datetime.format_date(check_date, "YYYY-MM-DD")
		local entries = calendar.get_entries_for_date(date_str)

		for _, entry in ipairs(entries) do
			if entry.attributes.notify then
				local notify_values = parse_notify_value(entry.attributes.notify)
				if type(notify_values) ~= "table" then
					notify_values = { notify_values }
				end

				for _, notify_minutes in ipairs(notify_values) do
					local notification = entry_to_notification(entry, date_str, notify_minutes)
					if notification then
						local notif_id = notification.id .. "_" .. notify_minutes

						-- Check if notification is due and not already sent
						if
							notification.notify_time <= now
							and notification.event_time > now
							and not sent_notifications[notif_id]
						then
							local minutes_until = math.floor((notification.event_time - now) / 60)
							local message, time_str = format_notification_message(entry, minutes_until)
							local title = "Calendar Reminder - " .. time_str

							-- Send notification
							manager.send_notification(title, message, {
								type = "calendar",
								priority = notification.priority,
								tags = notification.tags,
								sound = entry.attributes.sound,
							})

							-- Mark as sent
							sent_notifications[notif_id] = {
								sent_at = now,
								event_time = notification.event_time,
							}
							sent_count = sent_count + 1
							did_send = true
						end
					end
				end
			end
		end
	end

	if did_send then
		store.save_calendar_sent(sent_notifications)
	end

	-- Clean old sent notifications
	M.clean_old_notifications()

	return sent_count
end

-- Sync notifications to external services
function M.sync()
	-- Load calendar data
	calendar.load()

	local notifications = {}
	local today = datetime.get_current_date()
	local scan_days = cfg.sync_days or 365

	-- Scan future dates
	for day_offset = 0, scan_days do
		local check_date = datetime.add_days(today, day_offset)
		local date_str = datetime.format_date(check_date, "YYYY-MM-DD")
		local entries = calendar.get_entries_for_date(date_str)

		for _, entry in ipairs(entries) do
			if entry.attributes.notify then
				local notify_values = parse_notify_value(entry.attributes.notify)
				if type(notify_values) ~= "table" then
					notify_values = { notify_values }
				end

				for _, notify_minutes in ipairs(notify_values) do
					local notification = entry_to_notification(entry, date_str, notify_minutes)
					if notification then
						table.insert(notifications, notification)
					end
				end
			end
		end
	end

	-- Send to AWS if enabled
	local aws = cfg.providers and cfg.providers.aws
	if aws and aws.enabled and aws.sync then
		local aws_provider = require("zortex.notifications.providers.aws")
		local success = aws_provider.sync(notifications, aws)
		if success then
			vim.notify(
				string.format("Synced %d calendar notifications", #notifications),
				vim.log.levels.INFO,
				{ title = "Calendar Sync" }
			)
		end
	else
		-- Just show local summary
		vim.notify(
			string.format("Found %d upcoming calendar notifications", #notifications),
			vim.log.levels.INFO,
			{ title = "Calendar Sync" }
		)
	end

	return notifications
end

-- Clean old sent notifications
function M.clean_old_notifications()
	local now = os.time()
	local cutoff = now - (48 * 60 * 60) -- 48 hours
	local did_clean = false

	for id, notif in pairs(sent_notifications) do
		if notif.sent_at < cutoff then
			sent_notifications[id] = nil
			did_clean = true
		end
	end

	if did_clean then
		store.save_calendar_sent(sent_notifications)
	end
end

-- Get pending notifications for a date
function M.get_pending_for_date(date_str)
	local entries = require("zortex.stores.calendar").get_entries_for_date(date_str)
	local pending = {}

	for _, entry in ipairs(entries) do
		if entry.attributes.notify then
			local notify_values = parse_notify_value(entry.attributes.notify)
			if type(notify_values) ~= "table" then
				notify_values = { notify_values }
			end

			for _, notify_minutes in ipairs(notify_values) do
				local notification = entry_to_notification(entry, date_str, notify_minutes)
				if notification then
					table.insert(pending, {
						time = os.date("%H:%M", notification.notify_time),
						title = notification.title,
						advance_minutes = notify_minutes,
					})
				end
			end
		end
	end

	return pending
end

-- Setup
function M.setup(config)
	cfg = config

	-- Load sent notifications from state
	sent_notifications = store.get_calendar_sent()
end

return M
