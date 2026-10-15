-- services/calendar_entry/format - Calendar entries as display text
--
--   pretty(entry)  "☐ 🕐 14:00-15:00 ⏱ ~30m 🔁 weekly  Text P1  I2"   (icons)
--   simple(entry)  "x Text [14:00-15:00 ~30m ! R:weekly P1 I2]"        (compact)
--   format(entry)  one of the two, per Config.ui.calendar.pretty_attributes
local M = {}

local Config = require("zortex.config")
local datetime = require("zortex.utils.datetime")
local attributes = require("zortex.utils.attributes")
local constants = require("zortex.constants")

function M.format(entry)
	return Config.ui.calendar.pretty_attributes and M.pretty(entry) or M.simple(entry)
end

-- =============================================================================
-- Pretty
-- =============================================================================

local function timing_text(entry)
	local timing = entry.timing
	local context = entry.date_context and datetime.parse_date(entry.date_context)
	local function show_date(dt)
		return not (context and datetime.is_same_day(dt, context))
	end
	local function fmt(dt)
		if not dt then
			return "..."
		end
		if dt.hour and dt.min then
			return datetime.format_datetime(dt, show_date(dt) and "YYYY-MM-DD hh:mm" or "hh:mm")
		end
		return datetime.format_datetime(dt, "YYYY-MM-DD")
	end

	if timing.type == "point" then
		return fmt(timing.start)
	elseif timing.type == "range" then
		local s, e = timing.start, timing["end"]
		-- Same-day time range on the entry's own date: "14:00-15:00"
		if s and e and datetime.is_same_day(s, e) and s.hour and s.min and not show_date(s) then
			return datetime.format_datetime(s, "hh:mm") .. "-" .. datetime.format_datetime(e, "hh:mm")
		end
		return fmt(s) .. " - " .. fmt(e)
	elseif timing.type == "open_start" then
		return fmt(timing.start) .. " →"
	elseif timing.type == "open_end" then
		return "→ " .. fmt(timing["end"])
	elseif timing.type == "deadline" then
		return fmt(timing["end"])
	end
	return nil
end

function M.pretty(entry)
	local parts = {}
	if entry.type == "task" then
		local status = constants.TASK_SYMBOL[entry.mark]
		table.insert(parts, status and status.symbol or "")
	end

	local timing = entry.timing
	if timing then
		local time_str = timing_text(entry)
		if time_str then
			table.insert(parts, (entry:is_all_day() and "🗓️" or "🕐") .. " " .. time_str)
		end
		local duration, estimated = entry:get_duration()
		if duration then
			if estimated then
				table.insert(parts, "⏱ ~" .. attributes.format_duration(duration))
			elseif timing.buffer then
				table.insert(parts, "⏱ +" .. attributes.format_duration(timing.buffer))
			end
		end
		if entry:is_deadline() then
			table.insert(parts, "⚠️ Deadline")
		end
	end

	if entry.attributes["repeat"] then
		table.insert(parts, "🔁 " .. entry.attributes["repeat"])
	end

	table.insert(parts, " " .. entry.text)

	local extra = {}
	if entry.attributes.p then
		table.insert(extra, "P" .. entry.attributes.p)
	end
	if entry.attributes.i then
		table.insert(extra, "I" .. entry.attributes.i)
	end
	if #extra > 0 then
		table.insert(parts, " " .. table.concat(extra, "  "))
	end
	return table.concat(parts, "")
end

-- =============================================================================
-- Simple
-- =============================================================================

local function has_time(dt)
	return dt and dt.hour ~= nil and dt.min ~= nil
end

-- Compact time: "14:00", "14:00-15:00", "2026-10-12@10:00", "2026-10-12-2026-10-14", ...
local function compact_time(entry)
	local attrs = entry.attributes
	local context = entry.date_context and datetime.parse_date(entry.date_context)
	local function on_context_day(dt)
		return context and datetime.is_same_day(dt, context)
	end
	local at, from, to = attrs.at, attrs.from, attrs.to

	if at then
		if not has_time(at) then
			return datetime.format_datetime(at, "YYYY-MM-DD")
		end
		return datetime.format_datetime(at, on_context_day(at) and "hh:mm" or "YYYY-MM-DD@hh:mm")
	end
	if not (from or to) then
		return nil
	end

	local all_day = (from and not has_time(from)) or (to and not has_time(to))
	if from and to then
		if all_day then
			if datetime.is_same_day(from, to) then
				return datetime.format_datetime(from, "YYYY-MM-DD")
			end
			return datetime.format_datetime(from, "YYYY-MM-DD") .. "-" .. datetime.format_datetime(to, "YYYY-MM-DD")
		end
		if datetime.is_same_day(from, to) then
			local times = datetime.format_datetime(from, "hh:mm") .. "-" .. datetime.format_datetime(to, "hh:mm")
			if on_context_day(from) then
				return times
			end
			return datetime.format_datetime(from, "YYYY-MM-DD") .. "@" .. times
		end
		return datetime.format_datetime(from, "YYYY-MM-DD@hh:mm") .. "-" .. datetime.format_datetime(to, "YYYY-MM-DD@hh:mm")
	end

	local dt = from or to
	local fmt = all_day and "YYYY-MM-DD" or "YYYY-MM-DD@hh:mm"
	if not all_day and on_context_day(dt) then
		fmt = "hh:mm"
	end
	if from then
		return datetime.format_datetime(from, fmt) .. "-..."
	end
	return "...-" .. datetime.format_datetime(to, fmt)
end

function M.simple(entry)
	local parts = {}
	if entry.type == "task" and entry.completed then
		table.insert(parts, entry.mark)
	end
	table.insert(parts, entry.text)

	local attrs = entry.attributes
	local extra = {}
	local time_str = compact_time(entry)
	if time_str then
		table.insert(extra, time_str)
	end
	if attrs.dur then
		table.insert(extra, attributes.format_duration(attrs.dur))
	elseif attrs.est then
		table.insert(extra, "~" .. (attributes.format_duration(attrs.est)))
	end
	if attrs.notify then
		table.insert(extra, "!")
	end
	if attrs["repeat"] then
		table.insert(extra, "R:" .. attrs["repeat"])
	end
	if attrs.p then
		table.insert(extra, "P" .. attrs.p)
	end
	if attrs.i then
		table.insert(extra, "I" .. attrs.i)
	end
	if #extra > 0 then
		table.insert(parts, "[" .. table.concat(extra, " ") .. "]")
	end
	return table.concat(parts, " ")
end

return M
