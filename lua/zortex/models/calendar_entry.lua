-- models/calendar_entry.lua - Calendar entry model
local M = {}
local M_mt = { __index = M }

local datetime = require("zortex.core.datetime")
local parser = require("zortex.core.parser")
local attributes = require("zortex.core.attributes")
local config = require("zortex.config")

-- =============================================================================
-- Calendar Entry Creation
-- =============================================================================

function M:new(data)
	local entry = {
		raw_text = data.raw_text or "",
		display_text = data.display_text or data.raw_text or "",
		date_context = data.date_context, -- The date this entry belongs to
		type = data.type or "note", -- note, event, task
		attributes = data.attributes or {},
		task_status = data.task_status,
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
function M.from_text(entry_text, date_context)
	local data = {
		raw_text = entry_text,
		date_context = date_context,
	}

	local working_text = entry_text

	-- Check for task status
	if parser.is_task_line("- " .. working_text) then
		data.task_status = parser.parse_task_status("- " .. working_text)
		if data.task_status then
			data.type = "task"
			-- Strip the checkbox pattern
			working_text = working_text:match("^%[.%]%s+(.+)$") or working_text
		end
	end

	-- Parse attributes
	local attrs, remaining_text = parser.parse_attributes(working_text, attributes.schemas.calendar_entry)
	data.attributes = attrs or {}
	data.display_text = remaining_text

	-- Determine type based on attributes if not already a task
	if data.type ~= "task" then
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
		self.time = datetime.parse_time(self.attributes.at)
	end

	-- Extract duration
	self.duration = self.attributes.dur or self.attributes.est

	-- Extract date range
	if self.attributes.from or self.attributes.to then
		self.date_range = {
			from = self.attributes.from,
			to = self.attributes.to,
		}
	end
end

-- Check if entry is active on a given date
function M:is_active_on_date(date)
	local target_date = datetime.parse_date(date)
	if not target_date then
		return false
	end

	-- Normalize to noon to avoid DST issues
	target_date.hour, target_date.min, target_date.sec = 12, 0, 0
	local target_time = os.time(target_date)

	-- Check date range
	if self.date_range then
		local in_range = false

		if self.date_range.from and self.date_range.to then
			local from_time = os.time(vim.tbl_extend("force", self.date_range.from, { hour = 12, min = 0, sec = 0 }))
			local to_time = os.time(vim.tbl_extend("force", self.date_range.to, { hour = 12, min = 0, sec = 0 }))
			in_range = target_time >= from_time and target_time <= to_time
		elseif self.date_range.from then
			local from_time = os.time(vim.tbl_extend("force", self.date_range.from, { hour = 12, min = 0, sec = 0 }))
			in_range = target_time >= from_time
		elseif self.date_range.to then
			local to_time = os.time(vim.tbl_extend("force", self.date_range.to, { hour = 12, min = 0, sec = 0 }))
			in_range = target_time <= to_time
		end

		if in_range then
			return true
		end
	end

	-- Check repeat pattern
	if self.attributes["repeat"] and self.date_context then
		local start_date = datetime.parse_date(self.date_context)
		if start_date then
			return self:is_repeat_active(start_date, target_date)
		end
	end

	-- Default: active only on its own date
	return self.date_context == date
end

-- Check if repeat pattern is active
function M:is_repeat_active(start_date, target_date)
	local repeat_pattern = self.attributes["repeat"]
	if not repeat_pattern then
		return false
	end

	-- Normalize dates
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
	if self.time then
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
		if self.task_status and self.task_status.key ~= "[x]" then
			priority = priority + 300
		else
			priority = priority + 100
		end
	end

	-- Add time-based priority
	if self.time then
		priority = priority + (24 - self.time.hour) * 10 + (60 - self.time.min) / 6
	end

	return priority
end

-- =============================================================================
-- Format calendar entry
-- =============================================================================

-- Format entry depending on calendar pretty_attributes setting
function M:format()
	-- TODO: cache the config value?
	return config.get("ui.calendar.pretty_attributes") and self:format_pretty() or self:format_simple()
end

-- Pretty‑print attributes
function M:format_pretty()
	if not self.attributes then
		return ""
	end

	local parts = {}

	-- Time attributes
	local time_str = self:get_time_string()
	if time_str then
		table.insert(parts, "🕐 " .. self.attributes.at)
	end

	-- Duration attributes
	if self.attributes.dur then
		table.insert(parts, string.format("⏱ %dm", self.attributes.dur))
	elseif self.attributes.est then
		table.insert(parts, string.format("⏱ ~%dm", self.attributes.est))
	end

	-- Notification
	if self.attributes.notify then
		table.insert(parts, "🔔")
	end

	-- Repeat pattern
	if self.attributes["repeat"] then
		table.insert(parts, "🔁 " .. self.attributes["repeat"])
	end

	-- Date range
	if self.attributes.from or self.attributes.to then
		local range_parts = {}
		if self.attributes.from then
			table.insert(range_parts, datetime.format_date(self.attributes.from, "MM/DD"))
		else
			table.insert(range_parts, "...")
		end
		table.insert(range_parts, "→")
		if self.attributes.to then
			table.insert(range_parts, datetime.format_date(self.attributes.to, "MM/DD"))
		else
			table.insert(range_parts, "...")
		end
		table.insert(parts, table.concat(range_parts, " "))
	end

	if #parts > 0 then
		return self.display_text .. "  " .. table.concat(parts, "  ")
	end
	return self.display_text
end

-- Format attributes in simple mode
function M:format_simple()
	if not self.attributes then
		return ""
	end

	local parts = {}

	-- Compact time display
	if self.attributes.at then
		table.insert(parts, self.attributes.at)
	end

	-- Compact duration
	if self.attributes.dur then
		table.insert(parts, self.attributes.dur .. "m")
	elseif self.attributes.est then
		table.insert(parts, "~" .. self.attributes.est .. "m")
	end

	-- Simple indicators
	if self.attributes.notify then
		table.insert(parts, "!")
	end

	if self.attributes["repeat"] then
		table.insert(parts, "R")
	end

	-- Compact date range
	if self.attributes.from and self.attributes.to then
		local from_str = datetime.format_date(self.attributes.from, "MM/DD")
		local to_str = datetime.format_date(self.attributes.to, "MM/DD")
		table.insert(parts, from_str .. "-" .. to_str)
	elseif self.attributes.from then
		table.insert(parts, datetime.format_date(self.attributes.from, "MM/DD") .. "+")
	elseif self.attributes.to then
		table.insert(parts, "-" .. datetime.format_date(self.attributes.to, "MM/DD"))
	end

	if #parts > 0 then
		return " [" .. table.concat(parts, " ") .. "]"
	end
	return ""
end

return M
