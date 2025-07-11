-- core/datetime.lua - Date and time utilities for Zortex
local M = {}

local constants = require("zortex.constants")

--- Parses a date string into a table.
-- Supports YYYY-MM-DD and MM-DD-YYYY formats.
-- @param date_str string The date string to parse.
-- @return table|nil A table with {year, month, day} or nil if parsing fails.
function M.parse_date(date_str)
	if not date_str then
		return nil
	end

	-- YYYY-MM-DD
	local y, m, d = date_str:match(constants.PATTERNS.DATE_YMD)
	if y then
		return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
	end

	-- MM-DD-YYYY
	local m2, d2, y2 = date_str:match(constants.PATTERNS.DATE_MDY)
	if m2 then
		return { year = tonumber(y2), month = tonumber(m2), day = tonumber(d2) }
	end

	return nil
end

--- Parses a time string into a table.
-- Supports 24-hour (HH:MM) and 12-hour (HH:MMam/pm) formats.
-- @param time_str string The time string to parse.
-- @return table|nil A table with {hour, min} or nil if parsing fails.
function M.parse_time(time_str)
	if not time_str then
		return nil
	end

	local hour, min, ampm = nil, nil, nil

	-- HH:MM format (24-hour)
	hour, min = time_str:match(constants.PATTERNS.TIME_24H)
	if hour then
		return { hour = tonumber(hour), min = tonumber(min) }
	end

	-- HH:MM am/pm formats
	hour, min, ampm = time_str:match(constants.PATTERNS.TIME_AMPM)
	if hour then
		local h = tonumber(hour)
		if ampm == "pm" and h ~= 12 then
			h = h + 12
		elseif ampm == "am" and h == 12 then -- Midnight case
			h = 0
		end
		return { hour = h, min = tonumber(min) }
	end

	return nil
end

--- Parses a datetime string into a single date table.
-- @param dt_str string The datetime string (e.g., "YYYY-MM-DD HH:MM").
-- @param default_date_str string (Optional) A date string to use if dt_str is only a time.
-- @return table|nil A table with {year, month, day, hour, min} or nil.
function M.parse_datetime(dt_str, default_date_str)
	if not dt_str then
		return nil
	end

	-- Try date + time
	local date_part, time_part = dt_str:match(constants.PATTERNS.DATETIME_YMD)
	if date_part and time_part then
		local date = M.parse_date(date_part)
		local time = M.parse_time(time_part)
		if date and time then
			date.hour = time.hour
			date.min = time.min
			return date
		end
	end

	-- Try date only
	local date = M.parse_date(dt_str)
	if date then
		date.hour = 0
		date.min = 0
		return date
	end

	-- Try time only with a default date
	local time = M.parse_time(dt_str)
	if time and default_date_str then
		local default_date = M.parse_date(default_date_str)
		if default_date then
			default_date.hour = time.hour
			default_date.min = time.min
			return default_date
		end
	end

	return nil
end

--- Formats a date table into a string.
-- @param date_tbl table A table with {year, month, day, [hour], [min]}.
-- @param format_str string The format string (e.g., "YYYY-MM-DD").
-- @return string The formatted date string.
function M.format_date(date_tbl, format_str)
	local replacements = {
		["YYYY"] = string.format("%04d", date_tbl.year),
		["MM"] = string.format("%02d", date_tbl.month),
		["DD"] = string.format("%02d", date_tbl.day),
		["hh"] = string.format("%02d", date_tbl.hour or 0),
		["mm"] = string.format("%02d", date_tbl.min or 0),
	}
	return (
		format_str
			:gsub("YYYY", replacements.YYYY)
			:gsub("MM", replacements.MM)
			:gsub("DD", replacements.DD)
			:gsub("hh", replacements.hh)
			:gsub("mm", replacements.mm)
	)
end

return M
