-- modules/calendar.lua - Calendar functionality for Zortex
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")

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
		working_text = working_text:sub(#status_key + 2) -- +2 to account for space
	end

	-- 2. Check for time prefix or range
	local from_time, to_time, rest_of_line = working_text:match("^(%d%d?:%d%d)%-(%d%d?:%d%d)%s+(.+)$")
	if from_time and to_time then
		parsed.attributes.from, parsed.attributes.to, parsed.attributes.at = from_time, to_time, from_time
		parsed.type = "event"
		working_text = rest_of_line
	else
		local time_prefix, rest_of_line_2 = working_text:match("^(%d%d?:%d%d)%s+(.+)$")
		if time_prefix then
			parsed.attributes.at = time_prefix
			parsed.type = "event"
			working_text = rest_of_line_2
		end
	end

	-- 3. Parse attributes using unified parser
	-- The order is important: more specific patterns must come before generic ones.
	local attr_definitions = {
		-- Time/date attributes with parentheses are most specific
		{ name = "at", pattern = "@at%(([^)]+)%)" },
		{ name = "due", pattern = "@due%(([^)]+)%)" },
		{ name = "from", pattern = "@from%(([^)]+)%)" },
		{ name = "to", pattern = "@to%(([^)]+)%)" },
		{ name = "repeating", pattern = "@repeat%(([^)]+)%)" },
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
		-- Other specific attributes
		{ name = "duration", pattern = "@(%d+%.?%d*[hmd])", transform = parser.parse_duration },
		{
			name = "priority",
			pattern = "@p([123])",
			transform = function(p)
				return "p" .. p
			end,
		},
		-- Generic context pattern should be last as it's a fallback
		{ name = "context", pattern = "@(%w+)" },
	}

	local attrs, remaining = parser.parse_attributes(working_text, attr_definitions)
	parsed.attributes = vim.tbl_extend("force", parsed.attributes, attrs)

	-- Check for notification flags without parentheses (legacy)
	if remaining:match("@n") or remaining:match("@notify") or remaining:match("@event") then
		parsed.attributes.notification_enabled = true
		parsed.type = "event"
		remaining = remaining:gsub("@n", ""):gsub("@notify", ""):gsub("@event", "")
	end

	parsed.display_text = parser.trim(remaining)

	return parsed
end

-- =============================================================================
-- The rest of the modules-calendar.lua file is unchanged...
-- =============================================================================

function M.load()
	local path = fs.get_file_path("calendar.zortex")
	if not path or not fs.file_exists(path) then
		return false
	end
	state.entries = {}
	local lines = fs.read_lines(path)
	if not lines then
		return false
	end
	local current_date = nil
	for _, line in ipairs(lines) do
		local m, d, y = line:match("^(%d%d)%-(%d%d)%-(%d%d%d%d):$")
		if m and d and y then
			current_date = string.format("%04d-%02d-%02d", y, m, d)
			state.entries[current_date] = {}
		elseif current_date and (line:match("^%s+%- ") or line:match("^%s+%d%d?:%d%d ")) then
			local entry_text = line:match("^%s+%-? (.+)$") or line:match("^%s+(.+)$")
			if entry_text then
				table.insert(state.entries[current_date], parse_calendar_entry(entry_text, current_date))
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
	local dates = {}
	for date in pairs(state.entries) do
		table.insert(dates, date)
	end
	table.sort(dates)
	for _, date_str in ipairs(dates) do
		local entries = state.entries[date_str]
		if entries and #entries > 0 then
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

function M.add_entry(date_str, entry_text)
	if not state.entries[date_str] then
		state.entries[date_str] = {}
	end
	table.insert(state.entries[date_str], parse_calendar_entry(entry_text, date_str))
	return M.save()
end

function M.get_entries_for_date(date_str)
	local target_date = parser.parse_date(date_str)
	if not target_date then
		return {}
	end
	local target_time = os.time(target_date)
	local active_entries = {}
	local seen = {}
	if state.entries[date_str] then
		for _, entry in ipairs(state.entries[date_str]) do
			table.insert(active_entries, entry)
			seen[entry.raw_text] = true
		end
	end
	-- This can be expanded to include recurring entries
	return active_entries
end

return M
