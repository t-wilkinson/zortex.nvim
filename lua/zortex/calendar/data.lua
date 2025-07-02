-- Enhanced Data management for the Zortex calendar with notification support.
-- Handles loading, parsing, saving, querying calendar entries, and system notifications.

local M = {}

-- =============================================================================
-- Constants
-- =============================================================================

local CALENDAR_FILE = "calendar.zortex"

-- Task status definitions. The parser will attach this information to an entry.
M.TASK_STATUS = {
	["[ ]"] = { symbol = "☐", name = "Incomplete", hl = "Comment" },
	["[x]"] = { symbol = "☑", name = "Complete", hl = "String" },
	["[!]"] = { symbol = "⚠", name = "Important", hl = "ErrorMsg" },
	["[~]"] = { symbol = "◐", name = "In Progress", hl = "WarningMsg" },
	["[@]"] = { symbol = "⏸", name = "Paused", hl = "Comment" },
}

-- =============================================================================
-- State
-- =============================================================================

local state = {
	-- Stores raw text entries, e.g., state.raw_data["2023-01-01"] = {"[ ] Task 1"}
	raw_data = {},
	-- Stores parsed entry objects, e.g., state.parsed_data["2023-01-01"] = { {..parsed_entry..} }
	parsed_data = {},
}

-- =============================================================================
-- Private Helper Functions
-- =============================================================================

--- Deep copy a table to prevent mutation of original data.
local function deepcopy(orig)
	local orig_type = type(orig)
	local copy
	if orig_type == "table" then
		copy = {}
		for orig_key, orig_value in next, orig, nil do
			copy[deepcopy(orig_key)] = deepcopy(orig_value)
		end
		setmetatable(copy, deepcopy(getmetatable(orig)))
	else -- number, string, boolean, etc
		copy = orig
	end
	return copy
end

--- Parse a date string (YYYY-MM-DD) or (MM-DD-YYYY) into a table.
local function parse_date(date_str)
	if not date_str then
		return nil
	end

	-- 1) YYYY-MM-DD
	local y, m, d = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if y then
		return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
	end

	-- 2) MM-DD-YYYY
	local m2, d2, y2 = date_str:match("^(%d%d)%-(%d%d)%-(%d%d%d%d)$")
	if m2 then
		return { year = tonumber(y2), month = tonumber(m2), day = tonumber(d2) }
	end

	return nil
end

--- Parse time string into hour and minute
local function parse_time(time_str)
	if not time_str then
		return nil
	end

	-- Try HH:MM format
	local hour, min = time_str:match("^(%d%d?):(%d%d)$")
	if hour then
		return { hour = tonumber(hour), min = tonumber(min) }
	end

	-- Try HH:MMam/pm format
	hour, min = time_str:match("^(%d%d?):(%d%d)([ap]m)$")
	if hour then
		local h = tonumber(hour)
		local pm = time_str:match("pm$")
		if pm and h ~= 12 then
			h = h + 12
		elseif not pm and h == 12 then
			h = 0
		end
		return { hour = h, min = tonumber(min) }
	end

	-- Try HH:MM am/pm format
	hour, min = time_str:match("^(%d%d?):(%d%d)%s+([ap]m)$")
	if hour then
		local h = tonumber(hour)
		local pm = time_str:match("pm$")
		if pm and h ~= 12 then
			h = h + 12
		elseif not pm and h == 12 then
			h = 0
		end
		return { hour = h, min = tonumber(min) }
	end

	return nil
end

--- Parse datetime string (date + optional time)
local function parse_datetime(dt_str, default_date)
	if not dt_str then
		return nil
	end

	-- Try to parse as date + time
	local date_part, time_part = dt_str:match("^(%d%d%d%d%-%d%d%-%d%d)%s+(.+)$")
	if date_part and time_part then
		local date = parse_date(date_part)
		local time = parse_time(time_part)
		if date and time then
			date.hour = time.hour
			date.min = time.min
			return date
		end
	end

	-- Try to parse as date only
	local date = parse_date(dt_str)
	if date then
		date.hour = 0
		date.min = 0
		return date
	end

	-- Try to parse as time only (use default date)
	local time = parse_time(dt_str)
	if time and default_date then
		local date = parse_date(default_date)
		if date then
			date.hour = time.hour
			date.min = time.min
			return date
		end
	end

	return nil
