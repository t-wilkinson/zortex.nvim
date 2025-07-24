-- notifications/init.lua - Public API for the notification system
local M = {}

local manager = require("zortex.notifications.manager")
local pomodoro = require("zortex.notifications.types.pomodoro")
local timer = require("zortex.notifications.types.timer")
local calendar = require("zortex.notifications.types.calendar")
local digest = require("zortex.notifications.types.digest")
local xp = require("zortex.notifications.types.xp")

-- Initialize the notification system
function M.setup(config)
	manager.setup(config)
	pomodoro.setup(config.pomodoro)
	timer.setup(config.timers)
	calendar.setup(config)
	digest.setup(config.digest)
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
