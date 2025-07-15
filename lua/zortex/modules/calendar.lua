-- modules/calendar.lua - Calendar functionality for Zortex
local M = {}

local config = require("zortex.core.config")
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

function M.parse_calendar_entry(entry_text, date_context)
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
			-- Strip the checkbox pattern: [x], [ ], etc.
			working_text = working_text:match("^%[.%]%s+(.+)$") or working_text
		end
	end

	-- 2. Parse attributes from the remaining text
	local attrs, remaining_text = attributes.parse_attributes(working_text, attributes.schemas.calendar_entry)
	parsed.attributes = attrs or {}
	parsed.display_text = remaining_text

	-- 3. Determine type based on attributes if not already a task
	if parsed.type ~= "task" then
		if attrs.from or attrs.to or attrs.at then
			parsed.type = "event"
		end
	end

	return parsed
end

-- =============================================================================
-- Format calendar entry
-- =============================================================================

-- Format entry depending on calendar pretty_attributes setting
function M.format_entry(entry)
	return config.get("ui.calendar.pretty_attributes") and M.format_entry_pretty(entry) or M.format_entry_simple(entry)
end

-- Pretty‑print attributes
function M.format_entry_pretty(entry)
	if not entry.attributes then
		return ""
	end

	local parts = {}

	-- Time attributes
	if entry.attributes.at then
		table.insert(parts, "🕐 " .. entry.attributes.at)
	end

	-- Duration attributes
	if entry.attributes.dur then
		table.insert(parts, string.format("⏱ %dm", entry.attributes.dur))
	elseif entry.attributes.est then
		table.insert(parts, string.format("⏱ ~%dm", entry.attributes.est))
	end

	-- Notification
	if entry.attributes.notify then
		table.insert(parts, "🔔")
	end

	-- Repeat pattern
	if entry.attributes["repeat"] then
		table.insert(parts, "🔁 " .. entry.attributes["repeat"])
	end

	-- Date range
	if entry.attributes.from or entry.attributes.to then
		local range_parts = {}
		if entry.attributes.from then
			table.insert(range_parts, datetime.format_date(entry.attributes.from, "MM/DD"))
		else
			table.insert(range_parts, "...")
		end
		table.insert(range_parts, "→")
		if entry.attributes.to then
			table.insert(range_parts, datetime.format_date(entry.attributes.to, "MM/DD"))
		else
			table.insert(range_parts, "...")
		end
		table.insert(parts, table.concat(range_parts, " "))
	end

	if #parts > 0 then
		return entry.display_text .. "  " .. table.concat(parts, "  ")
	end
	return entry.display_text
end

-- Format attributes in simple mode
function M.format_entry_simple(entry)
	if not entry.attributes then
		return ""
	end

	local parts = {}

	-- Compact time display
	if entry.attributes.at then
		table.insert(parts, entry.attributes.at)
	end

	-- Compact duration
	if entry.attributes.dur then
		table.insert(parts, entry.attributes.dur .. "m")
	elseif entry.attributes.est then
		table.insert(parts, "~" .. entry.attributes.est .. "m")
	end

	-- Simple indicators
	if entry.attributes.notify then
		table.insert(parts, "!")
	end

	if entry.attributes["repeat"] then
		table.insert(parts, "R")
	end

	-- Compact date range
	if entry.attributes.from and entry.attributes.to then
		local from_str = datetime.format_date(entry.attributes.from, "MM/DD")
		local to_str = datetime.format_date(entry.attributes.to, "MM/DD")
		table.insert(parts, from_str .. "-" .. to_str)
	elseif entry.attributes.from then
		table.insert(parts, datetime.format_date(entry.attributes.from, "MM/DD") .. "+")
	elseif entry.attributes.to then
		table.insert(parts, "-" .. datetime.format_date(entry.attributes.to, "MM/DD"))
	end

	if #parts > 0 then
		return " [" .. table.concat(parts, " ") .. "]"
	end
	return ""
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
				local entry = M.parse_calendar_entry(entry_text, current_date_str)
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
	table.insert(state.entries[date_str], M.parse_calendar_entry(entry_text, date_str))
	return M.save()
end

