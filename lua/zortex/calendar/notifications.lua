local Utils = require("zortex.calendar.utils")
local Projects = require("zortex.old.projects")

local M = {}

-- =============================================================================
-- OS-specific Notification Helpers
-- =============================================================================

--- Detects the current operating system.
-- @return "macOS", "Linux", or "unknown"
local function get_os()
	local handle = io.popen("uname")
	if not handle then
		return "unknown"
	end
	local os_name = handle:read("*a"):gsub("%s*$", "")
	handle:close()
	if os_name == "Darwin" then
		return "macOS"
	elseif os_name == "Linux" then
		return "Linux"
	end
	return "unknown"
end

-- Detect the OS once at the start.
local detected_os = get_os()

--- Escape string for shell command
local function shell_escape(str)
	if detected_os == "macOS" then
		-- For macOS AppleScript, we need to escape backslashes and quotes
		str = str:gsub("\\", "\\\\") -- Escape backslashes first
		str = str:gsub('"', '\\"') -- Escape double quotes
		-- Replace newlines with literal \n for AppleScript
		str = str:gsub("\n", "\\n")
		-- Escape any other special characters
		str = str:gsub("\r", "\\r")
		str = str:gsub("\t", "\\t")
		return str
	elseif detected_os == "Linux" then
		-- For Linux notify-send, escape single quotes
		return str:gsub("'", "'\\''")
	end
	return str
end

--- Write string to temporary file (for complex notifications)
local function write_temp_file(content)
	local temp_file = os.tmpname()
	local file = io.open(temp_file, "w")
	if file then
		file:write(content)
		file:close()
		return temp_file
	end
	return nil
end

--- Shows an immediate notification.
-- @param title The notification title.
-- @param message The notification message.
-- @param options A table of options (e.g., for Linux notify-send).
local function show_instant_notification(title, message, options)
	options = options or {}
	local cmd

	if detected_os == "macOS" then
		-- Try multiple methods for macOS notifications

		-- Method 1: Try terminal-notifier if available (best option)
		local has_terminal_notifier = os.execute("command -v terminal-notifier >/dev/null 2>&1") == 0
		if has_terminal_notifier then
			local safe_title = title:gsub('"', '\\"'):gsub("'", "\\'")
			local safe_message = message:gsub('"', '\\"'):gsub("'", "\\'")
			-- terminal-notifier supports multi-line messages well
			cmd = string.format('terminal-notifier -title "%s" -message "%s" -sound default', safe_title, safe_message)
			os.execute(cmd)
			return
		end

		-- Method 2: Try alerter if available (good alternative)
		local has_alerter = os.execute("command -v alerter >/dev/null 2>&1") == 0
		if has_alerter then
			local safe_title = title:gsub('"', '\\"')
			local safe_message = message:gsub('"', '\\"')
			cmd = string.format('alerter -title "%s" -message "%s" -timeout 10', safe_title, safe_message)
			os.execute(cmd)
			return
		end

		-- Method 3: Use AppleScript with System Events (more reliable than display notification)
		-- This creates a dialog which is more visible but requires dismissal
		if options.use_dialog then
			local safe_message = message:gsub('"', '\\"'):gsub("'", "\\'"):gsub("\n", "\\n")
			cmd = string.format(
				[[osascript -e 'tell app "System Events" to display dialog "%s" with title "%s" buttons {"OK"} default button 1 giving up after 10']],
				safe_message,
				title
			)
			os.execute(cmd)
			return
		end

		-- Method 4: Create a notification using osascript with the Notification Center directly
		-- This approach uses the current app (Terminal/Kitty) as the sender
		local script = string.format(
			[[
tell application "System Events"
	set frontApp to name of first application process whose frontmost is true
end tell

tell application frontApp
	display notification "%s" with title "%s"
end tell
]],
			message:gsub('"', '\\"'):gsub("\n", " - "),
			title:gsub('"', '\\"')
		)

		local temp_file = write_temp_file(script)
		if temp_file then
			cmd = string.format("osascript %s; rm -f %s", temp_file, temp_file)
			os.execute(cmd)
			return
		end

		-- Fallback: Try basic display notification
		local safe_title = shell_escape(title)
		local safe_message = shell_escape(message:gsub("\n", " - "))
		cmd = string.format('osascript -e \'display notification "%s" with title "%s"\'', safe_message, safe_title)
		os.execute(cmd)

		-- Also show in Neovim as a backup
		vim.schedule(function()
			vim.notify(string.format("%s: %s", title, message:gsub("\n", " | ")), vim.log.levels.INFO)
		end)
	elseif detected_os == "Linux" then
		-- On Linux, use notify-send (it handles multi-line well)
		local urgency = options.urgency or "normal"
		local timeout = options.timeout or 10000
		local safe_title = shell_escape(title)
		local safe_message = shell_escape(message)
		cmd = string.format("notify-send -u %s -t %d '%s' '%s'", urgency, timeout, safe_title, safe_message)
		os.execute(cmd)
	else
		-- If the OS is not supported, show in Neovim
		vim.schedule(function()
			vim.notify(string.format("%s: %s", title, message), vim.log.levels.INFO)
		end)
		return
	end
