-- core/datetime.lua - Date and time utilities for Zortex
local M = {}

local constants = require("zortex.constants")

--- Gets the current date as a table.
-- @return table A table with {year, month, day, wday}
function M.get_current_date()
	local now = os.date("*t")
	return {
		year = now.year,
		month = now.month,
		day = now.day,
		wday = now.wday,
		hour = now.hour,
		min = now.min,
		sec = now.sec,
	}
end

--- Adds days to a date.
-- @param date table A date table with {year, month, day}
-- @param days number Number of days to add (can be negative)
-- @return table A new date table
function M.add_days(date, days)
	local time = os.time({
		year = date.year,
		month = date.month,
		day = date.day,
		hour = date.hour or 12, -- Use noon to avoid DST issues
		min = date.min or 0,
		sec = date.sec or 0,
	})
	local new_time = time + (days * 86400)
	local new_date = os.date("*t", new_time)
	return {
		year = new_date.year,
		month = new_date.month,
		day = new_date.day,
		wday = new_date.wday,
		hour = new_date.hour,
		min = new_date.min,
		sec = new_date.sec,
	}
end

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

local duration_multipliers = {
	m = 1, -- minutes
	h = 60, -- hours to minutes
	d = 60 * 24, -- days to minutes
	w = 60 * 24 * 7, -- weeks to minutes
}

-- Parse duration and units and return in minutes
function M.parse_duration(duration)
	local num, unit = duration:match("(%d+%.?%d*)%s*([hdmw])")
	local total = num * (duration_multipliers[unit] or 0)
	return total > 0 and total or nil
end

-- Parse multiple duration num+unit pairs
function M.parse_durations(durations)
	local total = 0
	for num, unit in durations:gmatch("(%d+%.?%d*)%s*([hdmw])") do
		num = tonumber(num)
		total = total + (num * (duration_multipliers[unit] or 0))
	end
	return total > 0 and total or nil
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

--- Compares two dates.
-- @param date1 table First date
-- @param date2 table Second date
-- @return number -1 if date1 < date2, 0 if equal, 1 if date1 > date2
function M.compare_dates(date1, date2)
	local time1 = os.time(date1)
	local time2 = os.time(date2)

	if time1 < time2 then
		return -1
	elseif time1 > time2 then
		return 1
	else
		return 0
	end
end

--- Gets the day of week name.
-- @param wday number Day of week (1-7, Sunday is 1)
-- @return string Day name
function M.get_day_name(wday)
	local days = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
	return days[wday] or ""
end

--- Gets the month name.
-- @param month number Month (1-12)
-- @return string Month name
function M.get_month_name(month)
	local months = {
		"January",
		"February",
		"March",
		"April",
		"May",
		"June",
		"July",
		"August",
		"September",
		"October",
		"November",
		"December",
	}
	return months[month] or ""
end

--- Checks if a year is a leap year.
-- @param year number The year
-- @return boolean True if leap year
function M.is_leap_year(year)
	return (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
end

--- Gets the number of days in a month.
-- @param year number The year
-- @param month number The month (1-12)
-- @return number Number of days
function M.get_days_in_month(year, month)
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if month == 2 and M.is_leap_year(year) then
		return 29
	end
	return days[month] or 30
end

--- Calculates the difference in days between two dates.
-- @param date1 table First date
-- @param date2 table Second date
-- @return number Number of days (positive if date2 > date1)
function M.days_between(date1, date2)
	local time1 = os.time({
		year = date1.year,
		month = date1.month,
		day = date1.day,
		hour = 12,
		min = 0,
		sec = 0,
	})
	local time2 = os.time({
		year = date2.year,
		month = date2.month,
		day = date2.day,
		hour = 12,
		min = 0,
		sec = 0,
	})
	return math.floor((time2 - time1) / 86400)
end

--- Formats a relative date string.
-- @param date table The date to format
-- @param reference table Optional reference date (defaults to today)
-- @return string Relative date string (e.g., "Today", "Tomorrow", "Next Monday")
function M.format_relative_date(date, reference)
	reference = reference or M.get_current_date()
	local days_diff = M.days_between(reference, date)

	if days_diff == 0 then
		return "Today"
	elseif days_diff == 1 then
		return "Tomorrow"
	elseif days_diff == -1 then
		return "Yesterday"
	elseif days_diff > 0 and days_diff <= 7 then
		return M.get_day_name(date.wday or os.date("*t", os.time(date)).wday)
	elseif days_diff > 7 and days_diff <= 14 then
		return "Next " .. M.get_day_name(date.wday or os.date("*t", os.time(date)).wday)
	else
		return os.date("%b %d", os.time(date))
	end
end

return M
