-- Data management for the Zortex calendar.
-- Handles loading, parsing, saving, and querying calendar entries.

local M = {}

-- =============================================================================
-- Constants
-- =============================================================================

local CALENDAR_FILE = "calendar.zortex"

-- Task status definitions. The parser will attach this information to an entry.
M.TASK_STATUS = {
	["[ ]"] = { symbol = "☐", name = "Incomplete", hl = "Comment" },
	["[x]"] = { symbol = "☑", name = "Complete", hl = "String" },
	["[!]"] = { symbol = "⚠", name = "Important", hl = "ErrorMsg" },
	["[~]"] = { symbol = "◐", name = "In Progress", hl = "WarningMsg" },
	["[@]"] = { symbol = "⏸", name = "Paused", hl = "Comment" },
}

-- =============================================================================
-- State
-- =============================================================================

local state = {
	-- Stores raw text entries, e.g., state.raw_data["2023-01-01"] = {"[ ] Task 1"}
	raw_data = {},
	-- Stores parsed entry objects, e.g., state.parsed_data["2023-01-01"] = { {..parsed_entry..} }
	parsed_data = {},
}

-- =============================================================================
-- Private Helper Functions
-- =============================================================================

--- Deep copy a table to prevent mutation of original data.
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

--- Parse a date string (YYYY-MM-DD) into a table.
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

--- Get the full path to the calendar data file.
local function get_calendar_path()
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir then
		vim.notify("g:zortex_notes_dir not set", vim.log.levels.ERROR)
		return nil
	end
	if not notes_dir:match("/$") then
		notes_dir = notes_dir .. "/"
	end
	return notes_dir .. CALENDAR_FILE
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Parse a single entry line for attributes and task status.
-- This is the core parser that converts a line of text into a structured object.
function M.parse_entry(entry_text)
	local parsed = {
		raw_text = entry_text,
		display_text = entry_text,
		task_status = nil,
		attributes = {},
		type = "note", -- default type
	}

	-- 1. Check for task status
	local status_pattern = "^(%[.%])%s+(.+)$"
	local status_key, remaining_text = entry_text:match(status_pattern)
	if status_key and M.TASK_STATUS[status_key] then
		parsed.task_status = M.TASK_STATUS[status_key]
		parsed.task_status.key = status_key
		parsed.type = "task"
		entry_text = remaining_text -- Continue parsing the rest of the string
	end

	-- 2. Check for time prefix (HH:MM)
	local time_prefix, rest_of_line = entry_text:match("^(%d%d:%d%d)%s+(.+)$")
	if time_prefix then
		parsed.attributes.at = time_prefix
		entry_text = rest_of_line
	end

	-- 3. Parse all other attributes (@due, @repeat, etc.)
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

	for attr_name, pattern in pairs(attribute_patterns) do
		for value in entry_text:gmatch(pattern) do
			if not (attr_name == "at" and parsed.attributes.at) then
				parsed.attributes[attr_name] = value
			end
			entry_text = entry_text:gsub(pattern:gsub("%%", "%%%%"), "")
		end
	end

	-- 4. Determine final entry type based on attributes found
	if parsed.attributes.at then
		parsed.type = "event"
	end

	-- 5. Clean up the remaining text for display
	parsed.display_text = entry_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

	return parsed
end

--- Loads and parses the calendar data from the file.
function M.load()
	local path = get_calendar_path()
	if not path then
		return
	end

	-- Reset state
	state.raw_data = {}
	state.parsed_data = {}

	if vim.fn.filereadable(path) == 0 then
		return -- File doesn't exist, nothing to load
	end

	local current_date = nil
	for line in io.lines(path) do
		local m, d, y = line:match("^(%d%d)%-(%d%d)%-(%d%d%d%d):$")
		if m and d and y then
			current_date = string.format("%04d-%02d-%02d", y, m, d)
			state.raw_data[current_date] = {}
			state.parsed_data[current_date] = {}
		elseif current_date and line:match("^%s+%- ") then
			local entry_text = line:match("^%s+%- (.+)$")
			if entry_text then
				table.insert(state.raw_data[current_date], entry_text)
				table.insert(state.parsed_data[current_date], M.parse_entry(entry_text))
			end
		elseif current_date and line:match("^%s+%d%d:%d%d ") then
			local entry_text = line:match("^%s+(.+)$")
			if entry_text then
				table.insert(state.raw_data[current_date], entry_text)
				table.insert(state.parsed_data[current_date], M.parse_entry(entry_text))
			end
		end
	end
