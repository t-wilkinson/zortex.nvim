-- features/ical.lua - iCal import/export for Zortex calendar
local M = {}

local datetime = require("zortex.core.datetime")
local fs = require("zortex.core.filesystem")
local calendar_store = require("zortex.stores.calendar")
local CalendarEntry = require("zortex.models.calendar_entry")

-- =============================================================================
-- iCal Parsing
-- =============================================================================

-- Parse iCal date/datetime
local function parse_ical_datetime(value)
	-- Handle different iCal datetime formats
	-- YYYYMMDD (date only)
	local year, month, day, hour, min, sec
	year, month, day = value:match("^(%d%d%d%d)(%d%d)(%d%d)$")
	if year then
		return {
			year = tonumber(year),
			month = tonumber(month),
			day = tonumber(day),
		}
	end

	-- YYYYMMDDTHHMMSS (datetime)
	year, month, day, hour, min, sec = value:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)")
	if year then
		return {
			year = tonumber(year),
			month = tonumber(month),
			day = tonumber(day),
			hour = tonumber(hour),
			min = tonumber(min),
			sec = tonumber(sec),
		}
	end

	-- YYYYMMDDTHHMMSSZ (UTC datetime)
	year, month, day, hour, min, sec = value:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z$")
	if year then
		return {
			year = tonumber(year),
			month = tonumber(month),
			day = tonumber(day),
			hour = tonumber(hour),
			min = tonumber(min),
			sec = tonumber(sec),
			utc = true,
		}
	end

	return nil
end

-- Unfold iCal lines (handle line continuations)
local function unfold_lines(lines)
	local unfolded = {}
	local current = ""

	for _, line in ipairs(lines) do
		if line:match("^%s") then
			-- Continuation line
			current = current .. line:sub(2)
		else
			-- New line
			if current ~= "" then
				table.insert(unfolded, current)
			end
			current = line
		end
	end

	if current ~= "" then
		table.insert(unfolded, current)
	end

	return unfolded
end

-- Parse a VEVENT block
local function parse_vevent(lines, start_idx)
	local event = {
		properties = {},
	}

	local i = start_idx + 1
	while i <= #lines do
		local line = lines[i]

		if line == "END:VEVENT" then
			return event, i
		end

		-- Parse property:value
		local prop, value = line:match("^([^:;]+)[;:](.*)$")
		if prop then
			prop = prop:upper()

			-- Handle parameters (e.g., DTSTART;VALUE=DATE:20240101)
			local params = {}
			if value:match(";") then
				local param_str, real_value = value:match("^([^:]+):(.*)$")
				if param_str then
					for param in param_str:gmatch("[^;]+") do
						local k, v = param:match("^([^=]+)=(.*)$")
						if k then
							params[k] = v
						end
					end
					value = real_value
				end
			end

			-- Store property
			if not event.properties[prop] then
				event.properties[prop] = {}
			end

			table.insert(event.properties[prop], {
				value = value,
				params = params,
			})
		end

		i = i + 1
	end

	return event, #lines
end

-- Convert VEVENT to Zortex calendar entry
local function vevent_to_entry(vevent)
	local props = vevent.properties
	if not props.DTSTART then
		return nil
	end

	-- Get start date/time
	local dtstart = props.DTSTART[1]
	local start_dt = parse_ical_datetime(dtstart.value)
	if not start_dt then
		return nil
	end

	-- Build entry text
	local summary = props.SUMMARY and props.SUMMARY[1].value or "Untitled Event"
	local description = props.DESCRIPTION and props.DESCRIPTION[1].value or ""

	-- Escape special characters
	summary = summary:gsub("\\n", " "):gsub("\\,", ","):gsub("\\;", ";")
	description = description:gsub("\\n", " "):gsub("\\,", ","):gsub("\\;", ";")

	-- Build attributes
	local attrs = {}

	-- Time attribute
	if start_dt.hour then
		attrs.at = string.format("%02d:%02d", start_dt.hour, start_dt.min)
	end

	-- Duration/end time
	if props.DTEND then
		local end_dt = parse_ical_datetime(props.DTEND[1].value)
		if end_dt and start_dt.hour and end_dt.hour then
			-- Calculate duration in minutes
			local start_time = os.time(start_dt)
			local end_time = os.time(end_dt)
			local duration_mins = math.floor((end_time - start_time) / 60)
			if duration_mins > 0 then
				attrs.dur = duration_mins
			end
		end
	elseif props.DURATION then
		-- Parse ISO 8601 duration (simplified)
		local dur_str = props.DURATION[1].value
		local hours = dur_str:match("PT(%d+)H") or 0
		local mins = dur_str:match("PT%d*H?(%d+)M") or 0
		attrs.dur = tonumber(hours) * 60 + tonumber(mins)
	end

	-- Recurrence rules (simplified)
	if props.RRULE then
		local rrule = props.RRULE[1].value
		if rrule:match("FREQ=DAILY") then
			attrs["repeat"] = "daily"
		elseif rrule:match("FREQ=WEEKLY") then
			attrs["repeat"] = "weekly"
		elseif rrule:match("FREQ=MONTHLY") then
			attrs["repeat"] = "monthly"
		elseif rrule:match("FREQ=YEARLY") then
			attrs["repeat"] = "yearly"
		end
	end

	-- Build entry text with attributes
	local entry_text = summary
	if description ~= "" then
		entry_text = entry_text .. " - " .. description
	end

	-- Add attributes to text
	for key, val in pairs(attrs) do
		if key == "repeat" then
			entry_text = entry_text .. " @" .. key .. "(" .. val .. ")"
		elseif type(val) == "number" then
			entry_text = entry_text .. " @" .. key .. "(" .. val .. ")"
		else
			entry_text = entry_text .. " @" .. key .. "(" .. val .. ")"
		end
	end

	-- Return date and entry text
	local date_str = datetime.format_date(start_dt, "YYYY-MM-DD")
	return date_str, entry_text
