-- notifications/providers/system.lua - System notification provider
local base = require("zortex.notifications.providers.base")

local function get_os()
	local sys = vim.uv.os_uname().sysname
	if sys == "Darwin" then
		return "macos"
	elseif sys == "Linux" then
		if (os.getenv("PREFIX") or ""):match("termux") then
			return "termux"
		end
		return "linux"
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
	-- in the background: a slow notifier never blocks the editor
	local ok, err = pcall(vim.system, { "sh", "-c", cmd }, { text = true }, function(res)
		if res.code ~= 0 then
			vim.schedule(function()
				require("zortex.core.logger").warn("notifications", "system notifier failed", { code = res.code, stderr = res.stderr })
			end)
		end
	end)
	return ok, not ok and tostring(err) or nil
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