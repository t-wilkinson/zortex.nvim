-- notifications/manager.lua - Core notification manager
local M = {}

local state = require("zortex.notifications.state")
local providers = {}
local config = {}
local scheduled = {}
local timer_handle = nil

-- Load all providers
local function load_providers()
	providers.system = require("zortex.notifications.providers.system")
	providers.ntfy = require("zortex.notifications.providers.ntfy")
	providers.aws = require("zortex.notifications.providers.aws")
	providers.vim = require("zortex.notifications.providers.vim")
	providers.ses = require("zortex.notifications.providers.ses")
end

-- Get active providers for a notification type
local function get_providers_for_type(notification_type)
	local provider_names = config[notification_type .. "_providers"] or config.default_providers or { "vim" }
	local active = {}

	for _, name in ipairs(provider_names) do
		if config.providers[name] and config.providers[name].enabled and providers[name] then
			table.insert(active, providers[name])
		end
	end

	return active
end

-- Send notification through all active providers
function M.send_notification(title, message, options)
	options = options or {}
	local notification_type = options.type or "default"
	local provider_list = options.providers and {} or get_providers_for_type(notification_type)

	-- If specific providers requested
	if options.providers then
		for _, name in ipairs(options.providers) do
			if providers[name] and config.providers[name] and config.providers[name].enabled then
				table.insert(provider_list, providers[name])
			end
		end
	end

	local results = {}
	for _, provider in ipairs(provider_list) do
		local success, err = provider.send(title, message, options, config.providers[provider.name])
		table.insert(results, {
			provider = provider.name,
			success = success,
			error = err,
		})
	end

	-- Log notification
	state.log_notification({
		title = title,
		message = message,
		options = options,
		results = results,
		timestamp = os.time(),
	})

	return results
end

-- Schedule a notification
function M.schedule_notification(title, message, when, options)
	local scheduled_time
	if type(when) == "number" then
		scheduled_time = when
	elseif type(when) == "string" then
		-- Parse duration string (e.g., "5m", "1h")
		local duration = require("zortex.core.datetime").parse_duration(when)
		if duration then
			scheduled_time = os.time() + (duration * 60)
		else
			return nil, "Invalid duration format"
		end
	elseif type(when) == "table" then
		scheduled_time = os.time(when)
	else
		return nil, "Invalid time format"
	end

	local id = string.format("%s_%s_%s", scheduled_time, title:gsub("%s+", "_"):sub(1, 20), tostring(os.time()))

	local notification = {
		id = id,
		title = title,
		message = message,
		scheduled_time = scheduled_time,
		options = options or {},
		created_at = os.time(),
	}

	scheduled[id] = notification
	state.save_scheduled(scheduled)

	return id
end

-- Cancel a scheduled notification
function M.cancel_notification(id)
	if scheduled[id] then
		scheduled[id] = nil
		state.save_scheduled(scheduled)
		return true
	end
	return false
end

-- List scheduled notifications
function M.list_scheduled()
	local list = {}
	for id, notif in pairs(scheduled) do
		table.insert(list, notif)
	end
	table.sort(list, function(a, b)
		return a.scheduled_time < b.scheduled_time
	end)
	return list
end

-- Check and send due notifications
local function check_scheduled()
	local now = os.time()
	local sent = {}

	for id, notif in pairs(scheduled) do
		if notif.scheduled_time <= now then
			M.send_notification(notif.title, notif.message, notif.options)
			table.insert(sent, id)
		end
	end

	-- Remove sent notifications
	for _, id in ipairs(sent) do
		scheduled[id] = nil
	end

	if #sent > 0 then
		state.save_scheduled(scheduled)
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

	-- Load scheduled notifications
	scheduled = state.load_scheduled() or {}

	-- Start timer for checking scheduled notifications
	if config.enabled ~= false then
		timer_handle = vim.loop.new_timer()
		local interval = (config.check_interval_minutes or 1) * 60000
		timer_handle:start(0, interval, vim.schedule_wrap(check_scheduled))
	end
end

-- Cleanup
function M.stop()
	if timer_handle then
		timer_handle:stop()
		timer_handle:close()
		timer_handle = nil
	end
end

return M

