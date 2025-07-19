-- notifications/providers/aws.lua - AWS notification provider
local base = require("zortex.notifications.providers.base")

local function send(title, message, options, config)
	if not config.api_endpoint or not config.user_id then
		return false, "AWS endpoint or user_id not configured"
	end

	local notification_data = {
		user_id = config.user_id,
		operation = "notify",
		notification = {
			title = title,
			message = message,
			priority = options.priority or "default",
			tags = options.tags or {},
			timestamp = os.time(),
		},
	}

	-- Add optional fields
	if options.scheduled_time then
		notification_data.notification.scheduled_time = options.scheduled_time
	end
	if options.entry_id then
		notification_data.notification.entry_id = options.entry_id
	end

	local json_data = vim.fn.json_encode(notification_data)
	local cmd = string.format(
		'curl -s -X POST -H "Content-Type: application/json" -H "Accept: application/json" -d %s %s',
		vim.fn.shellescape(json_data),
		vim.fn.shellescape(config.api_endpoint)
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
				return false, "AWS error: " .. (decoded and decoded.error or result)
			end
		else
			return false, "Failed to send to AWS: " .. result
		end
	end

	return false, "Failed to execute curl"
end

-- Sync multiple notifications
local function sync_notifications(notifications, config)
	if not config.api_endpoint or not config.user_id then
		return false, "AWS endpoint or user_id not configured"
	end

	local manifest = {
		user_id = config.user_id,
		operation = "sync",
		notifications = notifications,
	}

	local json_data = vim.fn.json_encode(manifest)
	local cmd = string.format(
		'curl -s -X POST -H "Content-Type: application/json" -H "Accept: application/json" -d %s %s',
		vim.fn.shellescape(json_data),
		vim.fn.shellescape(config.api_endpoint)
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
				return false, "AWS sync failed: " .. (decoded and decoded.error or result)
			end
		end
	end

	return false
end

return base.create_provider("aws", {
	send = send,
	sync = sync_notifications,

	test = function()
		return send("Zortex Test", "AWS notification test", { priority = "high" }, {
			api_endpoint = "https://example.com/notify",
			user_id = "test-user",
		})
	end,
})