-- calendar.lua - Enhanced Calendar view and management for Zortex
-- Provides popup calendar view, weekly view, and Telescope integration
-- Stores calendar data in Calendar.zortex file
-- Now with support for tasks, events, and project management

local M = {}

-- Dependencies
local api = vim.api
local fn = vim.fn

-- Constants
local CALENDAR_FILE = "calendar.zortex"
local DAYS = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
local DAYS_FULL = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = {
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

-- Task status indicators
local TASK_STATUS = {
	["[ ]"] = { symbol = "☐", hl = "Comment" },
	["[x]"] = { symbol = "☑", hl = "String" },
	["[!]"] = { symbol = "⚠", hl = "ErrorMsg" },
	["[~]"] = { symbol = "◐", hl = "WarningMsg" },
	["[@]"] = { symbol = "⏸", hl = "Comment" },
}

-- State
local state = {
	current_date = nil, -- Selected date (cursor position)
	today = nil, -- Today's actual date
	calendar_data = {},
	calendar_buf = nil,
	calendar_win = nil,
	view_mode = "month", -- "month" or "week"
	parsed_entries = {}, -- Parsed entry data with attributes
}

-- Initialize current date
local function init_current_date()
	local today = os.date("*t")
	state.today = {
		year = today.year,
		month = today.month,
		day = today.day,
	}
	state.current_date = {
		year = today.year,
		month = today.month,
		day = today.day,
	}
end

init_current_date()

-- =============================================================================
-- HELPERS
-- =============================================================================

--- Deep copy a table
local function deepcopy(orig)
	local orig_type = type(orig)
	local copy
	if orig_type == "table" then
		copy = {}
		for orig_key, orig_value in next, orig, nil do
			copy[deepcopy(orig_key)] = deepcopy(orig_value)
		end
		setmetatable(copy, deepcopy(getmetatable(orig)))
	else -- number, string, boolean, etc
		copy = orig
	end
	return copy
end

--- Convert time string (e.g., "9am", "14:30", "3pm") to a sortable number
local function parse_time(time_str)
	if not time_str then
		return nil
	end
	time_str = time_str:lower()

	-- Match HH:MM format
	local hour, minute = time_str:match("^(%d+):(%d%d)$")
	if hour and minute then
		return tonumber(hour) + (tonumber(minute) / 60)
	end

	-- Match 9am, 2pm, etc.
	local num, ampm = time_str:match("^(%d+)(am|pm)$")
	if num then
		num = tonumber(num)
		if ampm == "pm" and num ~= 12 then
			num = num + 12
		elseif ampm == "am" and num == 12 then -- Midnight case
			num = 0
		end
		return num
	end

	return nil -- Cannot parse
end

--- Parse a date string (YYYY-MM-DD) into a table
local function parse_date(date_str)
	if not date_str then
		return nil
	end
	local year, month, day = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if year then
		return { year = tonumber(year), month = tonumber(month), day = tonumber(day) }
	end
	return nil
end

-- =============================================================================
-- ENTRY PARSING & FORMATTING
-- =============================================================================

--- Parse a single entry line for attributes and task status
local function parse_entry(entry_text)
	local parsed = {
		raw_text = entry_text,
		text = entry_text,
		task_status = nil,
		attributes = {},
		type = "note", -- note, task, event, project
	}

	-- Check for time prefix (HH:MM) which implies an event
	local time_prefix, rest_of_line = entry_text:match("^(%d%d:%d%d)%s+(.+)$")
	if time_prefix then
		parsed.attributes.at = time_prefix
		entry_text = rest_of_line
		parsed.text = rest_of_line
	end

	-- Check for task status
	local status_pattern = "^(%[.%]) (.+)$"
	local status, remaining = entry_text:match(status_pattern)
	if status and TASK_STATUS[status] then
		parsed.task_status = status
		parsed.text = remaining
		parsed.type = "task"
		entry_text = remaining
	end

	-- Parse attributes
	local attribute_patterns = {
		at = "@at%(([^)]+)%)",
		duration = "@(%d+%.?%d*[hm][ri]?n?)",
		due = "@due%((%d%d%d%d%-%d%d%-%d%d)%)",
		from = "@from%((%d%d%d%d%-%d%d%-%d%d)%)",
		to = "@to%((%d%d%d%d%-%d%d%-%d%d)%)",
		priority = "@p([123])",
		repeating = "@repeat%(([^)]+)%)",
		notify = "@notify%(([^)]+)%)",
		context = "@(%w+)",
	}

	-- Extract all attributes
	for attr_name, pattern in pairs(attribute_patterns) do
		for value in entry_text:gmatch(pattern) do
			parsed.attributes[attr_name] = value
			entry_text = entry_text:gsub(pattern:gsub("%%", "%%%%"), "")
		end
	end

	-- Determine entry type based on attributes
	if parsed.attributes.at then
		parsed.type = "event"
	elseif parsed.attributes.from or parsed.attributes.to then
		parsed.type = "project"
	end

	-- Clean up display text
	parsed.display_text = entry_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

	return parsed
end

--- Format parsed entry for display
local function format_entry_display(parsed_entry, show_attributes)
	local display = ""

	-- Add task status
	if parsed_entry.task_status then
		local status_info = TASK_STATUS[parsed_entry.task_status]
		display = status_info.symbol .. " "
	end

	-- Add main text
	display = display .. parsed_entry.display_text

	-- Add instance markers for recurring/due items
	if parsed_entry.is_recurring_instance then
		display = display .. " 🔁"
	end
	if parsed_entry.is_due_date_instance then
		display = display .. " ❗"
	end

	-- Add key attributes if requested
	if show_attributes then
		local attrs = {}
		if parsed_entry.attributes.at then
			table.insert(attrs, "🕐 " .. parsed_entry.attributes.at)
		end
		if parsed_entry.attributes.due and not parsed_entry.is_due_date_instance then
			table.insert(attrs, "📅 " .. parsed_entry.attributes.due)
		end
		if parsed_entry.attributes.repeating then
			table.insert(attrs, "🔁 " .. parsed_entry.attributes.repeating)
		end
		if parsed_entry.attributes.from and parsed_entry.attributes.to then
			table.insert(attrs, "🗓️ " .. parsed_entry.attributes.from .. "→" .. parsed_entry.attributes.to)
		elseif parsed_entry.attributes.from then
			table.insert(attrs, "🗓️ " .. parsed_entry.attributes.from .. "→")
		elseif parsed_entry.attributes.to then
			table.insert(attrs, "🗓️ →" .. parsed_entry.attributes.to)
		end
		if parsed_entry.attributes.priority then
			table.insert(attrs, "P" .. parsed_entry.attributes.priority)
		end
		if #attrs > 0 then
			display = display .. " (" .. table.concat(attrs, ", ") .. ")"
		end
	end

	return display
end

-- =============================================================================
-- CALENDAR DATA MANAGEMENT
-- =============================================================================

--- Get calendar file path
local function get_calendar_path()
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir then
		vim.notify("g:zortex_notes_dir not set", vim.log.levels.ERROR)
		return nil
	end
	-- Ensure trailing slash
	if not notes_dir:match("/$") then
		notes_dir = notes_dir .. "/"
	end
	return notes_dir .. CALENDAR_FILE
end

--- Parse calendar file and load data
function M.load_calendar_data()
	local path = get_calendar_path()
	if not path then
		return {}
	end

	state.calendar_data = {}
	state.parsed_entries = {}

	if fn.filereadable(path) == 0 then
		return state.calendar_data
	end

	local current_date = nil
	local current_entries = {}
	local current_parsed = {}

	for line in io.lines(path) do
		-- Check for date header (MM-DD-YYYY:)
		local month, day, year = line:match("^(%d%d)%-(%d%d)%-(%d%d%d%d):$")
		if month and day and year then
			-- Save previous date's entries
			if current_date then
				state.calendar_data[current_date] = current_entries
				state.parsed_entries[current_date] = current_parsed
			end
			-- Start new date
			current_date = string.format("%04d-%02d-%02d", year, month, day)
			current_entries = {}
			current_parsed = {}
		elseif current_date and line:match("^%s+%- ") then
			-- Task/entry line
			local entry = line:match("^%s+%- (.+)$")
			if entry then
				table.insert(current_entries, entry)
				table.insert(current_parsed, parse_entry(entry))
			end
		end
	end

	-- Save last date's entries
	if current_date then
		state.calendar_data[current_date] = current_entries
		state.parsed_entries[current_date] = current_parsed
	end

	return state.calendar_data
end

--- Save calendar data to file
function M.save_calendar_data()
	local path = get_calendar_path()
	if not path then
		return false
	end

	local file = io.open(path, "w")
	if not file then
		vim.notify("Failed to open calendar file for writing", vim.log.levels.ERROR)
		return false
	end

	-- Sort dates to ensure the file is always in chronological order.
	-- This handles inserting new dates into their correct position.
	local dates = {}
	for date in pairs(state.calendar_data) do
		table.insert(dates, date)
	end
	table.sort(dates)

	-- Write organized by month
	local last_month = nil
	local last_week = nil

	for _, date in ipairs(dates) do
		local year, month, day = date:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
		year, month, day = tonumber(year), tonumber(month), tonumber(day)

		local entries = state.calendar_data[date]
		if entries and #entries > 0 then
			-- Month header
			local month_header = string.format("# %s %d", MONTHS[month], year)
			if last_month ~= month_header then
				if last_month then
					file:write("\n")
				end
				file:write(month_header .. "\n\n")
				last_month = month_header
			end

			-- Week header (optional, using ISO week)
			local t = os.time({ year = year, month = month, day = day })
			local week = tonumber(os.date("%V", t))
			local week_header = string.format("## Week %d", week)
			if last_week ~= week_header then
				file:write(week_header .. "\n\n")
				last_week = week_header
			end

			-- Date and entries MM-DD-YYYY
			file:write(string.format("%02d-%02d-%04d:\n", month, day, year))
			for _, entry in ipairs(entries) do
				file:write("  - " .. entry .. "\n")
			end
			file:write("\n")
		end
	end

	file:close()
	return true
end

--- Add entry to calendar
function M.add_entry(date_str, entry)
	if not state.calendar_data[date_str] then
		state.calendar_data[date_str] = {}
		state.parsed_entries[date_str] = {}
	end
	table.insert(state.calendar_data[date_str], entry)
	table.insert(state.parsed_entries[date_str], parse_entry(entry))
	M.save_calendar_data()
end

-- =============================================================================
-- CALENDAR UTILITIES
-- =============================================================================

--- Get days in month
local function days_in_month(year, month)
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
		return 29
	end
	return days[month]
end

--- Get day of week (0 = Sunday, 6 = Saturday)
local function day_of_week(year, month, day)
	local t = os.time({ year = year, month = month, day = day })
	return tonumber(os.date("%w", t))
end

--- Get ISO week number
local function get_week_number(year, month, day)
	local t = os.time({ year = year, month = month, day = day })
	return tonumber(os.date("%V", t))
end

--- Get week start date (Monday)
local function get_week_start(year, month, day)
	local t = os.time({ year = year, month = month, day = day })
	local dow = tonumber(os.date("%w", t))
	-- Adjust to Monday as start (0 = Sunday, so we need to go back)
	local days_back = dow == 0 and 6 or dow - 1
	local week_start = t - (days_back * 86400)
	local date = os.date("*t", week_start)
	return date.year, date.month, date.day
end

--- Get all entries that are active on a given date, including recurring and ranged events.
local function get_active_entries_for_date(date_str)
	local target_date_obj = parse_date(date_str)
	if not target_date_obj then
		return {}
	end
	local target_time = os.time(target_date_obj)

	local active_entries = {}
	local added_entries = {} -- Track raw text to avoid duplicates

	-- 1. Add standard entries for the day
	if state.parsed_entries[date_str] then
		for _, entry in ipairs(state.parsed_entries[date_str]) do
			if not added_entries[entry.raw_text] then
				table.insert(active_entries, entry)
				added_entries[entry.raw_text] = true
			end
		end
	end

	-- 2. Check all other entries for recurring, ranged, or due attributes
	for original_date_str, entries in pairs(state.parsed_entries) do
		local original_date_obj = parse_date(original_date_str)
		if original_date_obj then
			local original_time = os.time(original_date_obj)

			for _, entry in ipairs(entries) do
				if not added_entries[entry.raw_text] then
					local should_add = false
					-- Check for @repeat
					if entry.attributes.repeating and target_time > original_time then
						local repeat_val = entry.attributes.repeating:lower()
						local diff_days = math.floor((target_time - original_time) / 86400)
						if repeat_val == "daily" then
							should_add = true
						elseif repeat_val == "weekly" and diff_days > 0 and diff_days % 7 == 0 then
							should_add = true
						elseif repeat_val == "monthly" and target_date_obj.day == original_date_obj.day then
							should_add = true
						elseif
							repeat_val == "yearly"
							and target_date_obj.day == original_date_obj.day
							and target_date_obj.month == original_date_obj.month
						then
							should_add = true
						end
					end

					-- Check for @from/@to range
					if entry.attributes.from then
						local from_date = parse_date(entry.attributes.from)
						local to_date = entry.attributes.to and parse_date(entry.attributes.to) or from_date
						if from_date and to_date then
							local from_time = os.time(from_date)
							local to_time = os.time(to_date)
							if target_time >= from_time and target_time <= to_time then
								should_add = true
							end
						end
					end

					if should_add then
						local instance = deepcopy(entry)
						instance.is_recurring_instance = true
						table.insert(active_entries, instance)
						added_entries[entry.raw_text] = true -- Prevent re-adding
					end
				end

				-- Check for @due date separately, as it can appear on its own
				if entry.attributes.due and entry.attributes.due == date_str then
					local due_entry = deepcopy(entry)
					due_entry.is_due_date_instance = true
					table.insert(active_entries, due_entry)
				end
			end
		end
	end

	return active_entries
end

--- Count entries by type for a date
local function count_entries_by_type(date_str)
	local counts = { tasks = 0, events = 0, notes = 0, total = 0 }
	local active_entries = get_active_entries_for_date(date_str)
	if active_entries then
		for _, entry in ipairs(active_entries) do
			counts.total = counts.total + 1
			if entry.type == "task" then
				counts.tasks = counts.tasks + 1
			elseif entry.type == "event" then
				counts.events = counts.events + 1
			else
				counts.notes = counts.notes + 1
			end
		end
	end
	return counts
end

-- =============================================================================
-- MONTH VIEW
-- =============================================================================

--- Generate calendar lines for a month with week numbers
local function generate_month_lines(year, month, show_week_nums)
	local lines = {}
	local num_days = days_in_month(year, month)
	local first_dow = day_of_week(year, month, 1)

	-- Month header
	local header = string.format("%s %d", MONTHS[month], year)
	local header_padding = math.floor((25 - #header) / 2)
	if show_week_nums then
		header_padding = math.floor((28 - #header) / 2)
	end
	table.insert(lines, string.format("%s%s", string.rep(" ", header_padding), header))
	table.insert(lines, "")

	-- Day headers
	if show_week_nums then
		table.insert(lines, " Su Mo Tu We Th Fr Sa  Wk")
	else
		table.insert(lines, " Su Mo Tu We Th Fr Sa")
	end

	-- Calendar grid
	local line = ""
	local week_num = nil

	-- Leading spaces
	for i = 1, first_dow do
		line = line .. "   "
	end

	-- Days
	for day = 1, num_days do
		local date_str = string.format("%04d-%02d-%02d", year, month, day)
		local counts = count_entries_by_type(date_str)

		-- Get week number for first day of each week
		if show_week_nums and ((first_dow + day - 1) % 7 == 0 or day == 1) then
			week_num = get_week_number(year, month, day)
		end

		-- Highlight current selection, today, and days with entries
		local day_str = string.format("%2d", day)
		local is_selected = year == state.current_date.year
			and month == state.current_date.month
			and day == state.current_date.day
		local is_today = year == state.today.year and month == state.today.month and day == state.today.day

		if is_selected then
			day_str = "[" .. day .. "]" -- Selected day marker
		elseif is_today then
			day_str = ">" .. day_str:sub(2) -- Today marker
		elseif counts.total > 0 then
			-- Use different markers for different entry types
			if counts.tasks > 0 then
				day_str = "□" .. day_str:sub(2) -- Has tasks
			elseif counts.events > 0 then
				day_str = "●" .. day_str:sub(2) -- Has events
			else
				day_str = "*" .. day_str:sub(2) -- Has notes
			end
		end

		line = line .. string.format("%3s", day_str)

		-- New line after Saturday
		if (first_dow + day - 1) % 7 == 6 then
			if show_week_nums and week_num then
				line = line .. string.format("  %2d", week_num)
			end
			table.insert(lines, line)
			line = ""
			week_num = nil
		end
	end

	-- Last partial week
	if line ~= "" then
		if show_week_nums and week_num then
			-- Pad to align week number
			local remaining_days = 7 - ((first_dow + num_days - 1) % 7) - 1
			for i = 1, remaining_days do
				line = line .. "   "
			end
			line = line .. string.format("  %2d", week_num)
		end
		table.insert(lines, line)
	end

	return lines
end

--- Generate three-month calendar view
local function generate_three_month_view()
	local lines = {}
	local year = state.current_date.year
	local month = state.current_date.month

	-- Calculate previous and next months
	local prev_month = month - 1
	local prev_year = year
	if prev_month < 1 then
		prev_month = 12
		prev_year = year - 1
	end

	local next_month = month + 1
	local next_year = year
	if next_month > 12 then
		next_month = 1
		next_year = year + 1
	end

	-- Generate calendars
	local prev_cal = generate_month_lines(prev_year, prev_month, false)
	local curr_cal = generate_month_lines(year, month, true) -- Show week numbers for current month
	local next_cal = generate_month_lines(next_year, next_month, false)

	-- Find max lines
	local max_lines = math.max(#prev_cal, #curr_cal, #next_cal)

	-- Combine side by side
	for i = 1, max_lines do
		local prev_line = prev_cal[i] or ""
		local curr_line = curr_cal[i] or ""
		local next_line = next_cal[i] or ""

		-- Pad lines to consistent width
		prev_line = string.format("%-21s", prev_line)
		curr_line = string.format("%-28s", curr_line) -- Extra width for week numbers
		next_line = string.format("%-21s", next_line)

		table.insert(lines, prev_line .. " │ " .. curr_line .. " │ " .. next_line)
	end

	return lines
end

-- =============================================================================
-- WEEK VIEW
-- =============================================================================

--- Generate week view
local function generate_week_view()
	local lines = {}
	local year, month, day = get_week_start(state.current_date.year, state.current_date.month, state.current_date.day)

	-- Week header
	local week_num = get_week_number(state.current_date.year, state.current_date.month, state.current_date.day)
	table.insert(lines, string.format("Week %d, %d", week_num, state.current_date.year))
	table.insert(lines, string.rep("─", 70))
	table.insert(lines, "")

	-- Show each day of the week
	for i = 0, 6 do
		local t = os.time({ year = year, month = month, day = day }) + (i * 86400)
		local date = os.date("*t", t)
		local date_str = string.format("%04d-%02d-%02d", date.year, date.month, date.day)

		-- Day header
		local day_header = string.format("%s, %s %d", DAYS_FULL[date.wday], MONTHS[date.month], date.day)
		local is_today = date.year == state.today.year
			and date.month == state.today.month
			and date.day == state.today.day
		local is_selected = date.year == state.current_date.year
			and date.month == state.current_date.month
			and date.day == state.current_date.day

		if is_selected then
			day_header = "▶ " .. day_header
		elseif is_today then
			day_header = "● " .. day_header
		else
			day_header = "  " .. day_header
		end

		table.insert(lines, day_header)
		table.insert(lines, "  " .. string.rep("─", 50))

		-- Entries for this day (organized by type)
		local parsed = get_active_entries_for_date(date_str)
		if parsed and #parsed > 0 then
			-- Group by type
			local events = {}
			local tasks = {}
			local notes = {}

			for _, entry in ipairs(parsed) do
				if entry.type == "event" then
					table.insert(events, entry)
				elseif entry.type == "task" then
					table.insert(tasks, entry)
				else
					table.insert(notes, entry)
				end
			end

			-- Display events first (sorted by time if available)
			if #events > 0 then
				table.sort(events, function(a, b)
					local time_a = parse_time(a.attributes.at)
					local time_b = parse_time(b.attributes.at)
					if time_a and time_b then
						return time_a < time_b
					elseif time_a then
						return true -- Events with time come before those without
					elseif time_b then
						return false
					else
						return a.raw_text < b.raw_text -- Fallback sort
					end
				end)
				table.insert(lines, "    Events:")
				for _, event in ipairs(events) do
					table.insert(lines, "      " .. format_entry_display(event, true))
				end
			end

			-- Then tasks
			if #tasks > 0 then
				table.insert(lines, "    Tasks:")
				for _, task in ipairs(tasks) do
					table.insert(lines, "      " .. format_entry_display(task, false))
				end
			end

			-- Finally notes
			if #notes > 0 then
				table.insert(lines, "    Notes:")
				for _, note in ipairs(notes) do
					table.insert(lines, "      • " .. note.display_text)
				end
			end
		else
			table.insert(lines, "    (no entries)")
		end
		table.insert(lines, "")
	end

	return lines
end

-- =============================================================================
-- CALENDAR VIEW
-- =============================================================================

--- Create calendar buffer content
local function create_calendar_content()
	local lines = {}

	-- Navigation help
	if state.view_mode == "month" then
		table.insert(lines, "Navigation: h/l = day, j/k = week, J/K = month, H/L = year, w = week view")
	else
		table.insert(lines, "Navigation: j/k = day, J/K = week, m = month view")
	end
	table.insert(lines, "Actions: Enter = go to day, a = add entry, t = today, q = quit")
	table.insert(lines, "Markers: [n] = selected, >n = today, □n = tasks, ●n = events, *n = notes")
	table.insert(lines, string.rep("─", 80))
	table.insert(lines, "")

	if state.view_mode == "month" then
		-- Three-month view
		local month_lines = generate_three_month_view()
		for _, line in ipairs(month_lines) do
			table.insert(lines, line)
		end
	else
		-- Week view
		local week_lines = generate_week_view()
		for _, line in ipairs(week_lines) do
			table.insert(lines, line)
		end
	end

	-- Show entries for selected day
	table.insert(lines, "")
	table.insert(lines, string.rep("─", 80))
	local selected_date_tbl = state.current_date
	local selected_date_str =
		string.format("%04d-%02d-%02d", selected_date_tbl.year, selected_date_tbl.month, selected_date_tbl.day)
	table.insert(lines, string.format("Selected: %s", os.date("%A, %B %d, %Y", os.time(selected_date_tbl))))

	-- Show entry counts
	local counts = count_entries_by_type(selected_date_str)
	if counts.total > 0 then
		local count_parts = {}
		if counts.tasks > 0 then
			table.insert(count_parts, counts.tasks .. " tasks")
		end
		if counts.events > 0 then
			table.insert(count_parts, counts.events .. " events")
		end
		if counts.notes > 0 then
			table.insert(count_parts, counts.notes .. " notes")
		end
		table.insert(lines, "(" .. table.concat(count_parts, ", ") .. ")")
	end
	table.insert(lines, "")

	local parsed = get_active_entries_for_date(selected_date_str)
	if parsed and #parsed > 0 then
		for _, entry in ipairs(parsed) do
			table.insert(lines, "  " .. format_entry_display(entry, true))
		end
	else
		table.insert(lines, "  (no entries)")
	end

	return lines
end

--- Update calendar display
local function update_calendar_display()
	if not state.calendar_buf or not api.nvim_buf_is_valid(state.calendar_buf) then
		return
	end

	local lines = create_calendar_content()
	vim.bo[state.calendar_buf].modifiable = true
	api.nvim_buf_set_lines(state.calendar_buf, 0, -1, false, lines)
	vim.bo[state.calendar_buf].modifiable = false

	-- Apply highlights
	local ns_id = api.nvim_create_namespace("zortex_calendar")
	api.nvim_buf_clear_namespace(state.calendar_buf, ns_id, 0, -1)

	for i, line in ipairs(lines) do
		-- Highlight selected day
		local pattern = "%[%d+%]"
		local start_col = line:find(pattern)
		if start_col then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Visual", i - 1, start_col - 1, start_col + 2)
		end

		-- Highlight today
		local today_pattern = ">%d+"
		local today_col = line:find(today_pattern)
		if today_col then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Special", i - 1, today_col - 1, today_col + 2)
		end

		-- Highlight days with tasks
		local task_pattern = "□%d+"
		local task_col = line:find(task_pattern)
		if task_col then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Function", i - 1, task_col - 1, task_col + 2)
		end

		-- Highlight days with events
		local event_pattern = "●%d+"
		local event_col = line:find(event_pattern)
		if event_col then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Constant", i - 1, event_col - 1, event_col + 2)
		end

		-- Highlight days with notes
		local note_pattern = "%*%d+"
		local note_col = line:find(note_pattern)
		if note_col then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Directory", i - 1, note_col - 1, note_col + 2)
		end

		-- Highlight week view markers
		if line:find("^▶") then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Visual", i - 1, 0, 2)
		elseif line:find("^●") then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Special", i - 1, 0, 2)
		end

		-- Highlight task status symbols
		for status, info in pairs(TASK_STATUS) do
			local symbol = info.symbol
			local col = line:find(symbol, 1, true)
			if col then
				api.nvim_buf_add_highlight(state.calendar_buf, ns_id, info.hl, i - 1, col - 1, col + #symbol - 1)
			end
		end
	end
end

--- Calendar navigation
local function navigate_calendar(direction)
	local year = state.current_date.year
	local month = state.current_date.month
	local day = state.current_date.day

	if state.view_mode == "week" then
		-- Simplified navigation for week view
		if direction == "next_day" or direction == "next_week" then
			local t = os.time({ year = year, month = month, day = day })
			local days_to_add = direction == "next_day" and 1 or 7
			local new_t = t + (days_to_add * 86400)
			local new_date = os.date("*t", new_t)
			year, month, day = new_date.year, new_date.month, new_date.day
		elseif direction == "prev_day" or direction == "prev_week" then
			local t = os.time({ year = year, month = month, day = day })
			local days_to_sub = direction == "prev_day" and 1 or 7
			local new_t = t - (days_to_sub * 86400)
			local new_date = os.date("*t", new_t)
			year, month, day = new_date.year, new_date.month, new_date.day
		elseif direction == "today" then
			local today = os.date("*t")
			year, month, day = today.year, today.month, today.day
			state.today = {
				year = today.year,
				month = today.month,
				day = today.day,
			}
		end
	else
		-- Original month view navigation
		if direction == "next_month" then
			month = month + 1
			if month > 12 then
				month = 1
				year = year + 1
			end
		elseif direction == "prev_month" then
			month = month - 1
			if month < 1 then
				month = 12
				year = year - 1
			end
		elseif direction == "next_year" then
			year = year + 1
		elseif direction == "prev_year" then
			year = year - 1
		elseif direction == "next_week" then
			day = day + 7
			local max_days = days_in_month(year, month)
			if day > max_days then
				day = day - max_days
				month = month + 1
				if month > 12 then
					month = 1
					year = year + 1
				end
			end
		elseif direction == "prev_week" then
			day = day - 7
			if day < 1 then
				month = month - 1
				if month < 1 then
					month = 12
					year = year - 1
				end
				day = days_in_month(year, month) + day
			end
		elseif direction == "next_day" then
			day = day + 1
			local max_days = days_in_month(year, month)
			if day > max_days then
				day = 1
				month = month + 1
				if month > 12 then
					month = 1
					year = year + 1
				end
			end
		elseif direction == "prev_day" then
			day = day - 1
			if day < 1 then
				month = month - 1
				if month < 1 then
					month = 12
					year = year - 1
				end
				day = days_in_month(year, month)
			end
		elseif direction == "today" then
			local today = os.date("*t")
			year = today.year
			month = today.month
			day = today.day
			-- Also update the global today state in case date changed
			state.today = {
				year = today.year,
				month = today.month,
				day = today.day,
			}
		end
	end

	-- Ensure day is valid for the month
	local max_days = days_in_month(year, month)
	if day > max_days then
		day = max_days
	end

	state.current_date = { year = year, month = month, day = day }
	update_calendar_display()
end

--- Toggle view mode
local function toggle_view_mode()
	if state.view_mode == "month" then
		state.view_mode = "week"
	else
		state.view_mode = "month"
	end
	update_calendar_display()
end

--- Setup calendar keymaps
local function setup_calendar_keymaps()
	local buf = state.calendar_buf
	local opts = { noremap = true, silent = true, buffer = buf }

	-- View toggle
	vim.keymap.set("n", "w", function()
		if state.view_mode == "month" then
			toggle_view_mode()
		end
	end, opts)
	vim.keymap.set("n", "m", function()
		if state.view_mode == "week" then
			toggle_view_mode()
		end
	end, opts)

	-- Month/Year navigation (only in month view)
	vim.keymap.set("n", "H", function()
		if state.view_mode == "month" then
			navigate_calendar("prev_year")
		end
	end, opts)
	vim.keymap.set("n", "L", function()
		if state.view_mode == "month" then
			navigate_calendar("next_year")
		end
	end, opts)
	vim.keymap.set("n", "K", function()
		if state.view_mode == "month" then
			navigate_calendar("prev_month")
		else
			navigate_calendar("prev_week")
		end
	end, opts)
	vim.keymap.set("n", "J", function()
		if state.view_mode == "month" then
			navigate_calendar("next_month")
		else
			navigate_calendar("next_week")
		end
	end, opts)

	-- Day navigation (vim-style)
	vim.keymap.set("n", "h", function()
		if state.view_mode == "month" then
			navigate_calendar("prev_day")
		end
	end, opts)
	vim.keymap.set("n", "l", function()
		if state.view_mode == "month" then
			navigate_calendar("next_day")
		end
	end, opts)
	vim.keymap.set("n", "k", function()
		if state.view_mode == "month" then
			navigate_calendar("prev_week")
		else
			navigate_calendar("prev_day")
		end
	end, opts)
	vim.keymap.set("n", "j", function()
		if state.view_mode == "month" then
			navigate_calendar("next_week")
		else
			navigate_calendar("next_day")
		end
	end, opts)

	-- Arrow key support
	vim.keymap.set("n", "<Left>", function()
		navigate_calendar("prev_day")
	end, opts)
	vim.keymap.set("n", "<Right>", function()
		navigate_calendar("next_day")
	end, opts)
	vim.keymap.set("n", "<Up>", function()
		if state.view_mode == "month" then
			navigate_calendar("prev_week")
		else
			navigate_calendar("prev_day")
		end
	end, opts)
	vim.keymap.set("n", "<Down>", function()
		if state.view_mode == "month" then
			navigate_calendar("next_week")
		else
			navigate_calendar("next_day")
		end
	end, opts)

	-- Actions
	vim.keymap.set("n", "t", function()
		navigate_calendar("today")
	end, opts)
	vim.keymap.set("n", "<CR>", function()
		M.go_to_date()
	end, opts)
	vim.keymap.set("n", "a", function()
		M.add_entry_interactive()
	end, opts)
	vim.keymap.set("n", "q", function()
		M.close_calendar()
	end, opts)
	vim.keymap.set("n", "<Esc>", function()
		M.close_calendar()
	end, opts)
end

--- Open calendar view
function M.open_calendar()
	-- Load calendar data
	M.load_calendar_data()

	-- Create buffer
	state.calendar_buf = api.nvim_create_buf(false, true)
	vim.bo[state.calendar_buf].buftype = "nofile"
	vim.bo[state.calendar_buf].bufhidden = "wipe"
	vim.bo[state.calendar_buf].filetype = "zortex-calendar"

	-- Calculate window size
	local width = 85
	local height = 30
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Create window
	state.calendar_win = api.nvim_open_win(state.calendar_buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Zortex Calendar ",
		title_pos = "center",
	})

	-- Setup keymaps and display
	setup_calendar_keymaps()
	update_calendar_display()
end

--- Close calendar view
function M.close_calendar()
	if state.calendar_win and api.nvim_win_is_valid(state.calendar_win) then
		api.nvim_win_close(state.calendar_win, true)
	end
	state.calendar_win = nil
	state.calendar_buf = nil
	state.view_mode = "month" -- Reset to month view
end

--- Go to selected date
function M.go_to_date()
	local date = state.current_date
	local date_str = string.format("%04d-%02d-%02d", date.year, date.month, date.day)

	-- Close calendar
	M.close_calendar()

	local path = get_calendar_path()

	-- Use format: YYYY-MM-DD.zortex
	vim.cmd("edit " .. vim.fn.fnameescape(path))

	-- If new file, add header
	if fn.line("$") == 1 and fn.getline(1) == "" then
		local lines = {
			os.date("%B-%d-%Y", os.time(date)) .. ":",
		}
		api.nvim_buf_set_lines(0, 0, -1, false, lines)
	end
end

--- Add entry interactively
function M.add_entry_interactive()
	local date = state.current_date
	local date_str = string.format("%04d-%02d-%02d", date.year, date.month, date.day)

	vim.ui.input({
		prompt = string.format("Add entry for %s: ", date_str),
		completion = "customlist,v:lua.require'calendar'.complete_entry",
	}, function(input)
		if input and input ~= "" then
			M.add_entry(date_str, input)
			update_calendar_display()
		end
	end)
end

--- Completion function for entry input
function M.complete_entry(arg_lead, cmd_line, cursor_pos)
	local today = os.date("%Y-%m-%d")
	local tomorrow = os.date("%Y-%m-%d", os.time() + 86400)

	local completions = {
		"[ ] ",
		"[x] ",
		"[!] ",
		"[~] ",
		"[@] ",
		"09:00 ",
		"14:30 ",
		"@at(9am) ",
		"@at(2pm) ",
		"@due(" .. tomorrow .. ")",
		"@from(" .. today .. ")",
		"@to(" .. tomorrow .. ")",
		"@repeat(daily) ",
		"@repeat(weekly) ",
		"@repeat(monthly) ",
		"@p1 ",
		"@p2 ",
		"@p3 ",
		"@home ",
		"@work ",
		"@phone ",
		"@30m ",
		"@1h ",
		"@notify(15m) ",
	}

	local matches = {}
	for _, completion in ipairs(completions) do
		if completion:find("^" .. vim.pesc(arg_lead)) then
			table.insert(matches, completion)
		end
	end

	return matches
end

-- =============================================================================
-- TELESCOPE INTEGRATION
-- =============================================================================

function M.telescope_calendar(opts)
	opts = opts or {}

	-- Load calendar data
	M.load_calendar_data()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local conf = require("telescope.config").values
	local entry_display = require("telescope.pickers.entry_display")

	-- Create entries
	local entries = {}
	local all_dates = {}
	for date_str, _ in pairs(state.parsed_entries) do
		all_dates[date_str] = true
	end

	-- Also consider dates from attributes
	for date_str, parsed_list in pairs(state.parsed_entries) do
		for _, entry in ipairs(parsed_list) do
			if entry.attributes.due then
				all_dates[entry.attributes.due] = true
			end
		end
	end

	for date_str, _ in pairs(all_dates) do
		local active_entries = get_active_entries_for_date(date_str)
		if active_entries and #active_entries > 0 then
			local year, month, day = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
			if year and month and day then
				local date_obj = os.time({
					year = tonumber(year),
					month = tonumber(month),
					day = tonumber(day),
				})
				local formatted_date = os.date("%a, %b %d, %Y", date_obj)

				-- Count by type
				local counts = count_entries_by_type(date_str)
				local raw_text_concat = ""
				for _, e in ipairs(active_entries) do
					raw_text_concat = raw_text_concat .. e.raw_text .. " "
				end

				table.insert(entries, {
					value = date_str,
					display_date = formatted_date,
					ordinal = formatted_date .. " " .. raw_text_concat,
					parsed_entries = active_entries,
					counts = counts,
					date_obj = date_obj,
				})
			end
		end
	end

	-- Sort by date
	table.sort(entries, function(a, b)
		return a.date_obj > b.date_obj
	end)

	pickers
		.new(opts, {
			prompt_title = "Calendar Entries",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					local count_str = ""
					if entry.counts.tasks > 0 then
						count_str = count_str .. "□" .. entry.counts.tasks .. " "
					end
					if entry.counts.events > 0 then
						count_str = count_str .. "●" .. entry.counts.events .. " "
					end
					if entry.counts.notes > 0 then
						count_str = count_str .. "*" .. entry.counts.notes
					end

					return {
						value = entry,
						display = entry.display_date .. " │ " .. count_str,
						ordinal = entry.ordinal,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = require("telescope.previewers").new_buffer_previewer({
				title = "Calendar Entry Preview",
				define_preview = function(self, entry)
					local lines = {
						"Date: " .. entry.value.display_date,
						"",
					}

					-- Group by type
					local events = {}
					local tasks = {}
					local notes = {}

					for _, parsed in ipairs(entry.value.parsed_entries) do
						if parsed.type == "event" then
							table.insert(events, parsed)
						elseif parsed.type == "task" then
							table.insert(tasks, parsed)
						else
							table.insert(notes, parsed)
						end
					end

					if #events > 0 then
						table.insert(lines, "Events:")
						for _, event in ipairs(events) do
							table.insert(lines, "  " .. format_entry_display(event, true))
						end
						table.insert(lines, "")
					end

					if #tasks > 0 then
						table.insert(lines, "Tasks:")
						for _, task in ipairs(tasks) do
							table.insert(lines, "  " .. format_entry_display(task, true))
						end
						table.insert(lines, "")
					end

					if #notes > 0 then
						table.insert(lines, "Notes:")
						for _, note in ipairs(notes) do
							table.insert(lines, "  • " .. note.display_text)
						end
					end

					api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						-- Go to date
						local year, month, day = selection.value.value:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
						state.current_date = {
							year = tonumber(year),
							month = tonumber(month),
							day = tonumber(day),
						}
						M.go_to_date()
					end
				end)
				return true
			end,
		})
		:find()
end

-- =============================================================================
-- QUICK ADD
-- =============================================================================

--- Quick add entry for today
function M.quick_add_today(entry)
	local today = os.date("%Y-%m-%d")
	M.load_calendar_data()
	M.add_entry(today, entry)
	vim.notify("Added to calendar: " .. entry)
end

--- Quick add with date picker
function M.quick_add()
	vim.ui.input({
		prompt = "Date (YYYY-MM-DD) or relative (today/tomorrow/+N): ",
	}, function(date_input)
		if not date_input then
			return
		end

		local date_str
		if date_input == "today" or date_input == "" then
			date_str = os.date("%Y-%m-%d")
		elseif date_input == "tomorrow" then
			date_str = os.date("%Y-%m-%d", os.time() + 86400)
		elseif date_input:match("^%+%d+$") then
			local days = tonumber(date_input:sub(2))
			date_str = os.date("%Y-%m-%d", os.time() + days * 86400)
		else
			-- Validate date format
			local year, month, day = date_input:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
			if not year then
				vim.notify("Invalid date format. Use YYYY-MM-DD", vim.log.levels.ERROR)
				return
			end
			date_str = date_input
		end

		vim.ui.input({
			prompt = string.format("Add entry for %s: ", date_str),
			completion = "customlist,v:lua.require'calendar'.complete_entry",
		}, function(entry)
			if entry and entry ~= "" then
				M.load_calendar_data()
				M.add_entry(date_str, entry)
				vim.notify("Added to calendar: " .. entry)
			end
		end)
	end)
end

-- =============================================================================
-- TASK MANAGEMENT
-- =============================================================================

--- Get all incomplete tasks
function M.get_incomplete_tasks()
	M.load_calendar_data()
	local tasks = {}

	for date_str, parsed_entries in pairs(state.parsed_entries) do
		for _, entry in ipairs(parsed_entries) do
			if entry.type == "task" and entry.task_status == "[ ]" then
				table.insert(tasks, {
					date = date_str,
					entry = entry,
				})
			end
		end
	end

	-- Sort by date
	table.sort(tasks, function(a, b)
		return a.date < b.date
	end)

	return tasks
end

--- Toggle task status
function M.toggle_task_status(date_str, entry_index)
	local entries = state.calendar_data[date_str]
	if not entries or not entries[entry_index] then
		return
	end

	local entry = entries[entry_index]
	local parsed = parse_entry(entry)

	if parsed.task_status == "[ ]" then
		entries[entry_index] = entry:gsub("^%[ %]", "[x]")
	elseif parsed.task_status == "[x]" then
		entries[entry_index] = entry:gsub("^%[x%]", "[ ]")
	end

	M.save_calendar_data()
	M.load_calendar_data()
end

return M
