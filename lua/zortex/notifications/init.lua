-- notifications/init.lua - Public API for the unified notification system
local M = {}

local manager = require("zortex.notifications.manager")
local pomodoro = require("zortex.notifications.types.pomodoro")
local alarm = require("zortex.notifications.types.alarm")
local timer = require("zortex.notifications.types.timer")
local calendar = require("zortex.notifications.types.calendar")
local digest = require("zortex.notifications.types.digest")

-- Initialize the notification system
function M.setup(opts)
	-- Setup the core manager first
	manager.setup(opts)

	-- Setup individual modules
	pomodoro.setup(opts.types.pomodoro)
	timer.setup(opts.types.timers)
	calendar.setup(opts.types.calendar)
	digest.setup(opts.types.digest)
	alarm.setup(opts.types.alarm)

	-- Setup commands and autocmds
	M.setup_commands()
	M.setup_autocmds()
end

-- ===========================================================================
-- Core API
-- ===========================================================================

-- Send a notification immediately
function M.notify(title, message, options)
	return manager.send_notification(title, message, options)
end

-- Schedule a notification
function M.schedule(notification)
	return manager.schedule_notification(notification)
end

-- Cancel a scheduled notification
function M.cancel(id)
	return manager.cancel_notification(id)
end

-- List scheduled notifications with optional filter
function M.list_scheduled(filter)
	return manager.list_scheduled(filter)
end

-- ===========================================================================
-- Module APIs
-- ===========================================================================

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

-- Alarm functions (simplified interface)
M.alarm = {
	set = alarm.set,
	list = alarm.list,
	remove = alarm.remove,
	snooze = alarm.snooze,
	dismiss = alarm.dismiss,
	edit = alarm.edit,
	quick_alarm = alarm.quick_alarm,
}

-- Calendar functions
M.calendar = {
	sync = calendar.sync,
	get_pending_for_date = calendar.get_pending_for_date,
}

-- Digest functions
M.digest = digest

-- ===========================================================================
-- Test Functions
-- ===========================================================================

M.test = {
	system = function()
		return M.notify("Test", "System notification test", { channels = { "system" } })
	end,
	ntfy = function()
		return M.notify("Test", "ntfy notification test", { channels = { "ntfy" } })
	end,
	aws = function()
		return M.notify("Test", "AWS notification test", { channels = { "aws" } })
	end,
	ses = function()
		return M.notify("Test", "AWS SES email test", { channels = { "ses" } })
	end,
	vim = function()
		return M.notify("Test", "Vim notification test", { channels = { "vim" } })
	end,
	all = function()
		return M.notify("Test", "Testing all configured channels")
	end,
}

-- ===========================================================================
-- Cleanup
-- ===========================================================================

function M.cleanup()
	manager.stop()
	timer.cleanup()
	alarm.cleanup()
end

-- ===========================================================================
-- Autocmds
-- ===========================================================================

function M.setup_autocmds()
	local group = vim.api.nvim_create_augroup("ZortexNotifications", { clear = true })

	-- Sync calendar on save
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*calendar.zortex",
		callback = function()
			-- Defer slightly to ensure file is fully written
			vim.defer_fn(function()
				M.calendar.sync()
			end, 100)
		end,
		desc = "Sync calendar notifications on save",
	})

	-- Clean up on exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			M.cleanup()
		end,
		desc = "Clean up notifications on exit",
	})
end

-- ===========================================================================
-- Commands
-- ===========================================================================