end

--- Saves the current calendar data to the file.
function M.save()
	local path = get_calendar_path()
	if not path then
		return false
	end

	local file = io.open(path, "w")
	if not file then
		vim.notify("Failed to open calendar file for writing", vim.log.levels.ERROR)
		return false
	end

	local dates = {}
	for date in pairs(state.raw_data) do
		table.insert(dates, date)
	end
	table.sort(dates)

	for _, date_str in ipairs(dates) do
		local entries = state.raw_data[date_str]
		if entries and #entries > 0 then
			local y, m, d = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
			file:write(string.format("%s-%s-%s:\n", m, d, y))
			for _, entry in ipairs(entries) do
				file:write("  - " .. entry .. "\n")
			end
			file:write("\n")
		end
	end

	file:close()
	return true
end

--- Adds a new entry and saves the calendar.
function M.add_entry(date_str, entry_text)
	if not state.raw_data[date_str] then
		state.raw_data[date_str] = {}
		state.parsed_data[date_str] = {}
	end
	table.insert(state.raw_data[date_str], entry_text)
	table.insert(state.parsed_data[date_str], M.parse_entry(entry_text))
	M.save()
end

--- Gets all active entries for a given date, including recurring and ranged events.
function M.get_entries_for_date(date_str)
	local target_date_obj = parse_date(date_str)
	if not target_date_obj then
		return {}
	end
	local target_time = os.time(target_date_obj)

	local active_entries = {}
	local added_entries = {} -- Track raw text to avoid duplicates

	-- 1. Add standard entries for the day
	if state.parsed_data[date_str] then
		for _, entry in ipairs(state.parsed_data[date_str]) do
			if not added_entries[entry.raw_text] then
				table.insert(active_entries, entry)
				added_entries[entry.raw_text] = true
			end
		end
	end

	-- 2. Check all other entries for recurring, ranged, or due attributes
	for original_date_str, entries in pairs(state.parsed_data) do
		local original_date_obj = parse_date(original_date_str)
		if original_date_obj then
			local original_time = os.time(original_date_obj)

			for _, entry in ipairs(entries) do
				if not added_entries[entry.raw_text] then
					local is_recurring, is_ranged = false, false

					-- Check for @repeat
					if entry.attributes.repeating and target_time > original_time then
						local repeat_val = entry.attributes.repeating:lower()
						local diff_days = math.floor((target_time - original_time) / 86400)
						if repeat_val == "daily" then
							is_recurring = true
						elseif repeat_val == "weekly" and diff_days > 0 and diff_days % 7 == 0 then
							is_recurring = true
						end
					end

					-- Check for @from/@to range
					if entry.attributes.from or entry.attributes.to then
						local from_time = entry.attributes.from and os.time(parse_date(entry.attributes.from))
							or original_time
						local to_time = entry.attributes.to and os.time(parse_date(entry.attributes.to)) or from_time
						if target_time >= from_time and target_time <= to_time then
							is_ranged = true
						end
					end

					if is_recurring or is_ranged then
						local instance = deepcopy(entry)
						instance.is_recurring_instance = is_recurring
						instance.is_ranged_instance = is_ranged
						table.insert(active_entries, instance)
						added_entries[entry.raw_text] = true
					end
				end

				-- Check for @due date
				if entry.attributes.due and entry.attributes.due == date_str and not added_entries[entry.raw_text] then
					local due_entry = deepcopy(entry)
					due_entry.is_due_date_instance = true
					table.insert(active_entries, due_entry)
					added_entries[entry.raw_text] = true
				end
			end
		end
	end

	return active_entries
end

--- Returns all parsed entries, useful for Telescope.
function M.get_all_parsed_entries()
	return state.parsed_data
end

return M
