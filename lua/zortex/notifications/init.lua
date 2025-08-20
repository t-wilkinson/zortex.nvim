-- notifications/init.lua - Public API for the notification system
local M = {}

local manager = require("zortex.notifications.manager")
local pomodoro = require("zortex.notifications.types.pomodoro")
local alarm = require("zortex.notifications.types.alarm")
local timer = require("zortex.notifications.types.timer")
local calendar = require("zortex.notifications.types.calendar")
local digest = require("zortex.notifications.types.digest")

-- Initialize the notification system
function M.setup(opts) -- Config.notifications
	manager.setup(opts)
	pomodoro.setup(opts.pomodoro)
	timer.setup(opts.timers)
	calendar.setup(opts)
	digest.setup(opts.digest)
	alarm.setup(opts.alarm)

	M.setup_commands()
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

function M.setup_commands()
	local Config = require("zortex.config")

	local function cmd(name, command, options)
		vim.api.nvim_create_user_command(Config.commands.prefix .. name, command, options)
	end

	-- ===========================================================================
	-- Core notifications
	-- ===========================================================================
	-- Calendar sync
	cmd("NotificationSync", function()
		M.calendar.sync()
	end, { desc = "Sync calendar notifications" })

	-- Test notifications
	cmd("TestNotifications", function()
		M.test.all()
	end, { desc = "Test all notification providers" })

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

		-- No arguments - show status/list
		if args == "" then
			local alarms = M.alarm.list()
			if #alarms == 0 then
				vim.notify("No active alarms", vim.log.levels.INFO)
			else
				local lines = { "Active alarms:" }
				for _, alarm in ipairs(alarms) do
					local status = alarm.snoozed and " (snoozed)" or ""
					table.insert(
						lines,
						string.format("  %s: %s - %s%s", alarm.id:sub(1, 8), alarm.name, alarm.time_formatted, status)
					)
				end
				vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
			end
			return
		end

		-- Parse the command
		local first_word = args:match("^(%S+)")

		-- Check for action keywords
		if first_word == "list" or first_word == "ls" then
			vim.cmd(Config.commands.prefix .. "AlarmList")
		elseif first_word == "remove" or first_word == "rm" or first_word == "delete" then
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
		elseif first_word == "edit" then
			local id = args:match("^%S+%s+(%S+)")
			if id then
				vim.notify("Edit alarm functionality - use specific commands", vim.log.levels.INFO)
			else
				vim.notify("Usage: alarm edit <id>", vim.log.levels.ERROR)
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
			local date_pattern = "(%d%d%d%d%-?%d%d%-?%d%d)" -- date
			local tomorrow_pattern = "(tomorrow)"
			local repeat_pattern = "(daily|weekdays|weekends|weekly|monthly|yearly)"

			-- Extract components
			local duration = args:match(time_pattern)
			local clock_time = args:match(clock_pattern)
			local date = args:match(date_pattern)
			local tomorrow = args:match(tomorrow_pattern)
			local repeat_mode = args:match(repeat_pattern)

			-- Remove extracted patterns to get the name
			local name = args
			if duration then
				name = name:gsub(time_pattern, "")
			end
			if clock_time then
				name = name:gsub(clock_pattern, "")
			end
			if date then
				name = name:gsub(date_pattern, "")
			end
			if tomorrow then
				name = name:gsub(tomorrow_pattern, "")
			end
			if repeat_mode then
				name = name:gsub(repeat_pattern, "")
			end
			name = vim.trim(name)
			if name == "" then
				name = nil
			end

			-- Determine time input
			local time_input
			if duration then
				time_input = duration
			elseif clock_time then
				if tomorrow then
					-- Get tomorrow's date
					local tomorrow_date = require("zortex.utils.datetime").add_days(
						require("zortex.utils.datetime").get_current_date(),
						1
					)
					time_input = string.format(
						"%04d-%02d-%02d %s",
						tomorrow_date.year,
						tomorrow_date.month,
						tomorrow_date.day,
						clock_time
					)
				else
					time_input = clock_time
				end
			elseif date then
				time_input = date
			else
				-- Try to parse the whole thing as a time
				time_input = first_word
			end

			-- Set the alarm
			local options = {}
			if repeat_mode then
				options.repeat_mode = repeat_mode
			end

			local id, err = M.alarm.set(time_input, name, options)
			if not id then
				vim.notify("Failed to set alarm: " .. (err or "invalid format"), vim.log.levels.ERROR)
				vim.notify("Examples: '30m', '14:30', 'tomorrow 9am meeting', 'daily 7am wake up'", vim.log.levels.INFO)
			end
		end
	end, { nargs = "*", desc = "Smart alarm command" })

	-- Specific alarm commands
	cmd("AlarmSet", function(opts)
		local args = vim.split(opts.args, " ", { plain = false, trimempty = true })
		if #args < 1 then
			vim.notify("Usage: ZortexAlarmSet <time> [name] [options]", vim.log.levels.ERROR)
			return
		end

		local time = args[1]
		local name = args[2]
		local options = {}

		-- Parse additional options
		for i = 3, #args do
			if args[i]:match("^repeat=") then
				options.repeat_mode = args[i]:match("^repeat=(.+)")
			elseif args[i]:match("^snooze=") then
				options.snooze_duration = tonumber(args[i]:match("^snooze=(%d+)"))
			end
		end

		local id, err = M.alarm.set(time, name, options)
		if not id then
			vim.notify("Failed to set alarm: " .. err, vim.log.levels.ERROR)
		end
	end, { nargs = "+", desc = "Set an alarm" })

	cmd("AlarmList", function()
		local alarms = M.alarm.list()
		if #alarms == 0 then
			vim.notify("No active alarms", vim.log.levels.INFO)
			return
		end

		-- Create a nice formatted display
		local lines = {
			"╭─ Active Alarms ─────────────────────────────────────╮",
		}
		for _, alarm in ipairs(alarms) do
			local repeat_str = alarm.repeat_mode ~= "none" and " (" .. alarm.repeat_mode .. ")" or ""
			local status = alarm.snoozed and " [SNOOZED]" or ""
			table.insert(
				lines,
				string.format(
					"│ %-8s │ %-20s │ %s%s%s",
					alarm.id:sub(-8),
					alarm.name:sub(1, 20),
					alarm.time_formatted,
					repeat_str,
					status
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

		-- Close on any key
		vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", { silent = true })
		vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { silent = true })
	end, { desc = "List all alarms" })

	cmd("AlarmRemove", function(opts)
		if opts.args == "" then
			vim.notify("Usage: ZortexAlarmRemove <alarm_id or name>", vim.log.levels.ERROR)
			return
		end

		local success, err = M.alarm.remove(opts.args)
		if not success then
			vim.notify(err, vim.log.levels.ERROR)
		end
	end, { nargs = "+", desc = "Remove an alarm" })

	cmd("AlarmSnooze", function(opts)
		local args = vim.split(opts.args, " ", { plain = false, trimempty = true })
		if #args < 1 then
			vim.notify("Usage: ZortexAlarmSnooze <alarm_id> [minutes]", vim.log.levels.ERROR)
			return
		end

		local id = args[1]
		local duration = tonumber(args[2])

		local success, err = M.alarm.snooze(id, duration)
		if not success then
			vim.notify(err, vim.log.levels.ERROR)
		end
	end, { nargs = "+", desc = "Snooze an alarm" })

	cmd("AlarmDismiss", function(opts)
		if opts.args == "" then
			vim.notify("Usage: ZortexAlarmDismiss <alarm_id>", vim.log.levels.ERROR)
			return
		end

		local success, err = M.alarm.dismiss(opts.args)
		if not success then
			vim.notify(err, vim.log.levels.ERROR)
		end
	end, { nargs = "+", desc = "Dismiss an alarm" })

	cmd("AlarmEdit", function(opts)
		local args = vim.split(opts.args, " ", { plain = false, trimempty = true })
		if #args < 2 then
			vim.notify("Usage: ZortexAlarmEdit <alarm_id> <field>=<value> ...", vim.log.levels.ERROR)
			vim.notify("Fields: name, time, repeat_mode, title, message", vim.log.levels.INFO)
			return
		end

		local id = args[1]
		local updates = {}

		for i = 2, #args do
			local field, value = args[i]:match("^(%w+)=(.+)")
			if field and value then
				updates[field] = value
			end
		end

		local success, err = M.alarm.edit(id, updates)
		if not success then
			vim.notify(err, vim.log.levels.ERROR)
		end
	end, { nargs = "+", desc = "Edit an alarm" })

	-- Quick preset commands
	cmd("AlarmMorning", function()
		M.alarm.quick_alarm("morning")
	end, { desc = "Set morning alarm (7:00 AM daily)" })

	cmd("AlarmWorkday", function()
		M.alarm.quick_alarm("workday")
	end, { desc = "Set workday alarm (9:00 AM weekdays)" })
end

return M
