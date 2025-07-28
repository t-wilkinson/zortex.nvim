-- stores/calendar.lua - Calendar store using entry models
local M = {}

local constants = require("zortex.constants")
local datetime = require("zortex.utils.datetime")
local fs = require("zortex.utils.filesystem")
local CalendarEntry = require("zortex.services.calendar.entry")
local EventBus = require("zortex.core.event_bus")
local DocumentManager = require("zortex.core.document_manager")

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
	local path = fs.get_file_path(constants.FILES.CALENDAR)
	if not path or not fs.file_exists(path) then
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
		local m, d, y = line:match(constants.PATTERNS.CALENDAR_DATE_HEADING)
		if m and d and y then
			current_date_str = datetime.format_date({ year = y, month = m, day = d }, "YYYY-MM-DD")
			state.entries[current_date_str] = {}
		elseif current_date_str then
			local entry_text = line:match(constants.PATTERNS.CALENDAR_ENTRY_PREFIX)
			if entry_text then
				local entry = CalendarEntry.from_text(entry_text, current_date_str)
				table.insert(state.entries[current_date_str], entry)
			end
		end
	end

	state.loaded = true
	return true
end

function M.save()
	local path = fs.get_file_path(constants.FILES.CALENDAR)
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
			table.insert(lines, datetime.format_date(date_tbl, "MM-DD-YYYY") .. ":")

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
		local calendar_file = fs.get_file_path(constants.FILES.CALENDAR)
		if calendar_file then
			local bufnr = vim.fn.bufnr(calendar_file)
			if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
				-- Mark for reload
				DocumentManager.mark_buffer_dirty(bufnr, 1, -1)
			end
		end

		EventBus.emit("calendar:entry_added", {
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
	local entries = M.get_entries_for_date(date_str)

	if not entries or entry_index < 1 or entry_index > #entries then
		return false, "Invalid entry index"
	end

	local removed_entry = entries[entry_index]

	-- Remove from store
	if not state.data.entries[date_str] then
		return false, "No entries for date"
	end

	table.remove(state.data.entries[date_str], entry_index)

	-- Remove date if no entries left
	if #state.data.entries[date_str] == 0 then
		state.data.entries[date_str] = nil
	end

	-- Save
	M.save()

	EventBus.emit("calendar:entry_removed", {
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
	local seen = {} -- Track processed entries by raw_text

	-- Check all entries to see if they're active on this date
	for entry_date_str, entries in pairs(state.entries) do
		for _, entry in ipairs(entries) do
			if not seen[entry.raw_text] and entry:is_active_on_date(date_str) then
				table.insert(active_entries, entry)
				seen[entry.raw_text] = true
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