end

--- Parse duration string (e.g., "1.5h", "30min", "2d")
local function parse_duration(dur_str)
	if not dur_str then
		return nil
	end

	local num, unit = dur_str:match("^(%d+%.?%d*)%s*(%w+)$")
	if not num then
		-- Try without space
		num, unit = dur_str:match("^(%d+%.?%d*)(%w+)$")
	end

	if num then
		num = tonumber(num)
		unit = unit:lower()

		-- Convert to minutes
		if unit == "m" or unit == "min" or unit == "mins" or unit == "minute" or unit == "minutes" then
			return num
		elseif unit == "h" or unit == "hr" or unit == "hrs" or unit == "hour" or unit == "hours" then
			return num * 60
		elseif unit == "d" or unit == "day" or unit == "days" then
			return num * 60 * 24
		end
	end

	-- Special case for "0" without units
	if dur_str == "0" then
		return 0
	end

	return nil
end

--- Parse notification durations list
local function parse_notification_durations(notify_str)
	if not notify_str then
		return { 0 } -- Default: notify at event time
	end

	local durations = {}
	for dur in notify_str:gmatch("([^,]+)") do
		dur = dur:match("^%s*(.-)%s*$") -- trim
		local mins = parse_duration(dur)
		if mins then
			table.insert(durations, mins)
		end
	end

	return #durations > 0 and durations or { 0 }
end

--- Get the full path to the calendar data file.
function M.get_calendar_path()
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir then
		vim.notify("g:zortex_notes_dir not set", vim.log.levels.ERROR)
		return nil
	end
	if not notes_dir:match("/$") then
		notes_dir = notes_dir .. "/"
	end
	return notes_dir .. CALENDAR_FILE
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Parse a single entry line for attributes and task status.
-- This is the core parser that converts a line of text into a structured object.
function M.parse_entry(entry_text, date_context)
	local parsed = {
		raw_text = entry_text,
		display_text = entry_text,
		task_status = nil,
		attributes = {},
		type = "note", -- default type
		date_context = date_context, -- Store the date this entry belongs to
	}

	local working_text = entry_text

	-- 1. Check for task status
	local status_pattern = "^(%[.%])%s+(.+)$"
	local status_key, remaining_text = working_text:match(status_pattern)
	if status_key and M.TASK_STATUS[status_key] then
		parsed.task_status = M.TASK_STATUS[status_key]
		parsed.task_status.key = status_key
		parsed.type = "task"
		working_text = remaining_text
	end

	-- 2. Check for time prefix (HH:MM) or time range (HH:MM-HH:MM)
	-- Time range pattern
	local from_time, to_time, rest = working_text:match("^(%d%d?:%d%d)%-(%d%d?:%d%d)%s+(.+)$")
	if from_time and to_time then
		parsed.attributes.from = from_time
		parsed.attributes.to = to_time
		parsed.attributes.at = from_time -- Use start time as event time
		working_text = rest
	else
		-- Single time pattern
		local time_prefix, rest_of_line = working_text:match("^(%d%d?:%d%d)%s+(.+)$")
		if time_prefix then
			parsed.attributes.at = time_prefix
			working_text = rest_of_line
		end
	end

	-- 3. Parse all other attributes (@due, @repeat, etc.)
	-- First handle attributes with parentheses
	local paren_attributes = {
		at = "@at%(([^)]+)%)",
		due = "@due%(([^)]+)%)",
		from = "@from%(([^)]+)%)",
		to = "@to%(([^)]+)%)",
		repeating = "@repeat%(([^)]+)%)",
		notify = "@notify%(([^)]+)%)",
		n = "@n%(([^)]+)%)",
		event = "@event%(([^)]+)%)",
	}

	for attr_name, pattern in pairs(paren_attributes) do
		local value = working_text:match(pattern)
		if value then
			if attr_name == "notify" or attr_name == "n" or attr_name == "event" then
				parsed.attributes.notification_enabled = true
				parsed.attributes.notification_durations = parse_notification_durations(value)
			elseif not (attr_name == "at" and parsed.attributes.at) then
				parsed.attributes[attr_name] = value
			end
			working_text = working_text:gsub(pattern, "")
		end
	end

	-- Handle attributes without parentheses
	-- Check for @n, @event, @notify without parentheses
	if working_text:match("@n%s") or working_text:match("@n$") then
		parsed.attributes.notification_enabled = true
		parsed.attributes.notification_durations = parsed.attributes.notification_durations or { 0 }
		working_text = working_text:gsub("@n", "")
	end

	if working_text:match("@event%s") or working_text:match("@event$") then
		parsed.attributes.notification_enabled = true
		parsed.attributes.notification_durations = parsed.attributes.notification_durations or { 0 }
		working_text = working_text:gsub("@event", "")
	end

	if working_text:match("@notify%s") or working_text:match("@notify$") then
		parsed.attributes.notification_enabled = true
		parsed.attributes.notification_durations = parsed.attributes.notification_durations or { 0 }
		working_text = working_text:gsub("@notify", "")
	end

	-- Other attributes
	local simple_attributes = {
		duration = "@(%d+%.?%d*[hm][ri]?n?)",
		priority = "@p([123])",
		context = "@(%w+)",
	}

	for attr_name, pattern in pairs(simple_attributes) do
		local value = working_text:match(pattern)
		if value then
			parsed.attributes[attr_name] = value
			working_text = working_text:gsub(pattern, "")
		end
	end

	-- 4. Determine final entry type based on attributes found
	if parsed.attributes.at or parsed.attributes.notification_enabled then
		parsed.type = "event"
	end

	-- 5. Clean up the remaining text for display
	parsed.display_text = working_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

	return parsed
