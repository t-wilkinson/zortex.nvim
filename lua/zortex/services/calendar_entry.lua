-- services/calendar_entry.lua - Calendar entry model
local M = {}
local M_mt = { __index = M }

local Config = require("zortex.config")
local parser = require("zortex.utils.parser")
local datetime = require("zortex.utils.datetime")
local attributes = require("zortex.utils.attributes")
local constants = require("zortex.constants")

-- =============================================================================
-- Calendar Entry Creation
-- =============================================================================

function M:new(data)
	local entry = {
		raw_text = data.raw_text or "",
		display_text = data.display_text or data.raw_text or "",
		date_context = data.date_context or "", -- The date this entry belongs to
		type = data.type or "note", -- note, event, task
		attributes = data.attributes or {},
		task = data.task,
		-- Computed fields
		time = nil, -- Extracted from attributes.at
		duration = nil, -- From attributes.dur or est
		date_range = nil, -- From attributes.from/to
	}

	setmetatable(entry, M_mt)
	entry:_compute_fields()
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
-- Entry Methods
-- =============================================================================

function M:_compute_fields()
	-- Extract time
	if self.attributes.at then
		self.time = self.attributes.at
	elseif self.attributes.from then
		self.time = self.attributes.from
	end

	-- Extract duration
	self.duration = self.attributes.dur or self.attributes.est

	-- Extract date range for @from/@to attributes
	if self.attributes.from and self.attributes.to then
		self.date_range = {
			from = self.attributes.from,
			to = self.attributes.to,
		}
	end
end

function M:get_start_time()
	return self.time
end

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

