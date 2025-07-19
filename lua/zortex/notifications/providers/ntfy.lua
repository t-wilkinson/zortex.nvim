-- notifications/providers/ntfy.lua - ntfy.sh notification provider
local base = require("zortex.notifications.providers.base")

local function send(title, message, options, config)
	if not config.topic then
		return false, "No ntfy topic configured"
	end

	local priority = options.priority or config.priority or "default"
	local tags = options.tags or config.tags or {}
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
	if config.auth_token then
		table.insert(cmd_parts, "-H")
		table.insert(cmd_parts, string.format('"Authorization: Bearer %s"', config.auth_token))
	end

	-- Add message data
	table.insert(cmd_parts, "-d")
	table.insert(cmd_parts, string.format('"%s"', message:gsub('"', '\\"')))

	-- Add server URL and topic
	local server_url = config.server_url or "http://ntfy.sh"
	table.insert(cmd_parts, string.format('"%s/%s"', server_url, config.topic))

	local cmd = table.concat(cmd_parts, " ")
	local handle = io.popen(cmd .. " 2>&1")
	if handle then
		local result = handle:read("*a")
		local success = handle:close()

		if not success then
			return false, "ntfy error: " .. result
		end
		return true, nil
	end

	return false, "Failed to execute curl"
end

return base.create_provider("ntfy", {
	send = send,

	test = function()
		return send("Zortex Test", "ntfy notification test", { priority = "high", tags = { "test" } }, {
			topic = "test-topic",
			server_url = "http://ntfy.sh",
		})
	end,
})