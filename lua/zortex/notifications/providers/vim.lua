-- notifications/providers/vim.lua - Vim notification provider
local base = require("zortex.notifications.providers.base")

local function send(title, message, options, config)
	local level = options.level or config.level or vim.log.levels.INFO
	local timeout = options.timeout or config.timeout or 5000

	vim.schedule(function()
		vim.notify(message, level, {
			title = title,
			timeout = timeout,
		})
	end)

	return true, nil
end

return base.create_provider("vim", {
	send = send,

	test = function()
		return send("Zortex Test", "Vim notification test", {}, {})
	end,
})