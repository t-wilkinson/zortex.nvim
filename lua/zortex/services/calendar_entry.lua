-- services/calendar_entry.lua - Calendar entry model
local M = {}
local M_mt = { __index = M }

local Config = require("zortex.config")
local parser = require("zortex.utils.parser")
local datetime = require("zortex.utils.datetime")
local attributes = require("zortex.utils.attributes")
local constants = require("zortex.constants")
local Logger = require("zortex.core.logger")

-- =============================================================================
-- Calendar Entry Creation
-- =============================================================================

function M:new(data)
	local entry = {
		raw_text = data.raw_text or "",
		display_text = data.display_text or data.raw_text or "",
		date_context = data.date_context or nil, -- The date this entry belongs to
		type = data.type or "note", -- note, event, task
		attributes = data.attributes or {},
		task = data.task,
		-- Computed fields
		timing = nil,
	}

	setmetatable(entry, M_mt)
	entry:_compute_timing()
	return entry
end

-- Parse a calendar entry from text
function M.from_text(entry_text, current_date_str)
	local data = {
		raw_text = entry_text,
		date_context = current_date_str,
	}

	local working_text = entry_text

	-- Check for task checkbox at the beginning
	local task = parser.parse_task(working_text, {
		default_date_str = current_date_str,
	})

	if task then
		-- It's a task - extract the checkbox and parse status
		data.type = "task"
		data.task = task
		data.attributes = task.attributes
		data.display_text = task.text
	else
		-- Check for time range format: "10:00 - 12:00 rest of text"
		local at_time, from_time, to_time, remaining
		working_text = working_text:match("^%s*%- (.*)$")

		if not working_text then
			return nil
		end

		from_time, to_time, remaining = working_text:match("(%d%d?:%d%d)%s*%-%s*(%d%d?:%d%d)%s+(.*)$")
		if from_time and to_time and remaining then
			working_text = remaining
			-- Add the time attributes
			working_text = attributes.update_attribute(working_text, "from", from_time)
			working_text = attributes.update_attribute(working_text, "to", to_time)
		else
			-- Check for single time prefix: "10:00 rest of text"
			at_time, remaining = entry_text:match("(%d%d?:%d%d)%s+(.*)$")
			if at_time and remaining then
				working_text = remaining
				working_text = attributes.update_attribute(working_text, "at", at_time)
			end
		end

		-- Parse attributes
		local attrs, remaining_text = attributes.parse_calendar_attributes(working_text, {
			default_date_str = current_date_str,
		})
		data.attributes = attrs or {}
		data.display_text = remaining_text

		-- Determine type based on attributes
		if attrs.from or attrs.to or attrs.at then
			data.type = "event"
		end
	end

	return M:new(data)
end

-- =============================================================================
-- Datetime methods
-- =============================================================================

-- Compute unified timing information from attributes
function M:_compute_timing()
	local attrs = self.attributes

	if attrs.at then
		self.timing = {
			type = "point",
			start = attrs.at,
			duration = attrs.dur or attrs.est,
			estimated = attrs.est ~= nil,
		}
	elseif attrs.from then
		self.timing = {
			type = "range",
			start = attrs.from,
			["end"] = attrs.to,
			buffer = attrs.buffer,
		}
	elseif attrs.range then
		self.timing = {
			type = "range",
			start = attrs.range.start,
			["end"] = attrs.range["end"],
			buffer = attrs.buffer,
		}
		-- elseif attrs.after then
		-- 	-- Open-ended start
		-- 	local datetime_obj = self:_parse_time_spec(attrs.after)

		-- 	self.timing = {
		-- 		type = "open_start",
		-- 		start = datetime_obj,
		-- 		duration = attrs.est,
		-- 	}
		-- elseif attrs.before or attrs.deadline then
		-- 	-- Open-ended end
		-- 	local datetime_obj = self:_parse_time_spec(attrs.before or attrs.deadline)

		-- 	self.timing = {
		-- 		type = attrs.deadline and "deadline" or "open_end",
		-- 		["end"] = datetime_obj,
		-- 	}
	end

	-- Add recurrence if present
	if attrs.every then
		self.timing = self.timing or {}
		self.timing.recurrence = attrs.every
	end