end

--- Loads and parses the calendar data from the file.
function M.load()
	local path = M.get_calendar_path()
	if not path then
		return
	end

	-- Reset state
	state.raw_data = {}
	state.parsed_data = {}

	if vim.fn.filereadable(path) == 0 then
		return -- File doesn't exist, nothing to load
	end

	local current_date = nil
	for line in io.lines(path) do
		local m, d, y = line:match("^(%d%d)%-(%d%d)%-(%d%d%d%d):$")
		if m and d and y then
			current_date = string.format("%04d-%02d-%02d", y, m, d)
			state.raw_data[current_date] = {}
			state.parsed_data[current_date] = {}
		elseif current_date and line:match("^%s+%- ") then
			local entry_text = line:match("^%s+%- (.+)$")
			if entry_text then
				table.insert(state.raw_data[current_date], entry_text)
				table.insert(state.parsed_data[current_date], M.parse_entry(entry_text, current_date))
			end
		elseif current_date and line:match("^%s+%d%d?:%d%d ") then
			local entry_text = line:match("^%s+(.+)$")
			if entry_text then
				table.insert(state.raw_data[current_date], entry_text)
				table.insert(state.parsed_data[current_date], M.parse_entry(entry_text, current_date))
			end
		end
	end
end

--- Saves the current calendar data to the file.
function M.save()
	local path = M.get_calendar_path()
	if not path then
		return false
	end

	local file = io.open(path, "w")
	if not file then
		vim.notify("Failed to open calendar file for writing", vim.log.levels.ERROR)
		return false
	end

	local dates = {}
	for date in pairs(state.raw_data) do
		table.insert(dates, date)
	end
	table.sort(dates)

	for _, date_str in ipairs(dates) do
		local entries = state.raw_data[date_str]
		if entries and #entries > 0 then
			local y, m, d = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
			file:write(string.format("%s-%s-%s:\n", m, d, y))
			for _, entry in ipairs(entries) do
				file:write("  - " .. entry .. "\n")
			end
			file:write("\n")
		end
	end

	file:close()
	return true
end