end

--- Schedules a notification to be sent after a delay.
-- @param delay_seconds The delay in seconds.
-- @param title The notification title.
-- @param message The notification message.
local function schedule_notification(delay_seconds, title, message)
	local notification_cmd

	if detected_os == "macOS" then
		-- Check for terminal-notifier first
		local has_terminal_notifier = os.execute("command -v terminal-notifier >/dev/null 2>&1") == 0
		if has_terminal_notifier then
			local safe_title = title:gsub('"', '\\"'):gsub("'", "\\'")
			local safe_message = message:gsub('"', '\\"'):gsub("'", "\\'")
			notification_cmd =
				string.format('terminal-notifier -title "%s" -message "%s" -sound default', safe_title, safe_message)
		else
			-- Fallback to osascript
			if message:find("\n") then
				message = message:gsub("\n", " - ")
			end
			local safe_title = shell_escape(title)
			local safe_message = shell_escape(message)

			notification_cmd =
				string.format('osascript -e \'display notification "%s" with title "%s"\'', safe_message, safe_title)
		end
	elseif detected_os == "Linux" then
		-- On Linux, use notify-send
		local safe_title = shell_escape(title)
		local safe_message = shell_escape(message)
		notification_cmd = string.format("notify-send '%s' '%s'", safe_title, safe_message)
	else
		-- If the OS is not supported, we do nothing.
		return
	end

	-- Schedule the notification
	local full_cmd = string.format("(sleep %d && %s) &", delay_seconds, notification_cmd)
	os.execute(full_cmd)
end

-- =============================================================================
-- Enhanced Notification Functions
-- =============================================================================

--- Parse notification durations (extended to support days)
local function parse_notification_durations(notify_str)
	if not notify_str then
		return { 0 } -- Default: notify at event time
	end

	local durations = {}
	for dur in notify_str:gmatch("([^,]+)") do
		dur = dur:match("^%s*(.-)%s*$") -- trim

		-- Check for special values first
		if dur == "0" then
			table.insert(durations, 0)
		else
			-- Parse duration with units
			local num, unit = dur:match("^(%d+%.?%d*)%s*(%w+)$")
			if not num then
				num, unit = dur:match("^(%d+%.?%d*)(%w+)$")
			end

			if num then
				num = tonumber(num)
				unit = unit:lower()

				-- Convert to minutes
				local mins = nil
				if unit == "m" or unit == "min" or unit == "mins" or unit == "minute" or unit == "minutes" then
					mins = num
				elseif unit == "h" or unit == "hr" or unit == "hrs" or unit == "hour" or unit == "hours" then
					mins = num * 60
				elseif unit == "d" or unit == "day" or unit == "days" then
					mins = num * 60 * 24
				elseif unit == "w" or unit == "week" or unit == "weeks" then
					mins = num * 60 * 24 * 7
				end

				if mins then
					table.insert(durations, mins)
				end
			end
		end
	end

	return #durations > 0 and durations or { 0 }
end

