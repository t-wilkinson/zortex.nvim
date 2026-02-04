-- notifications/providers/homelab.lua - Homelab notification provider
local base = require("zortex.notifications.providers.base")
local Config = require("zortex.config")

-- priority=min(1),low,default,high,max/urgent(5)

local function send(title, message, options, config)
	if not config.api_endpoint or not config.user_id then
		return false, "Homelab endpoint or user_id not configured"
	end

	local notification_data = {
		user_id = config.user_id,
		operation = "notify",
		notification = {
			title = title,
			message = message,
			priority = options.priority or "default",
			tags = options.tags or {},
			scheduled_time = options.scheduled_time or os.time(),
			entry_id = options.entry_id,
			deduplication_key = options.deduplication_key,
		},
	}

	local json_data = vim.fn.json_encode(notification_data)

	-- Build curl command with optional API key
	local headers = {
		'"Content-Type: application/json"',
		'"Accept: application/json"',
	}

	if config.api_key then
		table.insert(headers, string.format('"X-API-Key: %s"', config.api_key))
	end

	local cmd = string.format(
		"curl -s -X POST %s -d %s %s/notify",
		table.concat(
			vim.tbl_map(function(h)
				return "-H " .. h
			end, headers),
			" "
		),
		vim.fn.shellescape(json_data),
		config.api_endpoint
	)

	local handle = io.popen(cmd .. " 2>&1")
	if handle then
		local result = handle:read("*a")
		local success = handle:close()

		if success then
			local ok, decoded = pcall(vim.fn.json_decode, result)
			if ok and decoded and decoded.success then
				return true, nil
			else
				return false, "Homelab error: " .. (decoded and decoded.error or result)
			end
		else
			return false, "Failed to send to homelab: " .. result
		end
	end

	return false, "Failed to execute curl"
end

-- Sync multiple notifications (used by calendar sync)
local function sync_notifications(notifications, config)
	if not config.api_endpoint then
		return false, "Homelab endpoint not configured"
	end

	-- Transform notifications to include scheduled_time and deduplication_key
	local processed_notifications = {}
	for _, notif in ipairs(notifications) do
		table.insert(processed_notifications, {
			title = notif.title,
			message = notif.message,
			scheduled_time = notif.trigger_time or os.time(),
			priority = notif.options and notif.options.priority or "default",
			tags = notif.options and notif.options.tags or {},
			entry_id = notif.options and notif.options.entry_text,
			deduplication_key = notif.options and notif.options.deduplication_key,
		})
	end

	local manifest = {
		user_id = config.user_id,
		operation = "sync",
		notifications = processed_notifications,
	}

	local json_data = vim.fn.json_encode(manifest)

	-- Build curl command with optional API key
	local headers = {
		'"Content-Type: application/json"',
		'"Accept: application/json"',
	}

	if config.api_key then
		table.insert(headers, string.format('"X-API-Key: %s"', config.api_key))
	end

	local cmd = string.format(
		"curl -s -X POST %s -d %s %s/notify",
		table.concat(
			vim.tbl_map(function(h)
				return "-H " .. h
			end, headers),
			" "
		),
		vim.fn.shellescape(json_data),
		config.api_endpoint
	)

	local handle = io.popen(cmd .. " 2>&1")
	if handle then
		local result = handle:read("*a")
		local success = handle:close()

		if success then
			local ok, decoded = pcall(vim.fn.json_decode, result)
			if ok and decoded and decoded.success then
				return true, nil
			else
				return false, "Homelab sync failed: " .. (decoded and decoded.error or result)
			end
		end
	end

	return false, "Failed to execute curl"
end

return base.create_provider("homelab", {
	send = send,
	sync = sync_notifications,

	test = function()
		return send("Zortex Test", "Homelab notification test", {
			priority = "high",
			tags = { "test", "zortex" },
		}, {
			api_endpoint = Config.server.api_endpoint,
			user_id = Config.server.user_id,
		})
	end,
})
