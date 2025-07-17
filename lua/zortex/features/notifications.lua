-- modules/notifications.lua - Notification system for Zortex calendar
local M = {}

local fs = require("zortex.core.filesystem")
local calendar = require("zortex.modules.calendar")
local datetime = require("zortex.core.datetime")

-- =============================================================================
-- Configuration
-- =============================================================================

local cfg = {}

-- =============================================================================
-- State Management
-- =============================================================================

local state = {
	pending = {}, -- Pending notifications
	sent = {}, -- Sent notifications (to avoid duplicates)
	last_check = nil,
}

-- =============================================================================
-- System Detection
-- =============================================================================

local function get_os()
	local handle = io.popen("uname -s")
	if handle then
		local result = handle:read("*a"):gsub("%s+", "")
		handle:close()

		if result == "Darwin" then
			return "macos"
		elseif result == "Linux" then
			-- Check if running in Termux
			if os.getenv("PREFIX") and os.getenv("PREFIX"):match("termux") then
				return "termux"
			end
			return "linux"
		end
	end
	return "unknown"
end

local function send_system_notification(title, message)
	if not cfg.enable_system_notifications then
		return false
	end

	local os_type = get_os()
	local cmd_template = cfg.commands[os_type]

	if not cmd_template then
		return false
	end

	-- Escape quotes in title and message
	title = title:gsub("'", "'\"'\"'")
	message = message:gsub("'", "'\"'\"'")

	local cmd = string.format(cmd_template, title, message)
	local success = os.execute(cmd)

	return success == 0
end

local function send_ntfy_notification(title, message, options)
	if not cfg.ntfy.enabled then
		return false
	end

	options = options or {}
	local priority = options.priority or cfg.ntfy.priority
	local tags = options.tags or cfg.ntfy.tags
	local click_url = options.click_url or nil

	-- Build curl command
	local cmd_parts = {
		"curl",
		"-s", -- silent
		"-X",
		"POST",
		"-H",
		string.format('"Title: %s"', title:gsub('"', '\\"')),
		"-H",
		string.format('"Priority: %s"', priority),
	}

	-- Add tags
	if tags and #tags > 0 then
		table.insert(cmd_parts, "-H")
		table.insert(cmd_parts, string.format('"Tags: %s"', table.concat(tags, ",")))
	end

	-- Add click URL if provided
	if click_url then
		table.insert(cmd_parts, "-H")
		table.insert(cmd_parts, string.format('"Click: %s"', click_url))
	end

	-- Add auth token if configured
	if cfg.ntfy.auth_token then
		table.insert(cmd_parts, "-H")
		table.insert(cmd_parts, string.format('"Authorization: Bearer %s"', cfg.ntfy.auth_token))
	end

	-- Add message data
	table.insert(cmd_parts, "-d")
	table.insert(cmd_parts, string.format('"%s"', message:gsub('"', '\\"')))

	-- Add server URL and topic
	table.insert(cmd_parts, string.format('"%s/%s"', cfg.ntfy.server_url, cfg.ntfy.topic))

	local cmd = table.concat(cmd_parts, " ")
	local handle = io.popen(cmd .. " 2>&1")
	if handle then
		local result = handle:read("*a")
		local success = handle:close()

		if not success then
			vim.notify("ntfy error: " .. result, vim.log.levels.ERROR)
			return false
		end
		return true
	end

	return false
end

-- AWS Integration Functions
local function send_manifest_to_server(operation, data)
	local aws_config = cfg.aws
	if not aws_config.enabled or not aws_config.api_endpoint or not aws_config.user_id then
		return false
	end

	local manifest = {
		user_id = aws_config.user_id,
		operation = operation,
	}

	if operation == "sync" then
		manifest.notifications = data
	elseif operation == "add" or operation == "update" then
		manifest.notification = data
	elseif operation == "remove" then
		manifest.entry_id = data
	elseif operation == "test" then
		manifest.notification = data
	end

	local json_data = vim.fn.json_encode(manifest)
	local cmd = string.format(
		'curl -s -X POST -H "Content-Type: application/json" -H "Accept: application/json" -d %s %s',
		vim.fn.shellescape(json_data),
		vim.fn.shellescape(aws_config.api_endpoint)
	)

	local handle = io.popen(cmd .. " 2>&1")
	if handle then
		local result = handle:read("*a")
		local success = handle:close()

		if success then
			local ok, decoded = pcall(vim.fn.json_decode, result)
			if ok and decoded and decoded.success then
				return true
			else
				vim.notify(
					"AWS notification sync failed: " .. (decoded and decoded.error or result),
					vim.log.levels.ERROR
				)
			end
		else
			vim.notify("Failed to send manifest to AWS: " .. result, vim.log.levels.ERROR)
		end
	end

	return false
