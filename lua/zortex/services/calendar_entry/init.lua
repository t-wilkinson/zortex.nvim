-- services/calendar_entry - A calendar entry: an Item (core/item) under a date
--
-- Entries are list items below a "YYYY-MM-DD:" heading in the calendar note:
-- "- [ ] task", "- note", "14:00 event", "16:00 - 17:00 event",
-- "- 09:00 event". An entry is the line's Item (raw_text, marker, key, mark,
-- completed, body, attributes, ...) plus:
--
--   type          "task" (has a checkbox) | "event" (has a time) | "note"
--   text          display text: attributes and the time prefix removed
--   date_context  the date heading it is under ("YYYY-MM-DD")
--   timing        { type = "point"|"range", start, end?, duration?, buffer? }
--
-- Text formats for the calendar view, digest and notifications live in
-- calendar_entry/format.
local M = {}

local Item = require("zortex.core.item")
local datetime = require("zortex.utils.datetime")
local attributes = require("zortex.utils.attributes")

local Entry = setmetatable({}, { __index = Item.Item })
Entry.__index = Entry
M.Entry = Entry

local function format()
	return require("zortex.services.calendar_entry.format")
end

-- =============================================================================
-- Parsing
-- =============================================================================

-- Timing from the time attributes (at; from/to; range)
local function compute_timing(attrs)
	local timing
	if attrs.at then
		timing = { type = "point", start = attrs.at, duration = attrs.dur or attrs.est, estimated = attrs.est ~= nil }
	elseif attrs.from then
		timing = { type = "range", start = attrs.from, ["end"] = attrs.to, buffer = attrs.buffer }
	elseif attrs.range then
		timing = { type = "range", start = attrs.range.start, ["end"] = attrs.range["end"], buffer = attrs.buffer }
	end
	return timing
end

--- The entry on a line under the date heading `date_str`, or nil when the
--- line is not a list item.
function M.from_text(line, date_str)
	local context = { default_date_str = date_str }
	local entry = Item.from_line(line, { context = context })
	if not entry then
		return nil
	end
	setmetatable(entry, Entry)
	entry.date_context = date_str

	if entry.mark then
		entry.type = "task"
	else
		-- Time prefix: on the item itself ("14:00 text") or after a bullet
		-- ("- 14:00 text"); it becomes @at / @from @to
		local text = entry.marker_type == "time" and vim.trim(line) or entry.body
		local from_time, to_time, rest = text:match("^(%d%d?:%d%d)%s*%-%s*(%d%d?:%d%d)%s+(.*)$")
		if from_time then
			text = attributes.update_attribute(rest, "from", from_time)
			text = attributes.update_attribute(text, "to", to_time)
		else
			local at_time, after = text:match("^(%d%d?:%d%d)%s+(.*)$")
			if at_time then
				text = attributes.update_attribute(after, "at", at_time)
			end
		end
		local attrs, remaining = attributes.parse_calendar_attributes(text, context)
		entry.attributes, entry.text = attrs or {}, remaining
		entry.type = "note"
		if entry.attributes.from or entry.attributes.to or entry.attributes.at then
			entry.type = "event"
			if entry.attributes.notify == nil then
				entry.attributes.notify = true
			end
		end
	end
	entry.timing = compute_timing(entry.attributes)
	return entry
end

-- =============================================================================
-- Time
-- =============================================================================

function Entry:get_start_time()
	return self.timing and self.timing.start
end

function Entry:get_end_time()
	local timing = self.timing
	if not timing then
		return nil
	end
	if timing["end"] then
		return timing["end"]
	end
	if timing.start and timing.duration then
		return datetime.add_duration(timing.start, timing.duration)
	end
	return nil
end

function Entry:is_deadline()
	return self.timing and self.timing.type == "deadline"
end

function Entry:is_all_day()
	if not self.timing or not self.timing.start then
		return false
	end
	return not (self.timing.start.hour and self.timing.start.min)