end

function M:get_start_time()
	return self.timing and self.timing.start
end

function M:get_end_time()
	if not self.timing then
		return nil
	end

	-- If we have an explicit end time
	if self.timing["end"] then
		return self.timing["end"]
	end

	-- If we have a start time and duration, calculate end
	if self.timing.start and self.timing.duration then
		return datetime.add_duration(self.timing.start, self.timing.duration)
	end

	return nil
end

function M:is_deadline()
	return self.timing and self.timing.type == "deadline"
end

function M:is_all_day()
	if not self.timing or not self.timing.start then
		return false
	end
	return not (self.timing.start.hour and self.timing.start.min)
end

function M:get_duration()
	if not self.timing then
		return nil
	end

	-- Explicit duration
	if self.timing.duration then
		return self.timing.duration, self.timing.estimated
	end

	-- Calculate from range
	if self.timing.start and self.timing["end"] then
		return datetime.diff(self.timing["end"], self.timing.start), false
	end

	return nil, false
end

-- =============================================================================
-- Entry Methods
-- =============================================================================

-- Check if entry is active on a given date
function M:is_active_on_date(date)
	local target_date = datetime.parse_date(date)
	if not target_date then
		return false
	end

	-- 1. Check if the entry is a ranged event and the target date falls within it.
	if self.attributes.from and self.attributes.to then
		local from_date = self.attributes.from
		local to_date = self.attributes.to

		-- Normalize dates to compare just the day part, ignoring time.
		-- We set the hour to 12 to avoid DST issues.
		local target_time =
			os.time({ year = target_date.year, month = target_date.month, day = target_date.day, hour = 12 })
		local from_time = os.time({ year = from_date.year, month = from_date.month, day = from_date.day, hour = 12 })
		local to_time = os.time({ year = to_date.year, month = to_date.month, day = to_date.day, hour = 12 })

		if target_time >= from_time and target_time <= to_time then
			return true -- It's active on this day.
		end
	end

	-- 2. Check if the entry is explicitly on this date (its context).
	if self.date_context == date then
		return true
	end

	-- 3. Check if the entry repeats on this date.
	if self.attributes["repeat"] and self.date_context then
		local start_date = datetime.parse_date(self.date_context)
		if start_date and self:is_repeat_active(start_date, target_date) then
			return true
		end
	end

	return false
end

-- Check if repeat pattern is active
function M:is_repeat_active(start_date, target_date)
	local repeat_pattern = self.attributes["repeat"]
	if not repeat_pattern then
		return false
	end

	-- Normalize dates to noon to avoid DST issues
	start_date = vim.tbl_extend("force", {}, start_date, { hour = 12, min = 0, sec = 0 })
	target_date = vim.tbl_extend("force", {}, target_date, { hour = 12, min = 0, sec = 0 })

	local start_time = os.time(start_date)
	local target_time = os.time(target_date)

	if target_time < start_time then
		return false
	end

	-- Parse repeat patterns
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
				-- For monthly repeats, check if it's the same day of month
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

-- Get formatted time string
function M:get_time_string()
	if self.time and self.time.hour and self.time.min then
		return string.format("%02d:%02d", self.time.hour, self.time.min)
	elseif self.attributes.at then
		return self.attributes.at
	end
	return nil
end

-- Get sort priority (for ordering entries)
function M:get_sort_priority()
	-- Priority order: notifications > events > incomplete tasks > completed tasks > notes
	local priority = 0

	if self.attributes.notify then
		priority = priority + 1000
	end

	if self.type == "event" then
		priority = priority + 500
	elseif self.type == "task" then
		if self.task.completed then
			priority = priority + 300
		else
			priority = priority + 100
		end
	end

	-- Add time-based priority
	if self.time and self.time.hour ~= nil and self.time.min ~= nil then
		-- Timed entries are sorted by time, earlier first
		priority = priority + (24 - self.time.hour) * 10 + (60 - self.time.min) / 6
	elseif self.time then
		-- All-day entries get a high priority to appear at the top of the list for that day
		priority = priority + 300
	end

	return priority
end

-- =============================================================================
-- Format calendar entry
-- =============================================================================