-- Pretty‑print attributes
function M:format_pretty()
	local parts = {}

	-- Start with task checkbox if it's a task
	if self.type == "task" then
		local status = constants.TASK_SYMBOL[self.task.mark]
		table.insert(parts, status and status.symbol or "")
	end

	-- Add the display text
	table.insert(parts, self.display_text)

	-- Add formatted attributes
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
	if attr_at then
		if has_time(attr_at) then
			local format = "YYYY-MM-DD hh:mm"
			if date_context and datetime.is_same_day(attr_at, date_context) then
				format = "hh:mm"
			end
			table.insert(attr_parts, "🕐 " .. datetime.format_date(attr_at, format))
		else -- All-day event
			table.insert(attr_parts, "🗓️ " .. datetime.format_date(attr_at, "YYYY-MM-DD"))
		end
	elseif attr_from or attr_to then
		local time_range_str
		local icon = "🕐"

		-- An event is "all-day" if either the from or to attribute exists and lacks a time.
		if (attr_from and not has_time(attr_from)) or (attr_to and not has_time(attr_to)) then
			icon = "🗓️"
		end

		if attr_from and attr_to then
			if icon == "🕐" then
				-- Timed range logic
				if datetime.is_same_day(attr_from, attr_to) then
					local time_from_str = datetime.format_date(attr_from, "hh:mm")
					local time_to_str = datetime.format_date(attr_to, "hh:mm")
					if date_context and datetime.is_same_day(attr_from, date_context) then
						time_range_str = time_from_str .. "-" .. time_to_str
					else
						local date_str = datetime.format_date(attr_from, "YYYY-MM-DD")
						time_range_str = date_str .. " " .. time_from_str .. "-" .. time_to_str
					end
				else
					local from_full_str = datetime.format_date(attr_from, "YYYY-MM-DD hh:mm")
					local to_full_str = datetime.format_date(attr_to, "YYYY-MM-DD hh:mm")
					time_range_str = from_full_str .. " - " .. to_full_str
				end
			else
				-- All-day range logic
				if datetime.is_same_day(attr_from, attr_to) then
					time_range_str = datetime.format_date(attr_from, "YYYY-MM-DD")
				else
					time_range_str = datetime.format_date(attr_from, "YYYY-MM-DD")
						.. " - "
						.. datetime.format_date(attr_to, "YYYY-MM-DD")
				end
			end
		elseif attr_from then
			local format = (icon == "🕐") and "YYYY-MM-DD hh:mm" or "YYYY-MM-DD"
			if icon == "🕐" and date_context and datetime.is_same_day(attr_from, date_context) then
				format = "hh:mm"
			end
			time_range_str = datetime.format_date(attr_from, format) .. " - ..."
		elseif attr_to then
			local format = (icon == "🕐") and "YYYY-MM-DD hh:mm" or "YYYY-MM-DD"
			if icon == "🕐" and date_context and datetime.is_same_day(attr_to, date_context) then
				format = "hh:mm"
			end
			time_range_str = "... - " .. datetime.format_date(attr_to, format)
		end

		table.insert(attr_parts, icon .. " " .. time_range_str)
	end

	-- Duration attributes
	if self.attributes.dur then
		table.insert(attr_parts, string.format("⏱ %s", attributes.format_duration(self.attributes.dur)))
	elseif self.attributes.est then
		table.insert(attr_parts, string.format("⏱ ~%s", attributes.format_duration(self.attributes.est)))
	end

	-- Notification
	if self.attributes.notify then
		table.insert(attr_parts, "🔔")
	end

	-- Repeat pattern
	if self.attributes["repeat"] then
		table.insert(attr_parts, "🔁 " .. self.attributes["repeat"])
	end

	-- Priority/importance
	if self.attributes.p then
		table.insert(attr_parts, "P" .. self.attributes.p)
	end
	if self.attributes.i then
		table.insert(attr_parts, "I" .. self.attributes.i)
	end

	-- Add attributes if any
	if #attr_parts > 0 then
		table.insert(parts, " " .. table.concat(attr_parts, "  "))
	end

	return table.concat(parts, "")
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
			time_str = datetime.format_date(attr_at, format)
		else -- All-day event
			time_str = datetime.format_date(attr_at, "YYYY-MM-DD")
		end
	elseif attr_from or attr_to then
		local is_all_day = (attr_from and not has_time(attr_from)) or (attr_to and not has_time(attr_to))

		if attr_from and attr_to then
			if not is_all_day then
				-- Timed range
				if datetime.is_same_day(attr_from, attr_to) then
					local time_from_str = datetime.format_date(attr_from, "hh:mm")
					local time_to_str = datetime.format_date(attr_to, "hh:mm")
					if date_context and datetime.is_same_day(attr_from, date_context) then
						time_str = time_from_str .. "-" .. time_to_str
					else
						local date_str = datetime.format_date(attr_from, "YYYY-MM-DD")
						time_str = date_str .. "@" .. time_from_str .. "-" .. time_to_str
					end
				else
					local from_full_str = datetime.format_date(attr_from, "YYYY-MM-DD@hh:mm")
					local to_full_str = datetime.format_date(attr_to, "YYYY-MM-DD@hh:mm")
					time_str = from_full_str .. "-" .. to_full_str
				end
			else
				-- All-day range
				if datetime.is_same_day(attr_from, attr_to) then
					time_str = datetime.format_date(attr_from, "YYYY-MM-DD")
				else
					time_str = datetime.format_date(attr_from, "YYYY-MM-DD")
						.. "-"
						.. datetime.format_date(attr_to, "YYYY-MM-DD")
				end
			end
		elseif attr_from then
			local format = not is_all_day and "YYYY-MM-DD@hh:mm" or "YYYY-MM-DD"
			if not is_all_day and date_context and datetime.is_same_day(attr_from, date_context) then
				format = "hh:mm"
			end
			time_str = datetime.format_date(attr_from, format) .. "-..."
		elseif attr_to then
			local format = not is_all_day and "YYYY-MM-DD@hh:mm" or "YYYY-MM-DD"
			if not is_all_day and date_context and datetime.is_same_day(attr_to, date_context) then
				format = "hh:mm"
			end
			time_str = "...-" .. datetime.format_date(attr_to, format)
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
