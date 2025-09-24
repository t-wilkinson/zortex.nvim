-- notifications/manager.lua - Unified notification scheduler with persistence
local M = {}

local Logger = require("zortex.core.logger")
local store = require("zortex.stores.notifications")
local providers = {}
local config = {}

-- Core state
local scheduled_notifications = {} -- id -> notification
local notification_timers = {} -- id -> timer handle
local sent_notifications = {} -- deduplication tracking

-- Generate unique ID
local function generate_id()
	return string.format("notif_%s_%s", os.time(), math.random(100000))
end

-- Load all providers
local function load_providers()
	providers.system = require("zortex.notifications.providers.system")
	providers.ntfy = require("zortex.notifications.providers.ntfy")
	providers.aws = require("zortex.notifications.providers.aws")
	providers.vim = require("zortex.notifications.providers.vim")
	providers.ses = require("zortex.notifications.providers.ses")
end

-- Calculate next occurrence for repeating notifications
local function calculate_next_occurrence(current_time, repeat_mode, repeat_interval)
	local next_time = current_time
	local now = os.time()

	-- Ensure we're scheduling in the future
	while next_time <= now do
		if repeat_mode == "daily" then
			next_time = next_time + 86400
		elseif repeat_mode == "weekly" then
			next_time = next_time + (7 * 86400)
		elseif repeat_mode == "monthly" then
			local date = os.date("*t", next_time)
			date.month = date.month + 1
			if date.month > 12 then
				date.month = 1
				date.year = date.year + 1
			end
			next_time = os.time(date)
		elseif repeat_mode == "yearly" then
			local date = os.date("*t", next_time)
			date.year = date.year + 1
			next_time = os.time(date)
		elseif repeat_mode == "weekdays" then
			repeat
				next_time = next_time + 86400
				local wday = os.date("*t", next_time).wday
			until wday >= 2 and wday <= 6 -- Monday to Friday
		elseif repeat_mode == "weekends" then
			repeat
				next_time = next_time + 86400
				local wday = os.date("*t", next_time).wday
			until wday == 1 or wday == 7 -- Sunday or Saturday
		elseif repeat_mode == "custom" and repeat_interval then
			next_time = next_time + (repeat_interval * 86400)
		else
			-- Try to parse patterns like "3d", "2w"
			local num, unit = (repeat_mode or ""):match("^(%d+)([dwmy])$")
			if num and unit then
				num = tonumber(num)
				if unit == "d" then
					next_time = next_time + (num * 86400)
				elseif unit == "w" then
					next_time = next_time + (num * 7 * 86400)
				elseif unit == "m" then
					local date = os.date("*t", next_time)
					date.month = date.month + num
					while date.month > 12 do
						date.month = date.month - 12
						date.year = date.year + 1
					end
					next_time = os.time(date)
				elseif unit == "y" then
					local date = os.date("*t", next_time)
					date.year = date.year + num
					next_time = os.time(date)
				else
					break -- Unknown pattern
				end
			else
				break -- No valid repeat mode
			end
		end
	end

	return next_time > now and next_time or nil
end

-- Persist notifications
local function save_scheduled_notifications()
	local data = {
		scheduled = scheduled_notifications,
		sent = sent_notifications,
	}
	store.save_notification_state(data)
end

-- Load persisted notifications
local function load_scheduled_notifications()
	local data = store.get_notification_state()
	if data then
		scheduled_notifications = data.scheduled or {}
		sent_notifications = data.sent or {}

		-- Reschedule all loaded notifications
		for id, notification in pairs(scheduled_notifications) do
			if notification.trigger_time > os.time() then
				-- Future notification, reschedule it
				M.schedule_notification(notification)
			elseif notification.options and notification.options.repeat_mode then
				-- Past notification with repeat, calculate next occurrence
				notification.trigger_time = calculate_next_occurrence(
					notification.trigger_time,
					notification.options.repeat_mode,
					notification.options.repeat_interval
				)
				if notification.trigger_time then
					M.schedule_notification(notification)
				else
					-- Can't calculate next occurrence, remove it
					scheduled_notifications[id] = nil
				end
			else
				-- Past notification without repeat, remove it
				scheduled_notifications[id] = nil
			end
		end
	end