end

-- Convert calendar entry to AWS notification format
local function entry_to_notification(entry, date_str)
	local notification = {
		entry_id = string.format("%s_%s", date_str, vim.fn.sha256(entry.raw_text):sub(1, 8)),
		title = entry.display_text,
		message = calendar.format_entry(entry),
		date = date_str,
		ntfy_topic = cfg.ntfy.topic or ("zortex-" .. cfg.aws.user_id),
	}

	-- Time (default to 9:00 if not specified)
	notification.time = entry.attributes.at or "09:00"

	-- Notify settings
	if entry.attributes.notify then
		if type(entry.attributes.notify) == "string" then
			-- Parse duration: "30m", "1h", etc.
			local num, unit = entry.attributes.notify:match("^(%d+)([mh]?)$")
			if num then
				local minutes = tonumber(num)
				if unit == "h" then
					minutes = minutes * 60
				end
				notification.notify_minutes = minutes
			else
				notification.notify_minutes = 15 -- default
			end
		elseif entry.attributes.notify == true then
			notification.notify_minutes = 15 -- default
		elseif type(entry.attributes.notify) == "number" then
			notification.notify_minutes = entry.attributes.notify
		end
	else
		notification.notify_minutes = 15 -- default
	end

	-- Date range
	if entry.attributes.from then
		notification.from_date = datetime.format_date(entry.attributes.from, "YYYY-MM-DD")
	end
	if entry.attributes.to then
		notification.to_date = datetime.format_date(entry.attributes.to, "YYYY-MM-DD")
	end

	-- Repeat pattern
	if entry.attributes["repeat"] then
		notification.repeat_pattern = entry.attributes["repeat"]
	end

	-- Priority based on p attribute
	if entry.attributes.p == "1" then
		notification.priority = "urgent"
	elseif entry.attributes.p == "2" then
		notification.priority = "high"
	elseif entry.attributes.p == "3" then
		notification.priority = "default"
	else
		notification.priority = "default"
	end

	-- Tags
	notification.tags = { "calendar" }
	if entry.type == "task" then
		table.insert(notification.tags, "task")
		if entry.task_status and entry.task_status.key == "[x]" then
			table.insert(notification.tags, "completed")
		end
	elseif entry.type == "event" then
		table.insert(notification.tags, "event")
	end

	-- Add custom tags from attributes
	if entry.attributes.tags then
		for _, tag in ipairs(entry.attributes.tags) do
			table.insert(notification.tags, tag)
		end
	end

	return notification
end

-- =============================================================================
-- Notification Logic
-- =============================================================================

local function parse_notify_value(notify_value)
	-- Parse notification timing: "15m", "1h", "30", etc.
	if not notify_value or notify_value == true then
		return cfg.default_advance_minutes
	end

	if type(notify_value) == "string" then
		-- Try to parse duration format
		local num, unit = notify_value:match("^(%d+)([mh]?)$")
		if num then
			num = tonumber(num)
			if unit == "h" then
				return num * 60
			else
				return num
			end
		end
	elseif type(notify_value) == "number" then
		return notify_value
	end

	return cfg.default_advance_minutes
end

local function get_notification_time(entry, event_datetime)
	-- Calculate when to send notification based on event time and notify setting
	local advance_minutes = parse_notify_value(entry.attributes.notify)

	-- Convert event time to timestamp
	local event_time = os.time(event_datetime)

	-- Calculate notification time
	local notify_time = event_time - (advance_minutes * 60)

	return notify_time, advance_minutes
end

local function create_notification_id(entry, date_str)
	-- Create unique ID for notification to avoid duplicates
	local parts = {
		date_str,
		entry.attributes.at or "allday",
		entry.display_text:sub(1, 20),
	}
	return table.concat(parts, "_"):gsub("%s+", "_"):gsub("[^%w_-]", "")
