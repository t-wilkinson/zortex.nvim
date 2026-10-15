-- notifications/providers/ntfy.lua - ntfy.sh notification provider
local base = require("zortex.notifications.providers.base")

local PRIORITY = { min = 1, low = 2, default = 3, high = 4, max = 5, urgent = 5 }

-- Publishes as JSON (like the server does) with curl in the background: no
-- shell, so quotes in titles are fine and the editor never waits.
local function send(title, message, options, config)
	-- no default topic: on a public server anyone could read a shared one
	if type(config.topic) ~= "string" or vim.trim(config.topic) == "" then
		return false, "No ntfy topic configured (notifications.providers.ntfy.topic)"
	end
	local priority = options.priority or config.priority or "default"
	local body = {
		topic = config.topic,
		title = title,
		message = message,
		priority = tonumber(priority) or PRIORITY[priority] or 3,
		tags = options.tags or config.tags or nil,
		click = options.click_url,
	}
	local cmd = { "curl", "-sS", "--fail", "-X", "POST", "-H", "Content-Type: application/json" }
	if config.auth_token then
		vim.list_extend(cmd, { "-H", "Authorization: Bearer " .. config.auth_token })
	elseif config.username and config.password then
		vim.list_extend(cmd, { "-u", config.username .. ":" .. config.password })
	end
	vim.list_extend(cmd, { "--data-binary", "@-", (config.server_url or "https://ntfy.sh"):gsub("/+$", "") })
	local ok, err = pcall(vim.system, cmd, { text = true, stdin = vim.json.encode(body) }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				require("zortex.core.logger").warn("notifications", "ntfy publish failed", { code = res.code, stderr = res.stderr })
			end)
		end
	end)
	return ok, not ok and tostring(err) or nil
end

return base.create_provider("ntfy", {
	send = send,
})