end

-- Schedule a notification
function M.schedule_notification(notification)
	-- Ensure notification has an ID
	if not notification.id then
		notification.id = generate_id()
	end

	-- Check deduplication
	if notification.options and notification.options.deduplication_key then
		local dedup_key = notification.options.deduplication_key
		if sent_notifications[dedup_key] then
			local sent_time = sent_notifications[dedup_key]
			-- Skip if already sent within the notification window (24 hours)
			if os.time() - sent_time < 86400 then
				Logger.debug("notifications", "schedule_notification", {
					id = notification.id,
					reason = "Already scheduled/sent",
					dedup_key = dedup_key,
				})
				return nil, "Already scheduled/sent"
			end
		end

		-- Also check if already scheduled
		for _, existing in pairs(scheduled_notifications) do
			if existing.options and existing.options.deduplication_key == dedup_key then
				Logger.debug("notifications", "schedule_notification", {
					id = notification.id,
					reason = "Already scheduled",
					dedup_key = dedup_key,
				})
				return nil, "Already scheduled"
			end
		end
	end

	-- Calculate next trigger time for repeating notifications in the past
	if notification.options and notification.options.repeat_mode and notification.trigger_time <= os.time() then
		notification.trigger_time = calculate_next_occurrence(
			notification.trigger_time,
			notification.options.repeat_mode,
			notification.options.repeat_interval
		)
		if not notification.trigger_time then
			return nil, "Cannot calculate next occurrence"
		end
	end

	-- Cancel existing timer if rescheduling
	if notification_timers[notification.id] then
		notification_timers[notification.id]:stop()
		notification_timers[notification.id]:close()
		notification_timers[notification.id] = nil
	end

	-- Store notification
	scheduled_notifications[notification.id] = notification

	-- Create timer
	local delay = math.max(0, (notification.trigger_time - os.time()) * 1000)
	if delay > 0 then
		local timer = vim.loop.new_timer()
		timer:start(
			delay,
			0,
			vim.schedule_wrap(function()
				M.trigger_notification(notification.id)
			end)
		)
		notification_timers[notification.id] = timer
	elseif delay == 0 then
		-- Trigger immediately
		vim.schedule(function()
			M.trigger_notification(notification.id)
		end)
	end

	-- Persist
	save_scheduled_notifications()

	Logger.info("notifications", "schedule_notification", {
		id = notification.id,
		title = notification.title,
		trigger_time = notification.trigger_time,
		trigger_date = os.date("%c", notification.trigger_time),
		type = notification.type,
	})

	return notification.id
end