end

--- Minutes, and whether the duration is an estimate.
function Entry:get_duration()
	local timing = self.timing
	if not timing then
		return nil
	end
	if timing.duration then
		return timing.duration, timing.estimated
	end
	if timing.start and timing["end"] then
		return datetime.diff(timing["end"], timing.start), false
	end
	return nil, false
end

--- "HH:MM" of the start, or nil.
function Entry:get_time_string()
	local start = self:get_start_time()
	if start and start.hour and start.min then
		return string.format("%02d:%02d", start.hour, start.min)
	elseif self.attributes.at then
		return self.attributes.at
	end
	return nil
end

-- =============================================================================
-- Dates
-- =============================================================================

-- Noon of a date, as seconds (noon avoids DST edges)
local function noon(d)
	return os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
end

--- Whether the entry shows on `date` ("YYYY-MM-DD"): a from/to range that
--- covers it, its own date, or a @repeat that lands on it.
function Entry:is_active_on_date(date)
	local target = datetime.parse_date(date)
	if not target then
		return false
	end
	local attrs = self.attributes
	if attrs.from and attrs.to then
		local t = noon(target)
		if t >= noon(attrs.from) and t <= noon(attrs.to) then
			return true
		end
	end
	if self.date_context == date then
		return true
	end
	if attrs["repeat"] and self.date_context then
		local start = datetime.parse_date(self.date_context)
		if start and self:is_repeat_active(start, target) then
			return true
		end
	end
	return false
end

--- Whether @repeat (daily, weekly, monthly, yearly, Nd, Nw, Nm, Ny) starting
--- on `start_date` lands on `target_date`.
function Entry:is_repeat_active(start_date, target_date)
	local pattern = self.attributes["repeat"]
	if not pattern then
		return false
	end
	start_date = vim.tbl_extend("force", {}, start_date, { hour = 12, min = 0, sec = 0 })
	target_date = vim.tbl_extend("force", {}, target_date, { hour = 12, min = 0, sec = 0 })
	local start_time, target_time = os.time(start_date), os.time(target_date)
	if target_time < start_time then
		return false
	end
	local days = math.floor((target_time - start_time) / 86400)
	local same_day_of_month = target_date.day == start_date.day
	local same_day_of_year = target_date.month == start_date.month and same_day_of_month

	if pattern == "daily" then
		return true
	elseif pattern == "weekly" then
		return days % 7 == 0
	elseif pattern == "monthly" then
		return same_day_of_month
	elseif pattern == "yearly" then
		return same_day_of_year
	end
	local num, unit = pattern:match("^(%d+)([dwmy])$")
	num = tonumber(num)
	if not num then
		return false
	end
	if unit == "d" then
		return days % num == 0
	elseif unit == "w" then
		return days % (num * 7) == 0
	elseif unit == "m" then
		local months = (target_date.year - start_date.year) * 12 + (target_date.month - start_date.month)
		return months % num == 0 and same_day_of_month
	else -- "y"
		return (target_date.year - start_date.year) % num == 0 and same_day_of_year
	end
end

-- =============================================================================
-- Ordering and display
-- =============================================================================

--- Higher sorts first: notifications, events, open tasks, done tasks, notes;
--- earlier times first; all-day entries near the top.
function Entry:get_sort_priority()
	local priority = 0
	if self.attributes.notify then
		priority = priority + 1000
	end
	if self.type == "event" then
		priority = priority + 500
	elseif self.type == "task" then
		priority = priority + (self.completed and 300 or 100)
	end
	local start = self:get_start_time()
	if start and start.hour ~= nil and start.min ~= nil then
		priority = priority + (24 - start.hour) * 10 + (60 - start.min) / 6
	elseif start then
		priority = priority + 300
	end
	return priority
end

--- Display text per Config.ui.calendar.pretty_attributes.
function Entry:format()
	return format().format(self)
end

function Entry:format_pretty()
	return format().pretty(self)
end

return M
