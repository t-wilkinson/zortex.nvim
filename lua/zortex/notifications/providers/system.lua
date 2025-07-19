-- notifications/providers/system.lua - System notification provider
local base = require("zortex.notifications.providers.base")

local function get_os()
	local handle = io.popen("uname -s")
	if handle then
		local result = handle:read("*a"):gsub("%s+", "")
		handle:close()

		if result == "Darwin" then
			return "macos"
		elseif result == "Linux" then
			if os.getenv("PREFIX") and os.getenv("PREFIX"):match("termux") then
				return "termux"
			end
			return "linux"
		end
	end
	return "unknown"
end

local function send(title, message, options, config)
	local os_type = get_os()
	local cmd_template = config.commands and config.commands[os_type]

	if not cmd_template then
		return false, "No command configured for " .. os_type
	end

	-- Escape quotes
	title = title:gsub("'", "'\"'\"'")
	message = message:gsub("'", "'\"'\"'")

	-- Add sound option for macOS if specified
	if os_type == "macos" and options.sound then
		cmd_template = cmd_template:gsub("-sound default", "-sound " .. options.sound)
	end

	local cmd = string.format(cmd_template, title, message)
	local success = os.execute(cmd)

	return success == 0, success ~= 0 and "Command failed" or nil
end

return base.create_provider("system", {
	send = send,

	test = function()
		return send("Zortex Test", "System notification test", {}, {
			commands = {
				macos = "terminal-notifier -title '%s' -message '%s' -sound default",
				linux = "notify-send -u normal -t 10000 '%s' '%s'",
				termux = "termux-notification --title '%s' --content '%s'",
			},
		})
	end,
})