--- Get the datetime for an entry (considering various attributes)
local function get_entry_datetime(entry, effective_date)
	local date_str = effective_date or entry.date_context
	local date_obj = Utils.parse_date(date_str)
	if not date_obj then
		return nil
	end

	-- Default to midnight
	date_obj.hour = 0
	date_obj.min = 0
	date_obj.sec = 0

	-- Check various time attributes
	local time_str = nil

	-- For time ranges, use the start time
	if entry.attributes.from then
		time_str = entry.attributes.from
	elseif entry.attributes.at then
		time_str = entry.attributes.at
	elseif entry.attributes.notify then
		-- If notify has a full datetime, parse it
		local dt = M.parse_datetime(entry.attributes.notify, date_str)
		if dt then
			return dt
		end
	elseif entry.attributes.due then
		-- If due has a full datetime, parse it
		local dt = M.parse_datetime(entry.attributes.due, date_str)
		if dt then
			return dt
		end
	end

	if time_str then
		local time = Utils.parse_time(time_str)
		if time then
			date_obj.hour = time.hour
			date_obj.min = time.min
		end
	end

	return date_obj
end

--- Format duration for display
local function format_duration(duration_mins)
	if duration_mins == 0 then
		return "now"
	elseif duration_mins < 60 then
		return string.format("%d minute%s", duration_mins, duration_mins == 1 and "" or "s")
	elseif duration_mins < 1440 then
		local hours = duration_mins / 60
		if hours == math.floor(hours) then
			return string.format("%d hour%s", hours, hours == 1 and "" or "s")
		else
			return string.format("%.1f hours", hours)
		end
	else
		local days = duration_mins / 1440
		if days == math.floor(days) then
			return string.format("%d day%s", days, days == 1 and "" or "s")
		else
			return string.format("%.1f days", days)
		end
	end
end

--- Check if notification should be part of daily digest
local function is_digest_notification(duration_mins)
	-- Notifications 1 day or more in advance go to daily digest
	return duration_mins >= 1440
end

--- Get daily digest time for a specific date
local function get_digest_time(date_str)
	local digest_time_str = "09:00"
	local date_obj = Utils.parse_date(date_str)
	if not date_obj then
		return nil
	end

	local time = Utils.parse_time(digest_time_str)
	if time then
		date_obj.hour = time.hour
		date_obj.min = time.min
		date_obj.sec = 0
		return os.time(date_obj)
	end

	-- Default to 9 AM if parsing fails
	date_obj.hour = 9
	date_obj.min = 0
	date_obj.sec = 0
	return os.time(date_obj)
end