--- Adds a new entry and saves the calendar.
function M.add_entry(date_str, entry_text)
	if not state.raw_data[date_str] then
		state.raw_data[date_str] = {}
		state.parsed_data[date_str] = {}
	end
	table.insert(state.raw_data[date_str], entry_text)
	table.insert(state.parsed_data[date_str], M.parse_entry(entry_text, date_str))
	M.save()
end

--- Gets all active entries for a given date, including recurring and ranged events.
function M.get_entries_for_date(date_str)
	local target_date_obj = parse_date(date_str)
	if not target_date_obj then
		return {}
	end
	local target_time = os.time(target_date_obj)

	local active_entries = {}
	local added_entries = {} -- Track raw text to avoid duplicates

	-- 1. Add standard entries for the day
	if state.parsed_data[date_str] then
		for _, entry in ipairs(state.parsed_data[date_str]) do
			if not added_entries[entry.raw_text] then
				table.insert(active_entries, entry)
				added_entries[entry.raw_text] = true
			end
		end
	end

	-- 2. Check all other entries for recurring, ranged, or due attributes
	for original_date_str, entries in pairs(state.parsed_data) do
		local original_date_obj = parse_date(original_date_str)
		if original_date_obj then
			local original_time = os.time(original_date_obj)

			for _, entry in ipairs(entries) do
				if not added_entries[entry.raw_text] then
					local is_recurring, is_ranged = false, false

					-- Check for @repeat
					if entry.attributes.repeating and target_time > original_time then
						local repeat_val = entry.attributes.repeating:lower()
						local diff_days = math.floor((target_time - original_time) / 86400)
						if repeat_val == "daily" then
							is_recurring = true
						elseif repeat_val == "weekly" and diff_days > 0 and diff_days % 7 == 0 then
							is_recurring = true
						end
					end

					-- Check for @from/@to range
					if entry.attributes.from or entry.attributes.to then
						local from_dt = parse_datetime(entry.attributes.from, original_date_str)
						local to_dt = parse_datetime(entry.attributes.to, original_date_str)
						local from_time = from_dt and os.time(from_dt) or original_time
						local to_time = to_dt and os.time(to_dt) or from_time
						if target_time >= from_time and target_time <= to_time then
							is_ranged = true
						end
					end

					if is_recurring or is_ranged then
						local instance = deepcopy(entry)
						instance.is_recurring_instance = is_recurring
						instance.is_ranged_instance = is_ranged
						instance.effective_date = date_str -- Store the effective date
						table.insert(active_entries, instance)
						added_entries[entry.raw_text] = true
					end
				end

				-- Check for @due date
				if entry.attributes.due then
					local due_dt = parse_datetime(entry.attributes.due, original_date_str)
					if due_dt then
						local due_date_str = string.format("%04d-%02d-%02d", due_dt.year, due_dt.month, due_dt.day)
						if due_date_str == date_str and not added_entries[entry.raw_text] then
							local due_entry = deepcopy(entry)
							due_entry.is_due_date_instance = true
							due_entry.effective_date = date_str
							table.insert(active_entries, due_entry)
							added_entries[entry.raw_text] = true
						end
					end
				end
			end
		end
	end

	return active_entries
end

--- Returns all parsed entries, useful for Telescope.
function M.get_all_parsed_entries()
	return state.parsed_data
end

-- =============================================================================
-- Notification Functions
-- =============================================================================

--- Get the datetime for an entry (considering various attributes)
local function get_entry_datetime(entry, effective_date)
	local date_str = effective_date or entry.date_context
	local date_obj = parse_date(date_str)
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
		local dt = parse_datetime(entry.attributes.notify, date_str)
		if dt then
			return dt
		end
	elseif entry.attributes.due then
		-- If due has time, use it
		local dt = parse_datetime(entry.attributes.due, date_str)
		if dt then
			return dt
		end
	end

	if time_str then
		local time = parse_time(time_str)
		if time then
			date_obj.hour = time.hour
			date_obj.min = time.min
		end
	end

	return date_obj
end

--- Setup system notifications for all future events
function M.setup_notifications()
	M.load()

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
		local date_obj = parse_date(date_str)
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