-- Trigger a notification
function M.trigger_notification(notification_id)
	local notification = scheduled_notifications[notification_id]
	if not notification then
		return
	end

	-- Determine channels
	local channels = notification.channels
	if not channels then
		channels = config.channels and config.channels[notification.type]
		if not channels then
			channels = config.channels and config.channels.default or { "vim", "system" }
		end
	end

	-- Send through all configured channels
	local results = {}
	local any_success = false

	for _, channel in ipairs(channels) do
		if providers[channel] and config.providers[channel] and config.providers[channel].enabled then
			local success, err = providers[channel].send(
				notification.title,
				notification.message,
				notification.options or {},
				config.providers[channel]
			)
			table.insert(results, {
				provider = channel,
				success = success,
				error = err,
			})
			if success then
				any_success = true
			end
		end
	end

	-- Fallback to ntfy if all channels failed
	if not any_success and providers.ntfy and config.providers.ntfy and config.providers.ntfy.enabled then
		local success, err = providers.ntfy.send(
			notification.title,
			notification.message,
			notification.options or {},
			config.providers.ntfy
		)
		table.insert(results, {
			provider = "ntfy",
			success = success,
			error = err,
		})
	end

	-- Track sent notification for deduplication
	if notification.options and notification.options.deduplication_key then
		sent_notifications[notification.options.deduplication_key] = os.time()
	end

	-- Clean up timer reference
	if notification_timers[notification_id] then
		notification_timers[notification_id] = nil
	end

	-- Handle repeating notifications
	if notification.options and notification.options.repeat_mode then
		notification.trigger_time = calculate_next_occurrence(
			notification.trigger_time,
			notification.options.repeat_mode,
			notification.options.repeat_interval
		)
		if notification.trigger_time then
			M.schedule_notification(notification) -- Reschedule
		else
			-- Can't calculate next occurrence, remove it
			scheduled_notifications[notification_id] = nil
		end
	else
		-- One-time notification, remove it
		scheduled_notifications[notification_id] = nil
	end

	save_scheduled_notifications()

	Logger.info("notifications", "trigger_notification", {
		id = notification_id,
		title = notification.title,
		results = results,
	})

	return results
end

-- Send notification immediately (backward compatibility)
function M.send_notification(title, message, options)
	options = options or {}

	-- Create a notification object
	local notification = {
		id = generate_id(),
		title = title,
		message = message,
		trigger_time = os.time(), -- Now
		type = options.type or "default",
		channels = options.channels or options.providers, -- Support old 'providers' key
		options = options,
	}

	scheduled_notifications[notification.id] = notification

	-- Send immediately by triggering
	return M.trigger_notification(notification.id)
end

-- Cancel a scheduled notification
function M.cancel_notification(id)
	if notification_timers[id] then
		notification_timers[id]:stop()
		notification_timers[id]:close()
		notification_timers[id] = nil
	end

	if scheduled_notifications[id] then
		scheduled_notifications[id] = nil
		save_scheduled_notifications()
		return true
	end

	return false
end

-- List scheduled notifications with optional filter
function M.list_scheduled(filter)
	local list = {}

	for id, notif in pairs(scheduled_notifications) do
		local include = true

		if filter then
			if filter.type and notif.type ~= filter.type then
				include = false
			elseif filter.before and notif.trigger_time > filter.before then
				include = false
			elseif filter.after and notif.trigger_time < filter.after then
				include = false
			end
		end

		if include then
			table.insert(list, notif)
		end
	end

	table.sort(list, function(a, b)
		return a.trigger_time < b.trigger_time
	end)

	return list
end

-- Clean old sent notifications
local function clean_old_sent_notifications()
	local cutoff = os.time() - 86400 -- 24 hours ago
	local cleaned = 0

	for key, time in pairs(sent_notifications) do
		if time < cutoff then
			sent_notifications[key] = nil
			cleaned = cleaned + 1
		end
	end

	if cleaned > 0 then
		save_scheduled_notifications()
		Logger.debug("notifications", "clean_old_sent", { cleaned = cleaned })
	end
end

-- Setup function
function M.setup(cfg)
	config = cfg or {}
	load_providers()

	-- Initialize providers
	for name, provider in pairs(providers) do
		if provider.setup then
			provider.setup(config.providers[name] or {})
		end
	end

	-- Load persisted notifications
	load_scheduled_notifications()

	-- Start cleanup timer for old sent notifications
	local cleanup_timer = vim.loop.new_timer()
	cleanup_timer:start(0, 3600000, vim.schedule_wrap(clean_old_sent_notifications)) -- Every hour
end

-- Cleanup
function M.stop()
	-- Stop all timers
	for id, timer in pairs(notification_timers) do
		if timer then
			timer:stop()
			timer:close()
		end
	end
	notification_timers = {}

	-- Save state
	save_scheduled_notifications()
end

return M