function M.get_entries_for_date(date_str)
	local target_date = datetime.parse_date(date_str)
	if not target_date then
		return {}
	end
	-- Normalize date to noon to avoid timezone/DST issues
	target_date.hour, target_date.min, target_date.sec = 12, 0, 0
	local target_time = os.time(target_date)

	local active_entries = {}
	local seen = {} -- Track processed entries by raw_text

	-- 1. Add entries specifically on this date
	if state.entries[date_str] then
		for _, entry in ipairs(state.entries[date_str]) do
			if not seen[entry.raw_text] then
				table.insert(active_entries, entry)
				seen[entry.raw_text] = true
			end
		end
	end

	-- 2. Check all entries for date ranges that include target date
	for entry_date_str, entries_on_date in pairs(state.entries) do
		for _, entry in ipairs(entries_on_date) do
			if not seen[entry.raw_text] and entry.attributes then
				local from_date = entry.attributes.from
				local to_date = entry.attributes.to

				-- Only check if at least one range attribute exists
				if from_date or to_date then
					local in_range = false

					-- Normalize times to noon for comparison
					if from_date then
						from_date = vim.tbl_extend("force", {}, from_date)
						from_date.hour, from_date.min, from_date.sec = 12, 0, 0
					end
					if to_date then
						to_date = vim.tbl_extend("force", {}, to_date)
						to_date.hour, to_date.min, to_date.sec = 12, 0, 0
					end

					if from_date and to_date then
						-- Both dates present: check if target is between them
						local from_time = os.time(from_date)
						local to_time = os.time(to_date)
						in_range = target_time >= from_time and target_time <= to_time
					elseif from_date then
						-- Only from date: check if target is after it
						local from_time = os.time(from_date)
						in_range = target_time >= from_time
					elseif to_date then
						-- Only to date: check if target is before it
						local to_time = os.time(to_date)
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

	-- 3. Handle repeating entries
	for entry_date_str, entries_on_date in pairs(state.entries) do
		for _, entry in ipairs(entries_on_date) do
			if not seen[entry.raw_text] and entry.attributes and entry.attributes["repeat"] then
				local repeat_pattern = entry.attributes["repeat"]
				local entry_date = datetime.parse_date(entry.date_context or entry_date_str)

				if entry_date and M.is_repeat_active(entry_date, target_date, repeat_pattern) then
					table.insert(active_entries, entry)
					seen[entry.raw_text] = true
				end
			end
		end
	end

	return active_entries
end

function M.is_repeat_active(start_date, target_date, repeat_pattern)
	-- Normalize dates to noon
	start_date = vim.tbl_extend("force", {}, start_date)
	start_date.hour, start_date.min, start_date.sec = 12, 0, 0
	target_date = vim.tbl_extend("force", {}, target_date)
	target_date.hour, target_date.min, target_date.sec = 12, 0, 0

	local start_time = os.time(start_date)
	local target_time = os.time(target_date)

	-- Don't show repeats before the start date
	if target_time < start_time then
		return false
	end

	-- Parse repeat patterns: daily, weekly, monthly, yearly, or custom like "3d", "2w"
	if repeat_pattern == "daily" then
		return true
	elseif repeat_pattern == "weekly" then
		local days_diff = math.floor((target_time - start_time) / 86400)
		return days_diff % 7 == 0
	elseif repeat_pattern == "monthly" then
		return target_date.day == start_date.day
	elseif repeat_pattern == "yearly" then
		return target_date.month == start_date.month and target_date.day == start_date.day
	else
		-- Handle patterns like "3d", "2w", "1m"
		local num, unit = repeat_pattern:match("^(%d+)([dwmy])$")
		if num and unit then
			num = tonumber(num)
			local days_diff = math.floor((target_time - start_time) / 86400)

			if unit == "d" then
				return days_diff % num == 0
			elseif unit == "w" then
				return days_diff % (num * 7) == 0
			elseif unit == "m" then
				-- Simple month calculation (not perfect for all edge cases)
				local month_diff = (target_date.year - start_date.year) * 12 + (target_date.month - start_date.month)
				return month_diff % num == 0 and target_date.day == start_date.day
			elseif unit == "y" then
				local year_diff = target_date.year - start_date.year
				return year_diff % num == 0
					and target_date.month == start_date.month
					and target_date.day == start_date.day
			end
		end
	end

	return false
end

return M
