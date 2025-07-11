-- modules/calendar.lua - Calendar functionality for Zortex
local M = {}

local datetime = require("zortex.core.datetime")
local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local constants = require("zortex.constants")
local attributes = require("zortex.core.attributes")

-- =============================================================================
-- State
-- =============================================================================

local state = {
	entries = {}, -- entries[date_str] = { entries }
}

-- =============================================================================
-- Entry Parsing
-- =============================================================================

local function parse_calendar_entry(entry_text, date_context)
	local parsed = {
		raw_text = entry_text,
		display_text = entry_text,
		date_context = date_context,
		type = "note",
		attributes = {},
		task_status = nil,
	}

	local working_text = entry_text

	-- 1. Check for task status
	if parser.is_task_line("- " .. working_text) then
		parsed.task_status = attributes.parse_task_status("- " .. working_text)
		if parsed.task_status then
			parsed.type = "task"
			-- Strip the status marker for further parsing
			working_text = working_text:match("^%[.%]%s+(.+)$") or working_text
		end
	end

	-- 2. Check for time prefix or range (specific to calendar format)
	local from_time, to_time, rest_of_line = working_text:match(constants.PATTERNS.CALENDAR_TIME_RANGE)
	if from_time and to_time then
		parsed.attributes.from = from_time
		parsed.attributes.to = to_time
		parsed.attributes.at = from_time
		parsed.type = "event"
		working_text = rest_of_line
	else
		local time_prefix, rest_of_line_2 = working_text:match(constants.PATTERNS.CALENDAR_TIME_PREFIX)
		if time_prefix then
			parsed.attributes.at = time_prefix
			parsed.type = "event"
			working_text = rest_of_line_2
		end
	end

	-- 3. Use the new attribute parser for event attributes
	local attrs, remaining_text = attributes.parse_event_attributes(working_text)
	parsed.attributes = vim.tbl_extend("force", parsed.attributes, attrs)
	parsed.display_text = remaining_text

	-- 4. If notify attribute is set, mark as event
	if parsed.attributes.notify then
		parsed.type = "event"
	end

	return parsed
end

-- =============================================================================
-- Data Access
-- =============================================================================

function M.load()
	local path = fs.get_file_path(constants.FILES.CALENDAR)
	if not path or not fs.file_exists(path) then
		return false
	end

	state.entries = {}
	local lines = fs.read_lines(path)
	if not lines then
		return false
	end

	local current_date_str = nil
	for _, line in ipairs(lines) do
		local m, d, y = line:match(constants.PATTERNS.CALENDAR_DATE_HEADING)
		if m and d and y then
			current_date_str = datetime.format_date({ year = y, month = m, day = d }, "YYYY-MM-DD")
			state.entries[current_date_str] = {}
		elseif current_date_str then
			local entry_text = line:match(constants.PATTERNS.CALENDAR_ENTRY_PREFIX)
			if entry_text then
				local entry = parse_calendar_entry(entry_text, current_date_str)
				table.insert(state.entries[current_date_str], entry)
			end
		end
	end
	return true
end

function M.save()
	local path = fs.get_file_path(constants.FILES.CALENDAR)
	if not path then
		return false
	end

	local lines = {}
	local dates = {}
	for date in pairs(state.entries) do
		table.insert(dates, date)
	end
	table.sort(dates)

	for _, date_str in ipairs(dates) do
		local entries = state.entries[date_str]
		if entries and #entries > 0 then
			local date_tbl = datetime.parse_date(date_str)
			table.insert(lines, datetime.format_date(date_tbl, "MM-DD-YYYY") .. ":")
			for _, entry in ipairs(entries) do
				-- Reconstruct the raw text for saving
				table.insert(lines, "  - " .. entry.raw_text)
			end
			table.insert(lines, "") -- Add a blank line for readability
		end
	end

	return fs.write_lines(path, lines)
end

function M.add_entry(date_str, entry_text)
	if not state.entries[date_str] then
		state.entries[date_str] = {}
	end
	table.insert(state.entries[date_str], parse_calendar_entry(entry_text, date_str))
	return M.save()
end

function M.get_entries_for_date(date_str)
	local target_date = datetime.parse_date(date_str)
	if not target_date then
		return {}
	end
	-- Normalize date to noon to avoid timezone/DST issues with os.time
	target_date.hour, target_date.min, target_date.sec = 12, 0, 0
	local target_time = os.time(target_date)

	local active_entries = {}
	local seen = {} -- Keep track of entry raw_text to avoid duplicates

	-- 1. Add entries specifically listed under the target date.
	-- These are entries without ranges, or the "home" date of a ranged entry.
	if state.entries[date_str] then
		for _, entry in ipairs(state.entries[date_str]) do
			if not seen[entry.raw_text] then
				table.insert(active_entries, entry)
				seen[entry.raw_text] = true
			end
		end
	end

	-- 2. Scan all entries in the calendar to find date ranges that include the target date.
	for _, entries_on_date in pairs(state.entries) do
		for _, entry in ipairs(entries_on_date) do
			-- If we haven't already processed this entry
			if not seen[entry.raw_text] then
				local from_attr = entry.attributes and entry.attributes.from
				local to_attr = entry.attributes and entry.attributes.to
				local from_date = from_attr and datetime.parse_date(from_attr)
				local to_date = to_attr and datetime.parse_date(to_attr)

				-- Only proceed if there's at least one valid date range attribute
				if from_date or to_date then
					if from_date then
						from_date.hour = 12
					end
					if to_date then
						to_date.hour = 12
					end

					-- Safely get time values
					local from_time = from_date and os.time(from_date)
					local to_time = to_date and os.time(to_date)

					local in_range = false
					if from_time and to_time then
						in_range = target_time >= from_time and target_time <= to_time
					elseif from_time then
						in_range = target_time >= from_time
					elseif to_time then
						in_range = target_time <= to_time
					end

					if in_range then
						table.insert(active_entries, entry)
						seen[entry.raw_text] = true
					end
				end
			end
		end
	end

	-- TODO: Implement repeating entries logic here.

	return active_entries
end

return M