end

-- =============================================================================
-- iCal Generation
-- =============================================================================

-- Format datetime for iCal
local function format_ical_datetime(dt)
	if dt.hour then
		return string.format("%04d%02d%02dT%02d%02d%02d", dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec or 0)
	else
		return string.format("%04d%02d%02d", dt.year, dt.month, dt.day)
	end
end

-- Escape text for iCal
local function escape_ical_text(text)
	return text:gsub(",", "\\,"):gsub(";", "\\;"):gsub("\n", "\\n")
end

-- Fold long lines (iCal requires lines <= 75 chars)
local function fold_line(line)
	if #line <= 75 then
		return line
	end

	local folded = {}
	local pos = 1

	-- First line
	table.insert(folded, line:sub(1, 75))
	pos = 76

	-- Continuation lines (74 chars + 1 space)
	while pos <= #line do
		table.insert(folded, " " .. line:sub(pos, pos + 73))
		pos = pos + 74
	end

	return table.concat(folded, "\r\n")
end

-- Convert calendar entry to VEVENT
local function entry_to_vevent(entry, date_str)
	local lines = { "BEGIN:VEVENT" }

	-- UID (required)
	local uid = entry.attributes.id or (date_str .. "-" .. os.time())
	table.insert(lines, "UID:" .. uid .. "@zortex")

	-- DTSTAMP (required)
	local now = os.date("!%Y%m%dT%H%M%SZ")
	table.insert(lines, "DTSTAMP:" .. now)

	-- DTSTART
	local date = datetime.parse_date(date_str)
	if entry.time then
		date.hour = entry.time.hour
		date.min = entry.time.min
		date.sec = 0
		table.insert(lines, "DTSTART:" .. format_ical_datetime(date))
	else
		table.insert(lines, "DTSTART;VALUE=DATE:" .. format_ical_datetime(date))
	end

	-- DTEND or DURATION
	if entry.duration then
		if entry.time then
			-- Calculate end time
			local end_date = vim.tbl_deep_extend("force", date, {})
			local total_mins = end_date.hour * 60 + end_date.min + entry.duration
			end_date.hour = math.floor(total_mins / 60)
			end_date.min = total_mins % 60

			-- Handle day overflow
			if end_date.hour >= 24 then
				end_date = datetime.add_days(end_date, 1)
				end_date.hour = end_date.hour - 24
			end

			table.insert(lines, "DTEND:" .. format_ical_datetime(end_date))
		else
			-- All-day event with duration
			table.insert(lines, string.format("DURATION:P%dD", math.ceil(entry.duration / 1440)))
		end
	end

	-- SUMMARY
	table.insert(lines, "SUMMARY:" .. escape_ical_text(entry.display_text))

	-- RRULE for repeating events
	if entry.attributes["repeat"] then
		local repeat_val = entry.attributes["repeat"]
		local rrule = nil

		if repeat_val == "daily" then
			rrule = "RRULE:FREQ=DAILY"
		elseif repeat_val == "weekly" then
			rrule = "RRULE:FREQ=WEEKLY"
		elseif repeat_val == "monthly" then
			rrule = "RRULE:FREQ=MONTHLY"
		elseif repeat_val == "yearly" then
			rrule = "RRULE:FREQ=YEARLY"
		elseif repeat_val:match("^%d+d$") then
			local days = repeat_val:match("^(%d+)d$")
			rrule = "RRULE:FREQ=DAILY;INTERVAL=" .. days
		elseif repeat_val:match("^%d+w$") then
			local weeks = repeat_val:match("^(%d+)w$")
			rrule = "RRULE:FREQ=WEEKLY;INTERVAL=" .. weeks
		end

		if rrule then
			table.insert(lines, rrule)
		end
	end

	-- STATUS for tasks
	if entry.type == "task" then
		if entry.task_status and entry.task_status.key == "[x]" then
			table.insert(lines, "STATUS:COMPLETED")
		else
			table.insert(lines, "STATUS:IN-PROCESS")
		end
	end

	table.insert(lines, "END:VEVENT")

	-- Fold long lines
	local folded = {}
	for _, line in ipairs(lines) do
		table.insert(folded, fold_line(line))
	end

	return table.concat(folded, "\r\n")
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Import iCal file
function M.import_file(filepath)
	local content = fs.read_file(filepath)
	if not content then
		return false, "Failed to read file: " .. filepath
	end

	local lines = vim.split(content, "\r?\n")
	lines = unfold_lines(lines)

	local imported = 0
	local errors = {}

	-- Ensure calendar is loaded
	calendar_store.load()

	-- Parse events
	local i = 1
	while i <= #lines do
		if lines[i] == "BEGIN:VEVENT" then
			local vevent, end_idx = parse_vevent(lines, i)
			local date_str, entry_text = vevent_to_entry(vevent)

			if date_str and entry_text then
				local success = calendar_store.add_entry(date_str, entry_text)
				if success then
					imported = imported + 1
				else
					table.insert(errors, "Failed to add entry: " .. entry_text)
				end
			else
				table.insert(errors, "Failed to parse event at line " .. i)
			end

			i = end_idx + 1
		else
			i = i + 1
		end
	end

	return true,
		string.format("Imported %d events%s", imported, #errors > 0 and string.format(" (%d errors)", #errors) or "")
end

-- Export to iCal file
function M.export_file(filepath, options)
	options = options or {}

	-- Load calendar
	calendar_store.load()

	local lines = {
		"BEGIN:VCALENDAR",
		"VERSION:2.0",
		"PRODID:-//Zortex//Calendar Export//EN",
		"CALSCALE:GREGORIAN",
		"METHOD:PUBLISH",
		fold_line("X-WR-CALNAME:" .. (options.calendar_name or "Zortex Calendar")),
		fold_line("X-WR-CALDESC:" .. (options.calendar_desc or "Exported from Zortex")),
	}

	-- Get date range
	local start_date, end_date
	if options.date_range then
		start_date = datetime.parse_date(options.date_range.start)
		end_date = datetime.parse_date(options.date_range["end"])
	else
		-- Default: export all entries
		local all_entries = calendar_store.get_all_entries()
		if #all_entries == 0 then
			return false, "No calendar entries to export"
		end

		-- Find date range
		start_date = datetime.parse_date(all_entries[1].date)
		end_date = start_date

		for _, item in ipairs(all_entries) do
			local date = datetime.parse_date(item.date)
			if os.time(date) < os.time(start_date) then
				start_date = date
			end
			if os.time(date) > os.time(end_date) then
				end_date = date
			end
		end
	end

	-- Export entries in date range
	local exported = 0
	local current = start_date

	while os.time(current) <= os.time(end_date) do
		local date_str = datetime.format_date(current, "YYYY-MM-DD")
		local entries = calendar_store.get_entries_for_date(date_str)

		for _, entry in ipairs(entries) do
			-- Skip completed tasks if requested
			if
				not (
					options.skip_completed
					and entry.type == "task"
					and entry.task_status
					and entry.task_status.key == "[x]"
				)
			then
				table.insert(lines, "")
				table.insert(lines, entry_to_vevent(entry, date_str))
				exported = exported + 1
			end
		end

		current = datetime.add_days(current, 1)
	end

	table.insert(lines, "END:VCALENDAR")

	-- Write file
	local content = table.concat(lines, "\r\n")
	local success = fs.write_file(filepath, content)

	if success then
		return true, string.format("Exported %d events to %s", exported, filepath)
	else
		return false, "Failed to write file: " .. filepath
	end
end

-- Import from URL
function M.import_url(url)
	-- Use curl to fetch the iCal
	local tmpfile = os.tmpname() .. ".ics"
	local cmd = string.format("curl -sL -o %s %s", vim.fn.shellescape(tmpfile), vim.fn.shellescape(url))

	local result = os.execute(cmd)
	if result ~= 0 then
		return false, "Failed to download iCal from URL"
	end

	local success, msg = M.import_file(tmpfile)
	os.remove(tmpfile)

	return success, msg
end

-- Interactive import
function M.import_interactive()
	vim.ui.input({
		prompt = "Import iCal from file path or URL: ",
		completion = "file",
	}, function(input)
		if not input or input == "" then
			return
		end

		local success, msg
		if input:match("^https?://") then
			success, msg = M.import_url(input)
		else
			-- Expand path
			input = vim.fn.expand(input)
			success, msg = M.import_file(input)
		end

		if success then
			vim.notify(msg, vim.log.levels.INFO)
		else
			vim.notify(msg, vim.log.levels.ERROR)
		end
	end)
end

-- Interactive export
function M.export_interactive()
	vim.ui.input({
		prompt = "Export iCal to file path: ",
		default = "~/zortex-calendar.ics",
		completion = "file",
	}, function(input)
		if not input or input == "" then
			return
		end

		-- Expand path
		input = vim.fn.expand(input)

		-- Ask for options
		local options = {
			calendar_name = "Zortex Calendar",
			skip_completed = true,
		}

		local success, msg = M.export_file(input, options)

		if success then
			vim.notify(msg, vim.log.levels.INFO)
		else
			vim.notify(msg, vim.log.levels.ERROR)
		end
	end)
end

return M
