-- notifications/providers/vim.lua - Vim notification provider
local base = require("zortex.notifications.providers.base")

local function send(title, message, options, config)
	local level = options.level or config.level or vim.log.levels.INFO
	local timeout = options.timeout or config.timeout or 5000

	vim.schedule(function()
		-- title/timeout are honoured by notification plugins (nvim-notify,
		-- noice, snacks); plain vim.notify shows the message
		local text = (title and title ~= "") and (title .. ": " .. (message or "")) or (message or "")
		vim.notify(text, level, { title = title, timeout = timeout })
	end)

	return true, nil
end

return base.create_provider("vim", {
	send = send,
})