-- Format entry depending on calendar pretty_attributes setting
function M:format()
	return Config.ui.calendar.pretty_attributes and self:format_pretty() or self:format_simple()
end

function M:format_pretty()
	local parts = {}

	-- Task checkbox
	if self.type == "task" then
		local status = constants.TASK_SYMBOL[self.task.mark]
		table.insert(parts, status and status.symbol or "")
	end

	-- Format timing attributes
	local attr_parts = {}

	if self.timing then
		local icon = self:is_all_day() and "🗓️" or "🕐"
		local time_str = self:_format_timing()

		if time_str then
			table.insert(parts, icon .. " " .. time_str)
		end

		-- Duration (if estimated or has buffer)
		local duration, is_estimated = self:get_duration()
		if duration then
			if is_estimated then
				table.insert(parts, "⏱ ~" .. attributes.format_duration(duration))
			elseif self.timing.buffer then
				table.insert(parts, "⏱ +" .. attributes.format_duration(self.timing.buffer))
			end
		end

		-- Deadline indicator
		if self:is_deadline() then
			table.insert(parts, "⚠️ Deadline")
		end

		-- Recurrence
		if self.timing.recurrence then
			local rec_str = self:_format_recurrence(self.timing.recurrence)
			table.insert(parts, "🔁 " .. rec_str)
		end
	end

	-- Display text
	table.insert(parts, self.display_text)

	-- Other attributes
	if self.attributes.notify then
		table.insert(attr_parts, "🔔")
	end

	if self.attributes.p then
		table.insert(attr_parts, "P" .. self.attributes.p)
	end

	if self.attributes.i then
		table.insert(attr_parts, "I" .. self.attributes.i)
	end

	-- Combine
	if #attr_parts > 0 then
		table.insert(parts, " " .. table.concat(attr_parts, "  "))
	end

	return table.concat(parts, "")
end

function M:_format_timing()
	if not self.timing then
		return nil
	end

	local date_context = self.date_context and datetime.parse_date(self.date_context)
	local function should_show_date(dt)
		return not (date_context and datetime.is_same_day(dt, date_context))
	end

	local function fmt_datetime(dt)
		if not dt then
			return "..."
		end

		if dt.hour and dt.min then
			-- Has time
			if should_show_date(dt) then
				return datetime.format_datetime(dt, "YYYY-MM-DD hh:mm")
			else
				return datetime.format_datetime(dt, "hh:mm")
			end
		else
			-- Date only
			return datetime.format_datetime(dt, "YYYY-MM-DD")
		end
	end

	if self.timing.type == "point" then
		return fmt_datetime(self.timing.start)
	elseif self.timing.type == "range" then
		local start_str = fmt_datetime(self.timing.start)
		local end_str = fmt_datetime(self.timing["end"])

		-- Optimize for same-day ranges
		if self.timing.start and self.timing["end"] and datetime.is_same_day(self.timing.start, self.timing["end"]) then
			if self.timing.start.hour and self.timing.start.min then
				-- Time range on same day
				if not should_show_date(self.timing.start) then
					return datetime.format_datetime(self.timing.start, "hh:mm")
						.. "-"
						.. datetime.format_datetime(self.timing["end"], "hh:mm")
				end
			end
		end

		return start_str .. " - " .. end_str
	elseif self.timing.type == "open_start" then
		return fmt_datetime(self.timing.start) .. " →"
	elseif self.timing.type == "open_end" then
		return "→ " .. fmt_datetime(self.timing["end"])
	elseif self.timing.type == "deadline" then
		return fmt_datetime(self.timing["end"])
	end

	return nil
end

function M:_format_recurrence(recurrence)
	local pattern = recurrence.pattern

	-- Handle simple patterns
	if pattern == "day" or pattern == "daily" then
		return "daily"
	elseif pattern == "week" or pattern == "weekly" then
		if #recurrence.modifiers > 0 then
			return "weekly (" .. table.concat(recurrence.modifiers, ",") .. ")"
		end
		return "weekly"
	elseif pattern == "month" or pattern == "monthly" then
		if #recurrence.modifiers > 0 then
			return "monthly (day " .. recurrence.modifiers[1] .. ")"
		end
		return "monthly"
	else
		-- Handle interval patterns like "2w", "3d"
		return pattern
	end
