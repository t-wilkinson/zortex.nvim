-- stores/calendar.lua - Calendar store using entry models
local M = {}

local Logger = require("zortex.core.logger")
local constants = require("zortex.constants")
local datetime = require("zortex.utils.datetime")
local fs = require("zortex.utils.filesystem")
local CalendarEntry = require("zortex.services.calendar_entry")
local Events = require("zortex.core.event_bus")
local Doc = require("zortex.core.document_manager")
local parser = require("zortex.utils.parser")

-- =============================================================================
-- Store State
-- =============================================================================

local state = {
	entries = {}, -- entries[date_str] = array of CalendarEntry models
	loaded = false,
}

-- =============================================================================
-- Loading and Saving
-- =============================================================================

function M.load()
	local path = fs.get_calendar_file()
	if not path or not fs.file_exists(path) then
		Logger.error("calendar.load", "Could not find file")
		state.loaded = true
		return false
	end

	state.entries = {}
	local lines = fs.read_lines(path)
	if not lines then
		state.loaded = true
		return false
	end

	local current_date_str = nil
	for _, line in ipairs(lines) do
		local y, m, d = line:match(constants.PATTERNS.CALENDAR_DATE_HEADING)
		if y and m and d then
			current_date_str = datetime.format_date({
				year = tonumber(y),
				month = tonumber(m),
				day = tonumber(d),
			}, "YYYY-MM-DD")
			-- Always initialize as empty array, we'll merge duplicates
			if not state.entries[current_date_str] then
				state.entries[current_date_str] = {}
			end
		elseif current_date_str then
			-- Extract the entry text with optional dash prefix
			local entry_text = line:match("^%s*%-?%s*(.+)$")

			if entry_text then
				-- Check for different time formats
				local parsed_text = entry_text

				-- Check for time range format: "10:00 - 12:00 rest of text"
				local from_time, to_time, remaining = entry_text:match("^(%d%d?:%d%d)%s*%-%s*(%d%d?:%d%d)%s+(.*)$")
				if from_time and to_time and remaining then
					parsed_text = remaining
					-- Add the time attributes
					parsed_text = parser.update_attribute(parsed_text, "from", from_time)
					parsed_text = parser.update_attribute(parsed_text, "to", to_time)
				else
					-- Check for single time prefix: "10:00 rest of text"
					local at_time, remaining = entry_text:match("^(%d%d?:%d%d)%s+(.*)$")
					if at_time and remaining then
						parsed_text = remaining
						parsed_text = parser.update_attribute(parsed_text, "at", at_time)
					end
				end

				local entry = CalendarEntry.from_text(parsed_text, current_date_str)
				table.insert(state.entries[current_date_str], entry)
			end
		end
	end

	state.loaded = true
	return true
end

function M.save()
	local path = fs.get_calendar_file()
	if not path then
		return false
	end

	local lines = {}
	local dates = vim.tbl_keys(state.entries)
	table.sort(dates)

	for _, date_str in ipairs(dates) do
		local entries = state.entries[date_str]
		if entries and #entries > 0 then
			local date_tbl = datetime.parse_date(date_str)
			table.insert(lines, datetime.format_date(date_tbl, "YYYY-MM-DD") .. ":")

			-- Sort entries by priority
			table.sort(entries, function(a, b)
				return a:get_sort_priority() > b:get_sort_priority()
			end)

			for _, entry in ipairs(entries) do
				table.insert(lines, "  - " .. entry.raw_text)
			end
			table.insert(lines, "")
		end
	end

	return fs.write_lines(path, lines)
end

function M.ensure_loaded()
	if not state.loaded then
		M.load()
	end
end

-- =============================================================================
-- Single Entry Management
-- =============================================================================

-- Add calendar entry
function M.add_entry(date_str, entry_text)
	M.ensure_loaded()

	-- Validate date
	local date = datetime.parse_date(date_str)
	if not date then
		return nil, "Invalid date format"
	end

	-- Create entry
	if not state.entries[date_str] then
		state.entries[date_str] = {}
	end

	local entry = CalendarEntry.from_text(entry_text, date_str)
	table.insert(state.entries[date_str], entry)

	local success = M.save()

	if success then
		-- Update document if it's open
		local calendar_file = fs.get_calendar_file()
		if calendar_file then
			local bufnr = vim.fn.bufnr(calendar_file)
			if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
				-- Mark for reload
				Doc.mark_buffer_dirty(bufnr, 1, -1)
			end
		end

		Events.emit("calendar:entry_added", {
			date = date_str,
			entry = entry,
		})

		return entry
	else
		return nil, "Failed to add entry"
	end
end

-- Delete an entry
function M.delete_entry_by_text(date_str, entry_text)
	M.ensure_loaded()

	local entries = state.entries[date_str]
	if not entries then
		return false
	end

	for i, entry in ipairs(entries) do
		if entry.raw_text == entry_text then
			table.remove(entries, i)
			return M.save()
		end
	end

	return false
end

function M.delete_entry_by_index(date_str, entry_index)
	M.ensure_loaded()

	local entries = state.entries[date_str]
	if not entries or entry_index < 1 or entry_index > #entries then
		return false, "Invalid entry index"
	end

	local removed_entry = entries[entry_index]
	table.remove(entries, entry_index)

	-- Remove date if no entries left
	if #entries == 0 then
		state.entries[date_str] = nil
	end

	-- Save
	M.save()

	Events.emit("calendar:entry_removed", {
		date = date_str,
		entry = removed_entry,
	})

	return true
end

-- Update an entry
function M.update_entry(date_str, old_text, new_text)
	M.ensure_loaded()

	local entries = state.entries[date_str]
	if not entries then
		return false
	end

	for i, entry in ipairs(entries) do
		if entry.raw_text == old_text then
			entries[i] = CalendarEntry.from_text(new_text, date_str)
			return M.save()
		end
	end

	return false
end

-- =============================================================================
-- Entries Management
-- =============================================================================

function M.get_entries_for_date(date_str)
	M.ensure_loaded()

	local active_entries = {}
	local seen = {} -- Track processed entries by a unique key

	-- Check all entries to see if they're active on this date
	for entry_date_str, entries in pairs(state.entries) do
		for _, entry in ipairs(entries) do
			-- Create a unique key for this entry
			local entry_key = entry_date_str .. ":" .. entry.raw_text

			if not seen[entry_key] and entry:is_active_on_date(date_str) then
				table.insert(active_entries, entry)
				seen[entry_key] = true
			end
		end
	end

	-- Sort by priority
	table.sort(active_entries, function(a, b)
		return a:get_sort_priority() > b:get_sort_priority()
	end)

	return active_entries
end

function M.get_entries_in_range(start_date, end_date)
	M.ensure_loaded()

	local entries_by_date = {}
	local current = datetime.parse_date(start_date)
	local end_time = os.time(datetime.parse_date(end_date))

	while os.time(current) <= end_time do
		local date_str = datetime.format_date(current, "YYYY-MM-DD")
		local entries = M.get_entries_for_date(date_str)
		if #entries > 0 then
			entries_by_date[date_str] = entries
		end
		current = datetime.add_days(current, 1)
	end

	return entries_by_date
end

-- Get all entries (for search/telescope)
function M.get_all_entries()
	M.ensure_loaded()

	local all_entries = {}
	for date_str, entries in pairs(state.entries) do
		for _, entry in ipairs(entries) do
			table.insert(all_entries, {
				date = date_str,
				entry = entry,
			})
		end
	end

	return all_entries
end

function M.set_all_entries(entries)
	state.entries = entries
	M.save()
end

return M