--- Setup system notifications for all future events
function M.setup_notifications()
	local state = Utils.load()
	local now = os.time()
	local notifications_scheduled = 0
	local digest_notifications = {} -- Group by date for digest

	-- Process all entries
	for date_str, entries in pairs(state.parsed_data) do
		for _, entry in ipairs(entries) do
			if entry.attributes.notification_enabled then
				local base_dt = get_entry_datetime(entry)
				if base_dt then
					local base_time = os.time(base_dt)

					-- Process each notification duration
					for _, duration_mins in ipairs(entry.attributes.notification_durations) do
						local notify_time = base_time - (duration_mins * 60)

						if notify_time > now then
							if is_digest_notification(duration_mins) then
								-- Add to digest for the notification date
								local notify_date = os.date("%Y-%m-%d", notify_time)
								if not digest_notifications[notify_date] then
									digest_notifications[notify_date] = {}
								end

								table.insert(digest_notifications[notify_date], {
									entry = entry,
									event_time = base_time,
									duration_mins = duration_mins,
									display_text = entry.display_text,
								})
							else
								-- Schedule individual notification
								local delay = notify_time - now

								-- Format notification message
								local title = "Zortex Reminder"
								local message = entry.display_text

								if duration_mins > 0 then
									title = string.format("Zortex: In %s", format_duration(duration_mins))
								end

								-- Add time information if available
								if entry.attributes.at or entry.attributes.from then
									local time_str = entry.attributes.at or entry.attributes.from
									message = string.format("%s - %s", time_str, message)
								end

								schedule_notification(delay, title, message)
								notifications_scheduled = notifications_scheduled + 1
							end
						end
					end
				end
			end
		end

		-- Also check for recurring events
		local date_obj = Utils.parse_date(date_str)
		if date_obj then
			for _, entry in ipairs(entries) do
				if entry.attributes.repeating and entry.attributes.notification_enabled then
					-- Calculate next occurrences for the next 7 days
					local base_time = os.time(date_obj)
					local check_until = now + (7 * 86400)

					-- Get the event time on the original date
					local entry_dt = get_entry_datetime(entry)
					if entry_dt then
						local current_time = base_time

						while current_time <= check_until do
							-- Skip if in the past
							if current_time > now then
								-- Set the time component
								local next_dt = os.date("*t", current_time)
								next_dt.hour = entry_dt.hour
								next_dt.min = entry_dt.min
								next_dt.sec = 0
								local event_time = os.time(next_dt)

								-- Process notification durations
								for _, duration_mins in ipairs(entry.attributes.notification_durations) do
									local notify_time = event_time - (duration_mins * 60)

									if notify_time > now then
										if is_digest_notification(duration_mins) then
											-- Add to digest
											local notify_date = os.date("%Y-%m-%d", notify_time)
											if not digest_notifications[notify_date] then
												digest_notifications[notify_date] = {}
											end

											table.insert(digest_notifications[notify_date], {
												entry = entry,
												event_time = event_time,
												duration_mins = duration_mins,
												display_text = entry.display_text .. " (Recurring)",
											})
										else
											-- Schedule individual notification
											local delay = notify_time - now
											local title = "Zortex Reminder (Recurring)"
											local message = entry.display_text

											if duration_mins > 0 then
												title = string.format("Zortex: In %s", format_duration(duration_mins))
											end

											if entry.attributes.at or entry.attributes.from then
												local time_str = entry.attributes.at or entry.attributes.from
												message = string.format("%s - %s", time_str, message)
											end

											schedule_notification(delay, title, message)
											notifications_scheduled = notifications_scheduled + 1
										end
									end
								end
							end

							-- Move to next occurrence
							if entry.attributes.repeating:lower() == "daily" then
								current_time = current_time + 86400
							elseif entry.attributes.repeating:lower() == "weekly" then
								current_time = current_time + (7 * 86400)
							else
								break
							end
						end
					end
				end
			end
		end
	end

	-- Schedule daily digests
	for digest_date, notifications in pairs(digest_notifications) do
		local digest_time = get_digest_time(digest_date)
		if digest_time and digest_time > now then
			local delay = digest_time - now

			-- Build digest message
			local lines = {}

			-- Sort notifications by event time
			table.sort(notifications, function(a, b)
				return a.event_time < b.event_time
			end)

			-- Group by how far in advance
			local today_events = {}
			local tomorrow_events = {}
			local later_events = {}

			for _, notif in ipairs(notifications) do
				local event_date = os.date("%Y-%m-%d", notif.event_time)
				local days_until = math.floor((notif.event_time - digest_time) / 86400)

				local event_info = {
					time = os.date("%H:%M", notif.event_time),
					text = notif.display_text,
					date = event_date,
				}

				if days_until == 0 then
					table.insert(today_events, event_info)
				elseif days_until == 1 then
					table.insert(tomorrow_events, event_info)
				else
					event_info.days = days_until
					table.insert(later_events, event_info)
				end
			end

			-- Schedule daily digests
			local delay = digest_time - now

			-- Build digest message (simplified for notifications)
			local event_count = #today_events + #tomorrow_events + #later_events
			local message = string.format("%d upcoming events", event_count)

			-- Add first few events as preview
			local preview_items = {}
			if #today_events > 0 then
				table.insert(preview_items, string.format("Today: %d", #today_events))
			end
			if #tomorrow_events > 0 then
				table.insert(preview_items, string.format("Tomorrow: %d", #tomorrow_events))
			end
			if #later_events > 0 then
				table.insert(preview_items, string.format("Later: %d", #later_events))
			end

			if #preview_items > 0 then
				message = message .. " (" .. table.concat(preview_items, ", ") .. ")"
			end

			-- Add the next event as preview
			if #today_events > 0 then
				message = message .. ". Next: " .. today_events[1].text
			elseif #tomorrow_events > 0 then
				message = message .. ". Tomorrow: " .. tomorrow_events[1].text
			end

			local title = "Zortex Daily Digest"

			schedule_notification(delay, title, message)
			notifications_scheduled = notifications_scheduled + 1
		end
	end

	return notifications_scheduled
end

--- Show today's digest notification immediately
function M.show_today_digest()
	Utils.load()
	Projects.load()

	local today = os.date("%Y-%m-%d")
	local entries = Utils.get_entries_for_date(today)
	local project_tasks = Projects.get_tasks_for_date(today)

	-- Sort entries by time
	table.sort(entries, function(a, b)
		local time_a = a.attributes.at or a.attributes.from or "00:00"
		local time_b = b.attributes.at or b.attributes.from or "00:00"
		return time_a < time_b
	end)

	-- Build comprehensive digest
	local lines = {}

	-- Group entries
	local events = {}
	local tasks = {}
	local notes = {}

	for _, entry in ipairs(entries) do
		if entry.type == "task" then
			table.insert(tasks, entry)
		elseif entry.type == "event" or entry.attributes.notification_enabled then
			table.insert(events, entry)
		else
			table.insert(notes, entry)
		end
	end

	-- Check if we have terminal-notifier for rich notifications
	local has_terminal_notifier = detected_os == "macOS"
		and os.execute("command -v terminal-notifier >/dev/null 2>&1") == 0

	if has_terminal_notifier or detected_os == "Linux" then
		-- Rich multi-line notification

		-- Add events
		if #events > 0 then
			table.insert(lines, "📅 EVENTS")
			for _, entry in ipairs(events) do
				local line = ""
				if entry.attributes.from and entry.attributes.to then
					line = string.format("%s-%s %s", entry.attributes.from, entry.attributes.to, entry.display_text)
				elseif entry.attributes.at then
					line = string.format("%s - %s", entry.attributes.at, entry.display_text)
				else
					line = entry.display_text
				end

				if entry.is_recurring_instance then
					line = line .. " 🔁"
				end

				table.insert(lines, "  " .. line)
			end
		end

		-- Add tasks
		if #tasks > 0 then
			if #lines > 0 then
				table.insert(lines, "")
			end
			table.insert(lines, "✓ TASKS")

			local pending_tasks = {}
			local completed_tasks = {}

			for _, entry in ipairs(tasks) do
				if entry.task_status and entry.task_status.key == "[x]" then
					table.insert(completed_tasks, entry)
				else
					table.insert(pending_tasks, entry)
				end
			end

			-- Show pending tasks first
			for _, entry in ipairs(pending_tasks) do
				local status = entry.task_status and entry.task_status.symbol or "☐"
				local line = status .. " "

				if entry.attributes.at then
					line = line .. entry.attributes.at .. " - "
				end

				line = line .. entry.display_text

				if entry.is_due_date_instance then
					line = line .. " 📅"
				end

				table.insert(lines, "  " .. line)
			end

			-- Show completed tasks
			if #completed_tasks > 0 then
				table.insert(lines, "  ---")
				for _, entry in ipairs(completed_tasks) do
					local line = "☑ " .. entry.display_text
					table.insert(lines, "  " .. line)
				end
			end
		end

		-- Add project tasks
		if #project_tasks > 0 then
			if #lines > 0 then
				table.insert(lines, "")
			end
			table.insert(lines, "📁 PROJECT TASKS")
			for _, task in ipairs(project_tasks) do
				local status = task.task_status and task.task_status.symbol or "☐"
				local line = status .. " "

				if task.attributes.at then
					line = line .. task.attributes.at .. " - "
				end

				line = line .. task.display_text .. " [" .. task.project .. "]"
				table.insert(lines, "  " .. line)
			end
		end

		-- Add notes
		if #notes > 0 then
			if #lines > 0 then
				table.insert(lines, "")
			end
			table.insert(lines, "📝 NOTES")
			for _, entry in ipairs(notes) do
				table.insert(lines, "  • " .. entry.display_text)
			end
		end

		-- Add summary
		if #lines == 0 then
			table.insert(lines, "No events or tasks for today")
			table.insert(lines, "Enjoy your free day! 🎉")
		else
			if #lines > 0 then
				table.insert(lines, "")
			end
			local total = #events + #tasks + #project_tasks + #notes
			table.insert(lines, string.format("Total: %d items for today", total))
		end

		local title = "Zortex Daily Digest - " .. os.date("%A, %B %d")
		local message = table.concat(lines, "\n")

		show_instant_notification(title, message, { urgency = "normal", timeout = 15000 })
	else
		-- Simplified notification for basic osascript

		-- Count items
		local event_count = #events
		local task_count = #tasks
		local completed_count = 0
		local project_task_count = #project_tasks

		for _, task in ipairs(tasks) do
			if task.task_status and task.task_status.key == "[x]" then
				completed_count = completed_count + 1
			end
		end

		local title = "Zortex Daily Digest"
		local message = ""

		if event_count == 0 and task_count == 0 and project_task_count == 0 then
			message = "No events or tasks for today. Enjoy your free day!"
		else
			local parts = {}

			if event_count > 0 then
				table.insert(parts, string.format("%d event%s", event_count, event_count == 1 and "" or "s"))
			end

			if task_count > 0 then
				local task_str = string.format("%d task%s", task_count, task_count == 1 and "" or "s")
				if completed_count > 0 then
					task_str = task_str .. string.format(" (%d done)", completed_count)
				end
				table.insert(parts, task_str)
			end

			if project_task_count > 0 then
				table.insert(
					parts,
					string.format("%d project task%s", project_task_count, project_task_count == 1 and "" or "s")
				)
			end

			message = "Today: " .. table.concat(parts, ", ")

			-- Add the next item as a preview
			local next_item = nil
			local next_time = "24:00"

			-- Find the next upcoming item
			for _, entry in ipairs(entries) do
				local entry_time = entry.attributes.at or entry.attributes.from or "23:59"
				if entry_time < next_time and not (entry.task_status and entry.task_status.key == "[x]") then
					next_time = entry_time
					next_item = entry
				end
			end

			if next_item then
				local time_str = ""
				if next_item.attributes.from and next_item.attributes.to then
					time_str = string.format(" (%s-%s)", next_item.attributes.from, next_item.attributes.to)
				elseif next_item.attributes.at then
					time_str = string.format(" at %s", next_item.attributes.at)
				end
				message = message .. ". Next: " .. next_item.display_text .. time_str
			end
		end

		show_instant_notification(title, message, { urgency = "normal", timeout = 10000 })

		-- Also suggest installing terminal-notifier
		vim.schedule(function()
			vim.notify(
				"For richer notifications, install terminal-notifier: brew install terminal-notifier",
				vim.log.levels.INFO
			)
		end)
	end
end

--- Show detailed digest in a buffer (alternative to notification)
function M.show_digest_buffer()
	Utils.load()

	local today = os.date("%Y-%m-%d")
	local entries = Utils.get_entries_for_date(today)

	-- Sort entries by time
	table.sort(entries, function(a, b)
		local time_a = a.attributes.at or a.attributes.from or "00:00"
		local time_b = b.attributes.at or b.attributes.from or "00:00"
		return time_a < time_b
	end)

	-- Build buffer content
	local lines = {
		"════════════════════════════════════════════════════",
		"                ZORTEX DAILY DIGEST                 ",
		"                " .. os.date("%A, %B %d, %Y"),
		"════════════════════════════════════════════════════",
		"",
	}

	-- Group entries
	local events = {}
	local tasks = {}
	local notes = {}

	for _, entry in ipairs(entries) do
		if entry.type == "task" then
			table.insert(tasks, entry)
		elseif entry.type == "event" or entry.attributes.notification_enabled then
			table.insert(events, entry)
		else
			table.insert(notes, entry)
		end
	end

	-- Add events
	if #events > 0 then
		table.insert(lines, "📅 EVENTS & APPOINTMENTS")
		table.insert(lines, "────────────────────────")
		for _, entry in ipairs(events) do
			local line = ""
			if entry.attributes.from and entry.attributes.to then
				line = string.format("%s-%s  %s", entry.attributes.from, entry.attributes.to, entry.display_text)
			elseif entry.attributes.at then
				line = string.format("%s      %s", entry.attributes.at, entry.display_text)
			else
				line = "         " .. entry.display_text
			end

			if entry.is_recurring_instance then
				line = line .. " 🔁"
			end

			table.insert(lines, line)
		end
		table.insert(lines, "")
	end

	-- Add tasks
	if #tasks > 0 then
		table.insert(lines, "✓ TASKS")
		table.insert(lines, "────────────────────────")
		for _, entry in ipairs(tasks) do
			local status = entry.task_status and entry.task_status.symbol or "☐"
			local line = status .. " "

			if entry.attributes.at then
				line = line .. entry.attributes.at .. "  "
			else
				line = line .. "       "
			end

			line = line .. entry.display_text

			if entry.is_due_date_instance then
				line = line .. " 📅"
			end

			table.insert(lines, line)
		end
		table.insert(lines, "")
	end

	-- Add project tasks
	Projects.load()
	local project_tasks = Projects.get_tasks_for_date(today)
	if #project_tasks > 0 then
		table.insert(lines, "📁 PROJECT TASKS")
		table.insert(lines, "────────────────────────")
		for _, task in ipairs(project_tasks) do
			local status = task.task_status and task.task_status.symbol or "☐"
			local line = status .. " "

			if task.attributes.at then
				line = line .. task.attributes.at .. "  "
			else
				line = line .. "       "
			end

			line = line .. task.display_text
			line = line .. " [" .. task.project .. "]"

			table.insert(lines, line)
		end
		table.insert(lines, "")
	end

	-- Add notes
	if #notes > 0 then
		table.insert(lines, "📝 NOTES")
		table.insert(lines, "────────────────────────")
		for _, entry in ipairs(notes) do
			table.insert(lines, "• " .. entry.display_text)
		end
		table.insert(lines, "")
	end

	-- Add upcoming preview
	table.insert(lines, "")
	table.insert(lines, "🔮 COMING UP THIS WEEK")
	table.insert(lines, "────────────────────────")

	local upcoming_count = 0
	for days = 1, 7 do
		local date = os.date("%Y-%m-%d", os.time() + (days * 86400))
		local date_entries = Utils.get_entries_for_date(date)
		local date_tasks = Projects.get_tasks_for_date(date)

		if #date_entries > 0 or #date_tasks > 0 then
			upcoming_count = upcoming_count + 1
			local day_name = os.date("%A", os.time() + (days * 86400))
			local total = #date_entries + #date_tasks
			table.insert(lines, string.format("%s: %d item%s", day_name, total, total == 1 and "" or "s"))

			-- Show first event of that day
			for _, entry in ipairs(date_entries) do
				if entry.type == "event" or entry.attributes.notification_enabled then
					local time_str = ""
					if entry.attributes.at then
						time_str = " at " .. entry.attributes.at
					end
					table.insert(lines, "  → " .. entry.display_text .. time_str)
					break
				end
			end
		end
	end

	if upcoming_count == 0 then
		table.insert(lines, "No scheduled events in the next 7 days")
	end

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
	vim.api.nvim_buf_set_name(buf, "Zortex Daily Digest")

	-- Create window
	local width = math.min(60, vim.o.columns - 4)
	local height = math.min(#lines + 2, vim.o.lines - 4)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
		title = " Daily Digest ",
		title_pos = "center",
	})

	-- Set highlights
	vim.api.nvim_win_set_option(win, "cursorline", true)

	-- Key mappings
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { noremap = true, silent = true })
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", { noremap = true, silent = true })
end

--- Test notification system
function M.test_notification()
	-- Check for notification tools on macOS
	if detected_os == "macOS" then
		local has_terminal_notifier = os.execute("command -v terminal-notifier >/dev/null 2>&1") == 0
		local has_alerter = os.execute("command -v alerter >/dev/null 2>&1") == 0

		if not has_terminal_notifier and not has_alerter then
			-- Try basic notification anyway
			vim.schedule(function()
				vim.notify("Testing basic notification fallback...", vim.log.levels.INFO)
			end)
		end
	end

	local title = "Zortex Test"
	local message = "Notification system is working!\nThis is line 2\nAnd line 3"
	show_instant_notification(title, message)

	-- Test with special characters
	vim.schedule(function()
		vim.notify("Testing special characters...", vim.log.levels.INFO)
		show_instant_notification("Test 2", "Special chars: quotes \" and apostrophe ' work")
	end)

	-- Test scheduled notification
	vim.schedule(function()
		vim.notify("Scheduling test notification for 5 seconds from now...", vim.log.levels.INFO)
		schedule_notification(5, "Zortex Delayed Test", "This was scheduled 5 seconds ago")
	end)
end

--- Debug notification methods
function M.debug_notifications()
	vim.notify("Testing different notification methods...", vim.log.levels.INFO)

	if detected_os == "macOS" then
		-- Test 1: Direct osascript
		vim.notify("Test 1: Direct osascript...", vim.log.levels.INFO)
		os.execute([[osascript -e 'display notification "Test 1: Direct osascript" with title "Zortex Test"']])

		-- Test 2: Using current app
		vim.notify("Test 2: Using current app...", vim.log.levels.INFO)
		os.execute(
			[[osascript -e 'tell application "System Events" to display notification "Test 2: Via System Events" with title "Zortex Test"']]
		)

		-- Test 3: Terminal-notifier
		local has_tn = os.execute("command -v terminal-notifier >/dev/null 2>&1") == 0
		if has_tn then
			vim.notify("Test 3: terminal-notifier...", vim.log.levels.INFO)
			os.execute([[terminal-notifier -title "Zortex Test" -message "Test 3: terminal-notifier works!"]])
		else
			vim.notify("Test 3: terminal-notifier not installed", vim.log.levels.WARN)
		end

		-- Test 4: Dialog (should always work)
		vim.notify("Test 4: Dialog (press OK to continue)...", vim.log.levels.INFO)
		show_instant_notification("Zortex Test", "Test 4: Dialog method", { use_dialog = true })
	elseif detected_os == "Linux" then
		vim.notify("Testing Linux notify-send...", vim.log.levels.INFO)
		os.execute([[notify-send "Zortex Test" "Linux notifications working!"]])
	end

	-- Method 5: Play sound as notification (always works)
	vim.notify("Test 5: Sound notification...", vim.log.levels.INFO)
	os.execute([[afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || echo "Sound playback failed"]])

	vim.notify("If you heard a sound, that method works as a fallback", vim.log.levels.INFO)
end

--- Show today's digest as a dialog (always works on macOS)
function M.show_today_digest_dialog()
	if detected_os ~= "macOS" then
		M.show_today_digest()
		return
	end

	Utils.load()
	Projects.load()

	local today = os.date("%Y-%m-%d")
	local entries = Utils.get_entries_for_date(today)
	local project_tasks = Projects.get_tasks_for_date(today)

	-- Build summary
	local event_count = 0
	local task_count = 0
	local task_pending = 0

	for _, entry in ipairs(entries) do
		if entry.type == "task" then
			task_count = task_count + 1
			if not entry.task_status or entry.task_status.key ~= "[x]" then
				task_pending = task_pending + 1
			end
		elseif entry.type == "event" or entry.attributes.notification_enabled then
			event_count = event_count + 1
		end
	end

	-- Build message
	local lines = {
		os.date("Daily Digest - %A, %B %d"),
		"",
		string.format("Events: %d", event_count),
		string.format("Tasks: %d (%d pending)", task_count, task_pending),
		string.format("Project Tasks: %d", #project_tasks),
		"",
		"Use :ZortexDigest for full details",
	}

	local message = table.concat(lines, "\\n")
	local title = "Zortex Daily Digest"

	-- Show as dialog
	show_instant_notification(title, message, { use_dialog = true })
end

return M