end

local function format_notification_message(entry, minutes_until)
	local time_str = ""
	if minutes_until <= 0 then
		time_str = "now"
	elseif minutes_until < 60 then
		time_str = string.format("in %d minutes", minutes_until)
	elseif minutes_until < 120 then
		time_str = "in 1 hour"
	else
		time_str = string.format("in %d hours", math.floor(minutes_until / 60))
	end

	local message = calendar.format_entry(entry)
	return message, time_str
end

-- =============================================================================
-- Notification Checking
-- =============================================================================

function M.check_and_send_notifications()
	local now = os.time()
	local sent_count = 0

	-- Load sent notifications to avoid duplicates
	M.load_state()

	-- Get current date and next few days
	local today = datetime.get_current_date()

	for day_offset = 0, 1 do -- Check today and tomorrow
		local check_date = datetime.add_days(today, day_offset)
		local date_str = datetime.format_date(check_date, "YYYY-MM-DD")
		local entries = calendar.get_entries_for_date(date_str)

		for _, entry in ipairs(entries) do
			if entry.attributes.notify then
				local notification_id = create_notification_id(entry, date_str)

				-- Skip if already sent
				if not state.sent[notification_id] then
					-- Calculate notification time
					local event_datetime = vim.tbl_extend("force", check_date, {
						hour = 9,
						min = 0,
						sec = 0, -- Default time
					})

					-- Parse time if specified
					if entry.attributes.at then
						local hour, min = entry.attributes.at:match("^(%d+):(%d+)")
						if hour and min then
							event_datetime.hour = tonumber(hour)
							event_datetime.min = tonumber(min)
						end
					end

					local notify_time, advance_minutes = get_notification_time(entry, event_datetime)
					local event_time = os.time(event_datetime)

					-- Check if it's time to send notification
					if now >= notify_time and now < event_time then
						local minutes_until = math.floor((event_time - now) / 60)
						local message, time_str = format_notification_message(entry, minutes_until)

						local title = "Zortex Reminder - " .. time_str

						-- Send system notification
						if send_system_notification(title, message) then
							sent_count = sent_count + 1
							state.sent[notification_id] = {
								sent_at = now,
								event_time = event_time,
								message = message,
							}

							-- Also show in Neovim if it's open
							vim.schedule(function()
								vim.notify(message, vim.log.levels.INFO, {
									title = title,
									timeout = 10000,
								})
							end)
						end
						-- Send ntfy notification
						if cfg.ntfy.enabled then
							send_ntfy_notification(title, message, {
								priority = "high",
								tags = { "calendar", "reminder", time_str:gsub(" ", "-") },
								click_url = string.format("zortex://calendar/%s", date_str),
							})
						end
					end
				end
			end
		end
	end

	-- Save state
	if sent_count > 0 then
		M.save_state()
	end

	-- Clean old sent notifications (older than 2 days)
	M.clean_old_notifications()

	return sent_count
end

-- =============================================================================
-- State Persistence
-- =============================================================================

function M.load_state()
	local notification_file = fs.get_file_path(cfg.notification_file)
	if notification_file then
		local data = fs.read_json(notification_file)
		if data then
			state.pending = data.pending or {}
			state.sent = data.sent or {}
			state.last_check = data.last_check
		end
	end
end

function M.save_state()
	local notification_file = fs.get_file_path(cfg.notification_file)
	if notification_file then
		fs.write_json(notification_file, {
			pending = state.pending,
			sent = state.sent,
			last_check = os.time(),
		})
	end
end

function M.clean_old_notifications()
	local now = os.time()
	local cutoff = now - (48 * 60 * 60) -- 48 hours

	local cleaned = false
	for id, notif in pairs(state.sent) do
		if notif.sent_at < cutoff then
			state.sent[id] = nil
			cleaned = true
		end
	end

	if cleaned then
		M.save_state()
	end
end

-- =============================================================================
-- Sync and Preview
-- =============================================================================

function M.sync()
	if cfg.aws.enabled then
		return M.sync_to_aws()
	else
		return M.sync_local()
	end
end

