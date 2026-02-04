-- notifications/types/calendar.lua - Calendar sync using unified scheduler
local M = {}

local manager = require("zortex.notifications.manager")
local datetime = require("zortex.utils.datetime")
local calendar_store = require("zortex.stores.calendar")
local Logger = require("zortex.core.logger")
local Config = require("zortex.config")

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
	local notifications_to_sync = {}
	local scheduled_count = 0

	local function create_notification(entry, notify_values, date_str, notification_time, event_type)
		local date_parts = datetime.parse_date(date_str)
		local full_time = vim.tbl_extend("force", {}, date_parts, notification_time)

		-- Ensure we have a valid table for os.time (requires year, month, day, hour, min)
		if not full_time.year or not full_time.hour then
			return
		end

		local notification_timestamp = os.time(full_time)

		for _, advance_minutes in ipairs(notify_values) do
			local trigger_time = notification_timestamp - (advance_minutes * 60)

			-- Only schedule future notifications
			if trigger_time > now then
				local dedup_key = create_dedup_key(entry, date_str, event_type, advance_minutes)
				local minutes_until = math.floor((notification_timestamp - trigger_time) / 60)
				local title, message = format_notification(entry, event_type, minutes_until)

				local notification = {
					title = title,
					message = message,
					trigger_time = trigger_time,
					scheduled_time = trigger_time, -- For homelab server
					type = "calendar",
					priority = entry.attributes.p and ("p" .. entry.attributes.p) or "default",
					tags = { "calendar", event_type },
					entry_id = entry.display_text,
					deduplication_key = dedup_key,
					entry_text = entry.display_text,
				}

				table.insert(notifications_to_sync, notification)
				scheduled_count = scheduled_count + 1
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

	-- Sync with homelab server if enabled, otherwise use local manager
	local server_config = Config.server
	if server_config and server_config.enabled then
		-- Use homelab provider's sync function
		local homelab_provider = require("zortex.notifications.providers.homelab")
		local success, err = homelab_provider.sync(notifications_to_sync, server_config)

		if success then
			Logger.info("calendar", "Synced " .. scheduled_count .. " notifications to homelab server")

			-- Send local confirmation
			manager.send_notification(
				"Calendar Sync Complete",
				string.format("Synced %d calendar notifications to server", scheduled_count),
				{ type = "calendar", channels = { "vim" } }
			)
		else
			Logger.error("calendar", "Failed to sync to homelab: " .. (err or "unknown error"))

			-- Fallback to local scheduling
			Logger.info("calendar", "Falling back to local scheduling")
			M.sync_local(notifications_to_sync)
		end
	else
		-- Use local manager scheduling
		M.sync_local(notifications_to_sync)
	end

	return scheduled_count
end

-- Local sync using manager (fallback)
function M.sync_local(notifications)
	local scheduled_count = 0

	for _, notification in ipairs(notifications) do
		-- Convert to manager format
		local manager_notification = {
			title = notification.title,
			message = notification.message,
			trigger_time = notification.trigger_time,
			type = "calendar",
			options = {
				priority = notification.priority,
				sound = notification.sound,
				deduplication_key = notification.deduplication_key,
				event_type = notification.event_type,
				entry_text = notification.entry_text,
				tags = notification.tags,
			},
		}

		local id = manager.schedule_notification(manager_notification)
		if id then
			scheduled_count = scheduled_count + 1
		end
	end

	if scheduled_count > 0 then
		Logger.info("calendar", "Scheduled " .. scheduled_count .. " notifications locally")
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
