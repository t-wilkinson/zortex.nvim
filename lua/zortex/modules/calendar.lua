-- modules/calendar.lua - Calendar functionality for Zortex
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local utils = require("zortex.core.utils")

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
	local status_key = working_text:match("^(%[.%])%s+")
	if status_key then
		parsed.task_status = parser.parse_task_status("- " .. working_text)
		parsed.type = "task"
		working_text = working_text:sub(#status_key + 1)
	end

	-- 2. Check for time prefix or range
	local from_time, to_time, rest = working_text:match("^(%d%d?:%d%d)%-(%d%d?:%d%d)%s+(.+)$")
	if from_time and to_time then
		parsed.attributes.from = from_time
		parsed.attributes.to = to_time
		parsed.attributes.at = from_time
		parsed.type = "event"
		working_text = rest
	else
		local time_prefix, rest = working_text:match("^(%d%d?:%d%d)%s+(.+)$")
		if time_prefix then
			parsed.attributes.at = time_prefix
			parsed.type = "event"
			working_text = rest
		end
	end

	-- 3. Parse attributes using unified parser
	local attr_definitions = {
		-- Time/date attributes
		{ name = "at", pattern = "@at%(([^)]+)%)" },
		{ name = "due", pattern = "@due%(([^)]+)%)" },
		{ name = "from", pattern = "@from%(([^)]+)%)" },
		{ name = "to", pattern = "@to%(([^)]+)%)" },
		{ name = "repeating", pattern = "@repeat%(([^)]+)%)" },

		-- Notification attributes
		{
			name = "notify",
			pattern = "@notify%(([^)]+)%)",
			transform = function(val)
				parsed.attributes.notification_enabled = true
				return val
			end,
		},
		{
			name = "n",
			pattern = "@n%(([^)]+)%)",
			transform = function(val)
				parsed.attributes.notification_enabled = true
				return val
			end,
		},

		-- Other attributes
		{
			name = "duration",
			pattern = "@(%d+%.?%d*[hmd])",
			transform = parser.parse_duration,
		},
		{
			name = "priority",
			pattern = "@p([123])",
			transform = function(p)
				return "p" .. p
			end,
		},
		{ name = "context", pattern = "@(%w+)" },
	}

	local attrs, remaining = parser.parse_attributes(working_text, attr_definitions)
	parsed.attributes = vim.tbl_extend("force", parsed.attributes, attrs)

	-- Check for notification flags without parentheses
	if
		remaining:match("@n%s")
		or remaining:match("@n$")
		or remaining:match("@notify%s")
		or remaining:match("@notify$")
		or remaining:match("@event%s")
		or remaining:match("@event$")
	then
		parsed.attributes.notification_enabled = true
		parsed.type = "event"
		remaining = remaining:gsub("@n", ""):gsub("@notify", ""):gsub("@event", "")
	end

	parsed.display_text = parser.trim(remaining)

	return parsed
end

-- =============================================================================
-- Loading and Saving
-- =============================================================================

function M.load()
	local path = fs.get_file_path("calendar.zortex")
	if not path or not fs.file_exists(path) then
		return false
	end

	-- Reset state
	state.entries = {}

	local lines = fs.read_lines(path)
	if not lines then
		return false
	end

	local current_date = nil
	for _, line in ipairs(lines) do
		-- Check for date header (MM-DD-YYYY:)
		local m, d, y = line:match("^(%d%d)%-(%d%d)%-(%d%d%d%d):$")
		if m and d and y then
			current_date = string.format("%04d-%02d-%02d", y, m, d)
			state.entries[current_date] = {}
		elseif current_date and line:match("^%s+%- ") then
			-- Entry line
			local entry_text = line:match("^%s+%- (.+)$")
			if entry_text then
				local parsed = parse_calendar_entry(entry_text, current_date)
				table.insert(state.entries[current_date], parsed)
			end
		elseif current_date and line:match("^%s+%d%d?:%d%d ") then
			-- Time-prefixed entry (legacy format)
			local entry_text = line:match("^%s+(.+)$")
			if entry_text then
				local parsed = parse_calendar_entry(entry_text, current_date)
				table.insert(state.entries[current_date], parsed)
			end
		end
	end

	return true
end

function M.save()
	local path = fs.get_file_path("calendar.zortex")
	if not path then
		return false
	end

	local lines = {}

	-- Get sorted dates
	local dates = {}
	for date in pairs(state.entries) do
		table.insert(dates, date)
	end
	table.sort(dates)

	-- Write entries
	for _, date_str in ipairs(dates) do
		local entries = state.entries[date_str]
		if entries and #entries > 0 then
			-- Convert YYYY-MM-DD to MM-DD-YYYY for file format
			local y, m, d = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
			table.insert(lines, string.format("%s-%s-%s:", m, d, y))

			for _, entry in ipairs(entries) do
				table.insert(lines, "  - " .. entry.raw_text)
			end
			table.insert(lines, "")
		end
	end

	return fs.write_lines(path, lines)
end

-- =============================================================================
-- Entry Management
-- =============================================================================

function M.add_entry(date_str, entry_text)
	if not state.entries[date_str] then
		state.entries[date_str] = {}
	end

	local parsed = parse_calendar_entry(entry_text, date_str)
	table.insert(state.entries[date_str], parsed)

	return M.save()
end

function M.remove_entry(date_str, entry_index)
	if state.entries[date_str] and state.entries[date_str][entry_index] then
		table.remove(state.entries[date_str], entry_index)

		-- Remove date if no entries left
		if #state.entries[date_str] == 0 then
			state.entries[date_str] = nil
		end

		return M.save()
	end
	return false
end

function M.update_entry(date_str, entry_index, new_text)
	if state.entries[date_str] and state.entries[date_str][entry_index] then
		local parsed = parse_calendar_entry(new_text, date_str)
		state.entries[date_str][entry_index] = parsed
		return M.save()
	end
	return false
end

-- =============================================================================
-- Query Functions
-- =============================================================================

-- Get entries for a specific date (including recurring)
function M.get_entries_for_date(date_str)
	local target_date = parser.parse_date(date_str)
	if not target_date then
		return {}
	end

	local target_time = os.time(target_date)
	local active_entries = {}
	local seen = {} -- Track duplicates

	-- 1. Direct entries for the date
	if state.entries[date_str] then
		for _, entry in ipairs(state.entries[date_str]) do
			table.insert(active_entries, entry)
			seen[entry.raw_text] = true
		end
	end

	-- 2. Check for recurring and ranged entries
	for orig_date_str, entries in pairs(state.entries) do
		local orig_date = parser.parse_date(orig_date_str)
		if orig_date then
			local orig_time = os.time(orig_date)

			for _, entry in ipairs(entries) do
				if not seen[entry.raw_text] then
					local include = false

					-- Check recurring
					if entry.attributes.repeating and target_time > orig_time then
						local repeat_val = entry.attributes.repeating:lower()
						local diff_days = math.floor((target_time - orig_time) / 86400)

						if repeat_val == "daily" then
							include = true
						elseif repeat_val == "weekly" and diff_days > 0 and diff_days % 7 == 0 then
							include = true
						elseif repeat_val == "monthly" then
							-- Simple monthly check (same day of month)
							if target_date.day == orig_date.day then
								include = true
							end
						end
					end

					-- Check date range
					if entry.attributes.from or entry.attributes.to then
						local from_dt = parser.parse_datetime(entry.attributes.from, orig_date_str)
						local to_dt = parser.parse_datetime(entry.attributes.to, orig_date_str)
						local from_time = from_dt and os.time(from_dt) or orig_time
						local to_time = to_dt and os.time(to_dt) or from_time

						if target_time >= from_time and target_time <= to_time then
							include = true
						end
					end

					-- Check due date
					if entry.attributes.due then
						local due_dt = parser.parse_datetime(entry.attributes.due, orig_date_str)
						if due_dt then
							local due_str = string.format("%04d-%02d-%02d", due_dt.year, due_dt.month, due_dt.day)
							if due_str == date_str then
								include = true
							end
						end
					end

					if include then
						local instance = utils.deepcopy(entry)
						instance.original_date = orig_date_str
						instance.effective_date = date_str
						table.insert(active_entries, instance)
						seen[entry.raw_text] = true
					end
				end
			end
		end
	end

	return active_entries
end

-- Get all entries
function M.get_all_entries()
	return state.entries
end

-- Get entries in date range
function M.get_entries_in_range(start_date, end_date)
	local start_time = os.time(parser.parse_date(start_date))
	local end_time = os.time(parser.parse_date(end_date))
	local results = {}

	for date_str, _ in pairs(state.entries) do
		local date = parser.parse_date(date_str)
		if date then
			local date_time = os.time(date)
			if date_time >= start_time and date_time <= end_time then
				local entries = M.get_entries_for_date(date_str)
				if #entries > 0 then
					results[date_str] = entries
				end
			end
		end
	end

	return results
end

-- Get upcoming events
function M.get_upcoming_events(days_ahead)
	days_ahead = days_ahead or 7
	local today = os.date("%Y-%m-%d")
	local future_date = os.date("%Y-%m-%d", os.time() + (days_ahead * 86400))

	local events = {}
	local range = M.get_entries_in_range(today, future_date)

	for date_str, entries in pairs(range) do
		for _, entry in ipairs(entries) do
			if entry.type == "event" or entry.attributes.at then
				table.insert(events, {
					date = date_str,
					entry = entry,
				})
			end
		end
	end

	-- Sort by date and time
	table.sort(events, function(a, b)
		if a.date ~= b.date then
			return a.date < b.date
		end
		local a_time = a.entry.attributes.at or "00:00"
		local b_time = b.entry.attributes.at or "00:00"
		return a_time < b_time
	end)

	return events
end

-- =============================================================================
-- Integration with Projects
-- =============================================================================

-- Get project tasks scheduled for a date
function M.get_project_tasks_for_date(date_str)
	local projects = require("zortex.features.projects")
	if not projects.get_all_tasks then
		return {}
	end

	local tasks = {}
	local all_tasks = projects.get_all_tasks()

	for _, task in ipairs(all_tasks) do
		-- Check if task has date attributes
		if task.attributes.due then
			local due_dt = parser.parse_datetime(task.attributes.due)
			if due_dt then
				local due_str = string.format("%04d-%02d-%02d", due_dt.year, due_dt.month, due_dt.day)
				if due_str == date_str then
					table.insert(tasks, task)
				end
			end
		end
	end

	return tasks
end

return M