end

-- Format attributes in simple mode
function M:format_simple()
	local parts = {}

	-- Start with task checkbox if it's a task
	if self.type == "task" and self.task.completed then
		table.insert(parts, self.task.mark)
	end

	-- Add the display text
	table.insert(parts, self.display_text)

	-- Add compact attributes
	local attr_parts = {}
	local date_context = self.date_context and datetime.parse_date(self.date_context)

	local attr_at = self.attributes.at
	local attr_from = self.attributes.from
	local attr_to = self.attributes.to

	-- Helper to check if a datetime object has a time component
	local function has_time(dt)
		return dt and dt.hour ~= nil and dt.min ~= nil
	end

	-- Time attributes
	local time_str
	if attr_at then
		if has_time(attr_at) then
			local format = "YYYY-MM-DD@hh:mm"
			if date_context and datetime.is_same_day(attr_at, date_context) then
				format = "hh:mm"
			end
			time_str = datetime.format_datetime(attr_at, format)
		else -- All-day event
			time_str = datetime.format_datetime(attr_at, "YYYY-MM-DD")
		end
	elseif attr_from or attr_to then
		local is_all_day = (attr_from and not has_time(attr_from)) or (attr_to and not has_time(attr_to))

		if attr_from and attr_to then
			if not is_all_day then
				-- Timed range
				if datetime.is_same_day(attr_from, attr_to) then
					local time_from_str = datetime.format_datetime(attr_from, "hh:mm")
					local time_to_str = datetime.format_datetime(attr_to, "hh:mm")
					if date_context and datetime.is_same_day(attr_from, date_context) then
						time_str = time_from_str .. "-" .. time_to_str
					else
						local date_str = datetime.format_datetime(attr_from, "YYYY-MM-DD")
						time_str = date_str .. "@" .. time_from_str .. "-" .. time_to_str
					end
				else
					local from_full_str = datetime.format_datetime(attr_from, "YYYY-MM-DD@hh:mm")
					local to_full_str = datetime.format_datetime(attr_to, "YYYY-MM-DD@hh:mm")
					time_str = from_full_str .. "-" .. to_full_str
				end
			else
				-- All-day range
				if datetime.is_same_day(attr_from, attr_to) then
					time_str = datetime.format_datetime(attr_from, "YYYY-MM-DD")
				else
					time_str = datetime.format_datetime(attr_from, "YYYY-MM-DD")
						.. "-"
						.. datetime.format_datetime(attr_to, "YYYY-MM-DD")
				end
			end
		elseif attr_from then
			local format = not is_all_day and "YYYY-MM-DD@hh:mm" or "YYYY-MM-DD"
			if not is_all_day and date_context and datetime.is_same_day(attr_from, date_context) then
				format = "hh:mm"
			end
			time_str = datetime.format_datetime(attr_from, format) .. "-..."
		elseif attr_to then
			local format = not is_all_day and "YYYY-MM-DD@hh:mm" or "YYYY-MM-DD"
			if not is_all_day and date_context and datetime.is_same_day(attr_to, date_context) then
				format = "hh:mm"
			end
			time_str = "...-" .. datetime.format_datetime(attr_to, format)
		end
	end

	if time_str then
		table.insert(attr_parts, time_str)
	end

	-- Compact duration
	if self.attributes.dur then
		table.insert(attr_parts, attributes.format_duration(self.attributes.dur))
	elseif self.attributes.est then
		table.insert(attr_parts, "~" .. (attributes.format_duration(self.attributes.est)))
	end

	-- Simple indicators
	if self.attributes.notify then
		table.insert(attr_parts, "!")
	end

	if self.attributes["repeat"] then
		table.insert(attr_parts, "R:" .. self.attributes["repeat"])
	end

	-- Priority/importance
	if self.attributes.p then
		table.insert(attr_parts, "P" .. self.attributes.p)
	end
	if self.attributes.i then
		table.insert(attr_parts, "I" .. self.attributes.i)
	end

	if #attr_parts > 0 then
		table.insert(parts, "[" .. table.concat(attr_parts, " ") .. "]")
	end

	return table.concat(parts, " ")
end

return M
