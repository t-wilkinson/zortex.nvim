local Utils = require("zortex.calendar.utils")

local M = {}

-- =============================================================================
-- Notification Functions
-- =============================================================================

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

	-- Check various time attributes
	local time_str = nil
	if entry.attributes.at then
		time_str = entry.attributes.at
	elseif entry.attributes.notify then
		-- If notify has time, use it
		local dt = Utils.parse_datetime(entry.attributes.notify, date_str)
		if dt then
			return dt
		end
	elseif entry.attributes.due then
		-- If due has time, use it
		local dt = Utils.parse_datetime(entry.attributes.due, date_str)
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

--- Setup system notifications for all future events
function M.setup_notifications()
	local state = M.load()

	local now = os.time()
	local notifications_scheduled = 0

	-- Get today's date string for comparison
	local today = os.date("%Y-%m-%d")

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
							-- Calculate delay in seconds
							local delay = notify_time - now

							-- Format notification message
							local title = "Zortex Reminder"
							local message = entry.display_text

							if duration_mins > 0 then
								local dur_str = ""
								if duration_mins < 60 then
									dur_str = string.format("%d minutes", duration_mins)
								elseif duration_mins < 1440 then
									dur_str = string.format("%.1f hours", duration_mins / 60)
								else
									dur_str = string.format("%.1f days", duration_mins / 1440)
								end
								title = string.format("Zortex: In %s", dur_str)
							end

							-- Schedule notification using 'at' command or systemd timer
							-- For simplicity, we'll use a background sleep + notify-send
							local cmd = string.format(
								"(sleep %d && notify-send '%s' '%s') &",
								delay,
								title:gsub("'", "'\\''"),
								message:gsub("'", "'\\''")
							)
							os.execute(cmd)
							notifications_scheduled = notifications_scheduled + 1
						end
					end
				end
			end
		end

		-- Also check for recurring events that might occur in the future
		-- This is a simplified version - you might want to expand this
		local date_obj = Utils.parse_date(date_str)
		if date_obj then
			for _, entry in ipairs(entries) do
				if entry.attributes.repeating and entry.attributes.notification_enabled then
					-- Calculate next occurrence
					local repeat_val = entry.attributes.repeating:lower()
					local base_time = os.time(date_obj)
					local next_time = base_time

					-- Find next occurrence after now
					while next_time <= now do
						if repeat_val == "daily" then
							next_time = next_time + 86400
						elseif repeat_val == "weekly" then
							next_time = next_time + (86400 * 7)
						else
							break
						end
					end

					if next_time > now and next_time < now + (86400 * 7) then -- Only schedule for next week
						local next_dt = os.date("*t", next_time)
						local entry_dt = get_entry_datetime(entry)
						if entry_dt then
							next_dt.hour = entry_dt.hour
							next_dt.min = entry_dt.min
							local notify_base = os.time(next_dt)

							for _, duration_mins in ipairs(entry.attributes.notification_durations) do
								local notify_time = notify_base - (duration_mins * 60)
								if notify_time > now then
									local delay = notify_time - now
									local title = "Zortex Reminder (Recurring)"
									local message = entry.display_text

									local cmd = string.format(
										"(sleep %d && notify-send '%s' '%s') &",
										delay,
										title:gsub("'", "'\\''"),
										message:gsub("'", "'\\''")
									)
									os.execute(cmd)
									notifications_scheduled = notifications_scheduled + 1
								end
							end
						end
					end
				end
			end
		end
	end

	return notifications_scheduled
end

--- Show today's digest notification
function M.show_today_digest()
	M.load()

	local today = os.date("%Y-%m-%d")
	local entries = M.get_entries_for_date(today)

	if #entries == 0 then
		os.execute("notify-send 'Zortex Daily Digest' 'No events or tasks for today'")
		return
	end

	-- Sort entries by time if available
	table.sort(entries, function(a, b)
		local time_a = a.attributes.at or "00:00"
		local time_b = b.attributes.at or "00:00"
		return time_a < time_b
	end)

	-- Build digest message
	local tasks = {}
	local events = {}
	local notes = {}

	for _, entry in ipairs(entries) do
		local line = entry.display_text
		if entry.attributes.at then
			line = entry.attributes.at .. " - " .. line
		end

		if entry.type == "task" then
			local status = entry.task_status and entry.task_status.symbol or "☐"
			line = status .. " " .. line
			table.insert(tasks, line)
		elseif entry.type == "event" then
			table.insert(events, line)
		else
			table.insert(notes, line)
		end
	end

	local message_parts = {}

	if #events > 0 then
		table.insert(message_parts, "📅 Events:")
		for _, event in ipairs(events) do
			table.insert(message_parts, "  " .. event)
		end
	end

	if #tasks > 0 then
		if #message_parts > 0 then
			table.insert(message_parts, "")
		end
		table.insert(message_parts, "✓ Tasks:")
		for _, task in ipairs(tasks) do
			table.insert(message_parts, "  " .. task)
		end
	end

	if #notes > 0 then
		if #message_parts > 0 then
			table.insert(message_parts, "")
		end
		table.insert(message_parts, "📝 Notes:")
		for _, note in ipairs(notes) do
			table.insert(message_parts, "  " .. note)
		end
	end

	local message = table.concat(message_parts, "\n")

	-- Use notify-send with proper escaping
	local cmd = string.format(
		"notify-send -u normal -t 10000 'Zortex Daily Digest - %s' '%s'",
		today,
		message:gsub("'", "'\\''"):gsub("\n", "\\n")
	)
	os.execute(cmd)
end

return M
