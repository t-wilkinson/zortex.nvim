-- notifications/init.lua - Public API for the notification system
local M = {}

local manager = require("zortex.notifications.manager")
local pomodoro = require("zortex.notifications.types.pomodoro")
local timer = require("zortex.notifications.types.timer")
local calendar = require("zortex.notifications.types.calendar")
local digest = require("zortex.notifications.types.digest")
local xp = require("zortex.notifications.types.xp")

function M.setup_commands()
	local Config = require("zortex.config")

	local function cmd(name, command, options)
		vim.api.nvim_create_user_command(Config.commands.prefix .. name, command, options)
	end

	-- ===========================================================================
	-- Notifications
	-- ===========================================================================
	cmd("Notify", function(opts)
		local args = vim.split(opts.args, " ", { plain = false, trimempty = true })
		if #args < 2 then
			vim.notify("Usage: ZortexNotify <title> <message>", vim.log.levels.ERROR)
			return
		end
		local title = args[1]
		local message = table.concat(vim.list_slice(args, 2), " ")
		M.notify(title, message)
	end, { nargs = "+", desc = "Send a notification" })

	-- Pomodoro
	cmd("PomodoroStart", function()
		M.pomodoro.start()
	end, { desc = "Start pomodoro timer" })

	cmd("PomodoroStop", function()
		M.pomodoro.stop()
	end, { desc = "Stop pomodoro timer" })

	cmd("PomodoroStatus", function()
		local status = M.pomodoro.status()
		if status.phase == "stopped" then
			vim.notify("Pomodoro is not running", vim.log.levels.INFO)
		else
			vim.notify(
				string.format("Pomodoro: %s - %s remaining", status.phase:gsub("_", " "), status.remaining_formatted),
				vim.log.levels.INFO
			)
		end
	end, { desc = "Show pomodoro status" })

	-- Timers
	cmd("TimerStart", function(opts)
		local args = vim.split(opts.args, " ", { plain = false, trimempty = true })
		if #args < 1 then
			vim.notify("Usage: ZortexTimerStart <duration> [name]", vim.log.levels.ERROR)
			return
		end
		local duration = args[1]
		local name = args[2] and table.concat(vim.list_slice(args, 2), " ") or nil
		local id = M.timer.start(duration, name)
		if id then
			vim.notify("Timer started: " .. id, vim.log.levels.INFO)
		end
	end, { nargs = "+", desc = "Start a timer" })

	cmd("TimerList", function()
		local timers = M.timer.list()
		if #timers == 0 then
			vim.notify("No active timers", vim.log.levels.INFO)
		else
			local lines = { "Active timers:" }
			for _, timer in ipairs(timers) do
				table.insert(
					lines,
					string.format("  %s: %s - %s remaining", timer.id:sub(1, 8), timer.name, timer.remaining_formatted)
				)
			end
			vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
		end
	end, { desc = "List active timers" })

	-- Calendar sync
	cmd("NotificationSync", function()
		M.calendar.sync()
	end, { desc = "Sync calendar notifications" })

	-- Test notifications
	cmd("TestNotifications", function()
		M.test.all()
	end, { desc = "Test all notification providers" })

	-- Daily Digest
	cmd("DigestSend", function()
		local success, msg = M.digest.send_now()
		vim.notify(msg, success and vim.log.levels.INFO or vim.log.levels.ERROR)
	end, { desc = "Send daily digest email now" })

	cmd("DigestPreview", function()
		M.digest.preview()
	end, { desc = "Preview daily digest" })
end

-- Initialize the notification system
function M.setup(cfg) -- Config.notifications
	manager.setup(cfg)
	pomodoro.setup(cfg.pomodoro)
	timer.setup(cfg.timers)
	calendar.setup(cfg)
	digest.setup(cfg.digest)
end

-- Send a notification immediately
function M.notify(title, message, options)
	return manager.send_notification(title, message, options)
end

-- Schedule a notification
function M.schedule(title, message, when, options)
	return manager.schedule_notification(title, message, when, options)
end

-- Cancel a scheduled notification
function M.cancel(id)
	return manager.cancel_notification(id)
end

-- List scheduled notifications
function M.list_scheduled()
	return manager.list_scheduled()
end

-- Pomodoro functions
M.pomodoro = {
	start = pomodoro.start,
	stop = pomodoro.stop,
	pause = pomodoro.pause,
	resume = pomodoro.resume,
	status = pomodoro.status,
	skip = pomodoro.skip_to_next,
}

-- Timer functions
M.timer = {
	start = timer.start,
	stop = timer.stop,
	list = timer.list,
	remaining = timer.get_remaining,
}

-- Calendar functions
M.calendar = {
	sync = calendar.sync,
	check = calendar.check_and_notify,
	get_pending_for_date = calendar.get_pending_for_date,
}

M.digest = digest
M.xp = xp

-- Test functions
M.test = {
	system = function()
		return M.notify("Test", "System notification test", { providers = { "system" } })
	end,
	ntfy = function()
		return M.notify("Test", "ntfy notification test", { providers = { "ntfy" } })
	end,
	aws = function()
		return M.notify("Test", "AWS notification test", { providers = { "aws" } })
	end,
	ses = function()
		return M.notify("Test", "AWS SES email test", { providers = { "ses" } })
	end,
	all = function()
		return M.notify("Test", "Testing all providers")
	end,
}

-- Cleanup on exit
function M.cleanup()
	manager.stop()
	timer.cleanup()
end

return M