function M.setup_commands()
	local Config = require("zortex.config")

	local function cmd(name, command, options)
		vim.api.nvim_create_user_command(Config.commands.prefix .. name, command, options)
	end

	-- ===========================================================================
	-- Core notifications
	-- ===========================================================================

	-- Send immediate notification
	cmd("Notify", function(opts)
		local args = vim.split(opts.args, " ", { plain = false, trimempty = true })
		if #args < 2 then
			vim.notify("Usage: ZortexNotify <title> <message>", vim.log.levels.ERROR)
			return
		end
		local title = args[1]
		local message = table.concat(vim.list_slice(args, 2), " ")
		M.notify(title, message)
	end, { nargs = "*", desc = "Send a notification" })

	-- List scheduled notifications
	cmd("NotificationList", function(opts)
		local filter = nil
		if opts.args ~= "" then
			filter = { type = opts.args }
		end

		local notifications = M.list_scheduled(filter)
		if #notifications == 0 then
			vim.notify("No scheduled notifications", vim.log.levels.INFO)
			return
		end

		local lines = { "Scheduled Notifications:", "" }
		for _, notif in ipairs(notifications) do
			local time_str = os.date("%b %d %H:%M", notif.trigger_time)
			local type_str = notif.type or "default"
			table.insert(
				lines,
				string.format(
					"[%s] %s - %s: %s",
					type_str,
					time_str,
					notif.title or "Untitled",
					notif.message and notif.message:sub(1, 50) or ""
				)
			)
		end

		-- Create buffer to display
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
		vim.api.nvim_buf_set_option(buf, "buftype", "nofile")

		vim.cmd("split")
		vim.api.nvim_win_set_buf(0, buf)
	end, {
		nargs = "?",
		desc = "List scheduled notifications",
		complete = function()
			return { "alarm", "calendar", "timer", "pomodoro", "digest" }
		end,
	})

	-- Calendar sync
	cmd("CalendarSync", function()
		local count = M.calendar.sync()
		vim.notify(string.format("Calendar sync complete: %d notifications scheduled", count), vim.log.levels.INFO)
	end, { desc = "Sync calendar notifications" })

	-- Test notifications
	cmd("TestNotifications", function(opts)
		if opts.args ~= "" then
			local test_fn = M.test[opts.args]
			if test_fn then
				test_fn()
			else
				vim.notify("Unknown test: " .. opts.args, vim.log.levels.ERROR)
			end
		else
			M.test.all()
		end
	end, {
		nargs = "?",
		desc = "Test notification providers",
		complete = function()
			return vim.tbl_keys(M.test)
		end,
	})

	-- ===========================================================================
	-- Daily Digests
	-- ===========================================================================

	cmd("DigestSend", function()
		local success, msg = M.digest.send_now()
		vim.notify(msg, success and vim.log.levels.INFO or vim.log.levels.ERROR)
	end, { desc = "Send daily digest email now" })

	cmd("DigestPreview", function()
		M.digest.preview()
	end, { desc = "Preview daily digest" })

	-- ===========================================================================
	-- Pomodoro
	-- ===========================================================================

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

	-- ===========================================================================
	-- Timers
	-- ===========================================================================

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
	end, { nargs = "*", desc = "Start a timer" })

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

	-- ===========================================================================
	-- Alarms
	-- ===========================================================================

	cmd("Alarm", function(opts)
		local args = opts.args

		-- No arguments - show list
		if args == "" then
			local alarms = M.alarm.list()
			if #alarms == 0 then
				vim.notify("No active alarms", vim.log.levels.INFO)
			else
				local lines = { "Active alarms:" }
				for _, alarm in ipairs(alarms) do
					local status = ""
					if alarm.options and alarm.options.repeat_mode and alarm.options.repeat_mode ~= "none" then
						status = " (" .. alarm.options.repeat_mode .. ")"
					end
					table.insert(
						lines,
						string.format(
							"  %s: %s - %s%s",
							alarm.id:sub(-8),
							alarm.name or "Unnamed",
							alarm.time_formatted,
							status
						)
					)
				end
				vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
			end
			return
		end

		-- Parse the command
		local first_word = args:match("^(%S+)")

		-- Handle subcommands
		if first_word == "list" or first_word == "ls" then
			vim.cmd(Config.commands.prefix .. "AlarmList")
		elseif first_word == "remove" or first_word == "rm" then
			local id = args:match("^%S+%s+(.+)")
			if id then
				local success, err = M.alarm.remove(id)
				if not success then
					vim.notify(err, vim.log.levels.ERROR)
				end
			else
				vim.notify("Usage: alarm remove <id or name>", vim.log.levels.ERROR)
			end
		elseif first_word == "snooze" then
			local id, duration = args:match("^%S+%s+(%S+)%s*(%S*)")
			if id then
				local success, err = M.alarm.snooze(id, tonumber(duration))
				if not success then
					vim.notify(err, vim.log.levels.ERROR)
				end
			else
				vim.notify("Usage: alarm snooze <id> [minutes]", vim.log.levels.ERROR)
			end
		elseif first_word == "dismiss" then
			local id = args:match("^%S+%s+(.+)")
			if id then
				local success, err = M.alarm.dismiss(id)
				if not success then
					vim.notify(err, vim.log.levels.ERROR)
				end
			else
				vim.notify("Usage: alarm dismiss <id>", vim.log.levels.ERROR)
			end
		-- Quick presets
		elseif
			first_word == "morning"
			or first_word == "workday"
			or first_word == "lunch"
			or first_word == "evening"
			or first_word == "bedtime"
		then
			local name = args:match("^%S+%s+(.+)")
			local id, err = M.alarm.quick_alarm(first_word, name)
			if not id then
				vim.notify(err, vim.log.levels.ERROR)
			end
		else
			-- Intelligent parsing for setting alarms
			local time_pattern = "(%d+[mhd])" -- duration
			local clock_pattern = "(%d%d?:%d%d%s*[ap]?m?)" -- time
			local repeat_pattern = "(daily|weekdays|weekends|weekly|monthly|yearly)"

			local duration = args:match(time_pattern)
			local clock_time = args:match(clock_pattern)
			local repeat_mode = args:match(repeat_pattern)

			-- Extract name (everything except patterns)
			local name = args
			if duration then
				name = name:gsub(time_pattern, "")
			end
			if clock_time then
				name = name:gsub(clock_pattern, "")
			end
			if repeat_mode then
				name = name:gsub(repeat_pattern, "")
			end
			name = vim.trim(name)
			if name == "" then
				name = nil
			end

			-- Determine time input
			local time_input = duration or clock_time or first_word

			-- Set the alarm
			local options = {}
			if repeat_mode then
				options.repeat_mode = repeat_mode
			end

			local id, err = M.alarm.set(time_input, name, options)
			if not id then
				vim.notify("Failed to set alarm: " .. (err or "invalid format"), vim.log.levels.ERROR)
			end
		end
	end, { nargs = "*", desc = "Smart alarm command" })

	cmd("AlarmList", function()
		local alarms = M.alarm.list()
		if #alarms == 0 then
			vim.notify("No active alarms", vim.log.levels.INFO)
			return
		end

		-- Create formatted display
		local lines = {
			"╭─ Active Alarms ─────────────────────────────────────╮",
		}
		for _, alarm in ipairs(alarms) do
			local repeat_str = alarm.repeat_mode ~= "none" and " (" .. alarm.repeat_mode .. ")" or ""
			table.insert(
				lines,
				string.format(
					"│ %-8s │ %-20s │ %s%s",
					alarm.id:sub(-8),
					(alarm.name or "Unnamed"):sub(1, 20),
					alarm.time_formatted,
					repeat_str
				)
			)
			if alarm.time_until > 0 then
				table.insert(
					lines,
					string.format("│          │ %-20s │ %s", "", "In " .. alarm.time_until_formatted)
				)
			end
			table.insert(
				lines,
				"├─────────────────────────────────────────────────────┤"
			)
		end
		lines[#lines] =
			"╰─────────────────────────────────────────────────────╯"

		-- Create buffer to display
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
		vim.api.nvim_buf_set_option(buf, "buftype", "nofile")

		-- Open in floating window
		local width = 55
		local height = #lines
		local win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			col = (vim.o.columns - width) / 2,
			row = (vim.o.lines - height) / 2,
			style = "minimal",
			border = "rounded",
		})

		-- Close on key press
		vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", { silent = true })
		vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { silent = true })
	end, { desc = "List all alarms" })
end

return M