function M.sync_local()
	-- Load calendar data
	calendar.load()

	-- Reset pending notifications
	state.pending = {}

	local now = os.time()
	local today = datetime.get_current_date()
	local upcoming_notifications = {}

	-- Check next 7 days for events with notifications
	for day_offset = 0, 6 do
		local check_date = datetime.add_days(today, day_offset)
		local date_str = datetime.format_date(check_date, "YYYY-MM-DD")
		local entries = calendar.get_entries_for_date(date_str)

		for _, entry in ipairs(entries) do
			if entry.attributes.notify then
				-- Calculate event time
				local event_datetime = vim.tbl_extend("force", check_date, {
					hour = 9,
					min = 0,
					sec = 0,
				})

				if entry.attributes.at then
					local hour, min = entry.attributes.at:match("^(%d+):(%d+)")
					if hour and min then
						event_datetime.hour = tonumber(hour)
						event_datetime.min = tonumber(min)
					end
				end

				local notify_time, advance_minutes = get_notification_time(entry, event_datetime)
				local notification_id = create_notification_id(entry, date_str)

				-- Only include if not already sent and notification time is in future
				if not state.sent[notification_id] and notify_time > now then
					table.insert(upcoming_notifications, {
						id = notification_id,
						entry = entry,
						event_time = os.time(event_datetime),
						notify_time = notify_time,
						advance_minutes = advance_minutes,
						date_str = date_str,
					})
				end
			end
		end
	end

	-- Sort by notification time
	table.sort(upcoming_notifications, function(a, b)
		return a.notify_time < b.notify_time
	end)

	-- Store in state
	state.pending = upcoming_notifications
	M.save_state()

	-- Show summary
	local summary_lines = {
		string.format("Notification sync complete - %s", os.date("%Y-%m-%d %H:%M")),
		string.format("Found %d upcoming notifications:", #upcoming_notifications),
		"",
	}

	for i, notif in ipairs(upcoming_notifications) do
		if i <= 10 then -- Show first 10
			local notify_date = os.date("%m/%d %H:%M", notif.notify_time)
			local event_date = os.date("%m/%d %H:%M", notif.event_time)
			table.insert(
				summary_lines,
				string.format(
					"  • %s - notify at %s (event at %s)",
					notif.entry.display_text:sub(1, 40),
					notify_date,
					event_date
				)
			)
		end
	end

	if #upcoming_notifications > 10 then
		table.insert(summary_lines, string.format("  ... and %d more", #upcoming_notifications - 10))
	end

	vim.notify(table.concat(summary_lines, "\n"), vim.log.levels.INFO, {
		title = "Zortex Notifications",
		timeout = 10000,
	})

	return upcoming_notifications
end

-- AWS sync function
function M.sync_to_aws()
	-- Load calendar data
	calendar.load()

	local notifications = {}
	local today = datetime.get_current_date()
	local scan_days = 365 -- Scan a full year ahead

	-- Scan future dates for entries with notifications
	for day_offset = 0, scan_days do
		local check_date = datetime.add_days(today, day_offset)
		local date_str = datetime.format_date(check_date, "YYYY-MM-DD")
		local entries = calendar.get_entries_for_date(date_str)

		for _, entry in ipairs(entries) do
			if entry.attributes.notify then
				local notification = entry_to_notification(entry, date_str)
				if notification then
					table.insert(notifications, notification)
				end
			end
		end
	end

	-- Send full sync to AWS
	local success = send_manifest_to_server("sync", notifications)

	if success then
		vim.notify(string.format("Synced %d notifications to AWS", #notifications), vim.log.levels.INFO, {
			title = "Zortex AWS Sync",
			timeout = 5000,
		})
	else
		vim.notify("Failed to sync notifications to AWS", vim.log.levels.ERROR)
	end

	return success
end

function M.get_pending_for_date(date_str)
	local pending = {}

	for _, notif in ipairs(state.pending or {}) do
		if notif.date_str == date_str then
			table.insert(pending, {
				time = os.date("%H:%M", notif.notify_time),
				title = notif.entry.display_text,
				advance_minutes = notif.advance_minutes,
			})
		end
	end

	return pending
end

-- =============================================================================
-- Background Service
-- =============================================================================

function M.create_background_script()
	-- Create a shell script that can be run as a background service
	local script_content = [[#!/bin/bash
# Zortex Calendar Notification Service

ZORTEX_DIR="$HOME/.zortex"
CHECK_INTERVAL=300  # 5 minutes

while true; do
    # Use Neovim in headless mode to check notifications
    nvim --headless -c "lua require('zortex.modules.notifications').check_and_send_notifications()" -c "qa!" 2>/dev/null
    
    sleep $CHECK_INTERVAL
done
]]

	local script_path = fs.get_file_path(".z/notification_service.sh")
	if script_path then
		local file = io.open(script_path, "w")
		if file then
			file:write(script_content)
			file:close()
			os.execute("chmod +x " .. script_path)

			vim.notify("Notification service script created at: " .. script_path, vim.log.levels.INFO)
			return script_path
		end
	end

	return nil
end

function M.setup_cron()
	-- Setup cron job for notifications
	local cron_line = string.format(
		"*/5 * * * * cd %s && /usr/bin/nvim --headless -c 'lua require(\"zortex.modules.notifications\").check_and_send_notifications()' -c 'qa!' 2>/dev/null",
		fs.get_notes_dir()
	)

	vim.notify("Add this to your crontab:\n" .. cron_line, vim.log.levels.INFO, {
		title = "Zortex Notification Cron",
		timeout = 15000,
	})
end

-- =============================================================================
-- Tests
-- =============================================================================

function M.test_notifications_ete()
	if not cfg.aws.enabled then
		vim.notify("AWS notifications not enabled", vim.log.levels.ERROR)
		return false
	end
	local cur = datetime.get_current_date()
	local entry = calendar.parse_calendar_entry("- [ ] Test", datetime.format_date(cur, "MM-DD-YYYY"))
	local notification = entry_to_notification(entry, datetime.format_date(cur, "YYYY-MM-DD"))
	notification.notify_minutes = 0
	notification.priority = "high"
	vim.notify(vim.inspect(notification), 3)
	return send_manifest_to_server("test", notification)
end

function M.test_system_notification()
	-- Send a test notification
	local success =
		send_system_notification("Zortex Test Notification", "This is a test notification from Zortex Calendar")

	if success then
		vim.notify("Test notification sent successfully!", vim.log.levels.INFO)
	else
		vim.notify("Failed to send test notification. Check your system configuration.", vim.log.levels.ERROR)
	end

	return success
end

-- Test AWS connection
function M.test_aws_connection()
	if not cfg.aws.enabled then
		vim.notify("AWS notifications not enabled", vim.log.levels.WARN)
		return false
	end

	-- Send a test notification
	local test_notification = {
		entry_id = "test_" .. os.time(),
		title = "Zortex AWS Test",
		message = "This is a test notification from Zortex",
		date = datetime.format_date(datetime.get_current_date(), "YYYY-MM-DD"),
		time = os.date("%H:%M"),
		notify_minutes = 0, -- Send immediately
		priority = "high",
		tags = { "test", "zortex" },
	}

	local success = send_manifest_to_server("add", test_notification)
	if success then
		vim.notify("AWS test notification sent successfully!", vim.log.levels.INFO)
	end

	return success
end

function M.test_ntfy_notification()
	-- Send a test notification via ntfy
	local success = send_ntfy_notification(
		"Zortex Test Notification",
		"This is a test notification from Zortex Calendar via ntfy",
		{
			priority = "high",
			tags = { "test", "zortex" },
		}
	)

	return success
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Add single notification to AWS
function M.add_notification(entry, date_str)
	if not cfg.aws.enabled then
		return false
	end

	local notification = entry_to_notification(entry, date_str)
	return send_manifest_to_server("add", notification)
end

-- Update notification in AWS
function M.update_notification(entry, date_str)
	if not cfg.aws.enabled then
		return false
	end

	local notification = entry_to_notification(entry, date_str)
	return send_manifest_to_server("update", notification)
end

-- Remove notification from AWS
function M.remove_notification(entry, date_str)
	if not cfg.aws.enabled then
		return false
	end

	local entry_id = string.format("%s_%s", date_str, vim.fn.sha256(entry.raw_text):sub(1, 8))
	return send_manifest_to_server("remove", entry_id)
end

function M.setup(opts)
	cfg = opts

	M.load_state()
end

return M
