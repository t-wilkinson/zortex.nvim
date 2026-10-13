-- notifications/init.lua - Public API for the unified notification system
local M = {}

local manager = require("zortex.notifications.manager")
local pomodoro = require("zortex.notifications.types.pomodoro")
local calendar = require("zortex.notifications.types.calendar")

-- Initialize the notification system
function M.setup(opts)
	-- Setup the core manager first
	manager.setup(opts)

	-- Setup individual modules
	pomodoro.setup(opts.types.pomodoro, opts.providers)
	calendar.setup(opts.types.calendar)

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
M.pomodoro = pomodoro

-- Calendar functions
M.calendar = {
	sync = calendar.sync,
	get_pending_for_date = calendar.get_pending_for_date,
}

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
	pomodoro.cleanup()
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
				M.calendar.sync({ silent = true })
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
		vim.bo[buf].modifiable = false
		vim.bo[buf].buftype = "nofile"
		vim.cmd("split")
		vim.api.nvim_win_set_buf(0, buf)
	end, {
		nargs = "?",
		desc = "List scheduled notifications",
		complete = function()
			return { "calendar", "pomodoro" }
		end,
	})

	-- Calendar sync
	cmd("CalendarSync", function(opts)
		M.calendar.sync({
			force = opts.bang,
			on_done = function(msg)
				vim.notify(msg, vim.log.levels.INFO)
			end,
		})
	end, { bang = true, desc = "Sync calendar notifications (! resends even when unchanged)" })

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
	-- Pomodoro
	-- ===========================================================================

	cmd("PomodoroStart", function()
		M.pomodoro.start()
	end, { desc = "Start (or resume) the pomodoro" })

	cmd("PomodoroPause", function()
		M.pomodoro.toggle()
	end, { desc = "Pause / resume the pomodoro" })

	cmd("PomodoroSkip", function()
		M.pomodoro.skip()
	end, { desc = "End the current pomodoro phase now" })

	cmd("PomodoroStop", function()
		M.pomodoro.stop()
	end, { desc = "Stop the pomodoro" })

	cmd("PomodoroRestart", function()
		M.pomodoro.restart()
	end, { desc = "Begin a new pomodoro cycle" })

	cmd("PomodoroStatus", function()
		local function show()
			vim.notify(M.pomodoro.describe(), vim.log.levels.INFO, { title = "Pomodoro" })
		end
		if M.pomodoro.remote() then
			M.pomodoro.refresh(show)
		else
			show()
		end
	end, { desc = "Show pomodoro status" })

	-- :ZortexPomodoroSettings work=50 short=10 long=20 every=4 auto_break=yes auto_work=no
	cmd("PomodoroSettings", function(opts)
		local keys = {
			work = "work",
			short = "short_break",
			short_break = "short_break",
			long = "long_break",
			long_break = "long_break",
			every = "long_break_after",
			long_break_after = "long_break_after",
			auto_break = "auto_start_break",
			auto_start_break = "auto_start_break",
			auto_work = "auto_start_work",
			auto_start_work = "auto_start_work",
		}
		local changes = {}
		for _, arg in ipairs(opts.fargs) do
			local k, v = arg:match("^([%w_]+)=(%S+)$")
			local key = k and keys[k]
			if not key then
				vim.notify("Unknown setting: " .. arg, vim.log.levels.ERROR)
				return
			end
			if key:match("^auto") then
				changes[key] = v == "yes" or v == "true" or v == "1" or v == "on"
			else
				changes[key] = tonumber(v)
			end
		end
		if vim.tbl_isempty(changes) then
			local st = M.pomodoro.status()
			vim.notify(vim.inspect(st.settings or {}), vim.log.levels.INFO, { title = "Pomodoro settings" })
			return
		end
		M.pomodoro.update_settings(changes)
	end, {
		nargs = "*",
		desc = "Show or change pomodoro settings (work=25 short=5 long=15 every=4 auto_break=yes auto_work=no)",
		complete = function()
			return { "work=", "short=", "long=", "every=", "auto_break=", "auto_work=" }
		end,
	})
end

return M
