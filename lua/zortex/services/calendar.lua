-- services/calendar.lua - Calendar service using DocumentManager and EventBus
local M = {}

local DocumentManager = require("zortex.core.document_manager")
local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local calendar_store = require("zortex.stores.calendar")
local datetime = require("zortex.utils.datetime")
local fs = require("zortex.utils.filesystem")
local constants = require("zortex.constants")
local CalendarEntry = require("zortex.models.calendar_entry")

-- =============================================================================
-- Calendar Document Parsing
-- =============================================================================

-- Parse calendar entries from document
local function parse_calendar_document(doc)
	if not doc or not doc.sections then
		return {}
	end

	local entries_by_date = {}
	local current_date = nil

	-- Process all lines to find date headers and entries
	local lines = vim.api.nvim_buf_get_lines(doc.bufnr or 0, 0, -1, false)
	if #lines == 0 and doc.filepath then
		lines = fs.read_lines(doc.filepath) or {}
	end

	for i, line in ipairs(lines) do
		-- Check for date header
		local m, d, y = line:match(constants.PATTERNS.CALENDAR_DATE_HEADING)
		if m and d and y then
			current_date =
				datetime.format_date({ year = tonumber(y), month = tonumber(m), day = tonumber(d) }, "YYYY-MM-DD")
			entries_by_date[current_date] = entries_by_date[current_date] or {}
		elseif current_date then
			-- Check for entry
			local entry_text = line:match(constants.PATTERNS.CALENDAR_ENTRY_PREFIX)
			if entry_text then
				local entry = CalendarEntry.from_text(entry_text, current_date)
				entry.line_num = i
				table.insert(entries_by_date[current_date], entry)
			end
		end
	end

	return entries_by_date
end

-- =============================================================================
-- Calendar Operations
-- =============================================================================

-- Load calendar data
function M.load()
	local doc = DocumentManager.get_file(constants.FILES.CALENDAR)
	if not doc then
		Logger.error("calendar_service", "Failed to load calendar document")
		return false
	end

	local entries_by_date = parse_calendar_document(doc)

	-- Update store
	calendar_store.set_all_entries(entries_by_date)

	EventBus.emit("calendar:loaded", {
		entry_count = vim.tbl_count(entries_by_date),
		filepath = constants.FILES.CALENDAR,
	})

	return true
end

-- Save calendar data
function M.save()
	local result = calendar_store.save()

	if result then
		EventBus.emit("calendar:saved", {
			timestamp = os.time(),
		})
	end

	return result
end

-- Add calendar entry
function M.add_entry(date_str, entry_text, opts)
	opts = opts or {}

	-- Validate date
	local date = datetime.parse_date(date_str)
	if not date then
		return nil, "Invalid date format"
	end

	-- Create entry
	local entry = CalendarEntry.from_text(entry_text, date_str)

	-- Add to store
	local success = calendar_store.add_entry(date_str, entry_text)

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

-- Remove calendar entry
function M.remove_entry(date_str, entry_index)
	local entries = calendar_store.get_entries_for_date(date_str)

	if not entries or entry_index < 1 or entry_index > #entries then
		return false, "Invalid entry index"
	end

	local removed_entry = entries[entry_index]

	-- Remove from store
	if not calendar_store.data.entries[date_str] then
		return false, "No entries for date"
	end

	table.remove(calendar_store.data.entries[date_str], entry_index)

	-- Remove date if no entries left
	if #calendar_store.data.entries[date_str] == 0 then
		calendar_store.data.entries[date_str] = nil
	end

	-- Save
	calendar_store.save()

	EventBus.emit("calendar:entry_removed", {
		date = date_str,
		entry = removed_entry,
	})

	return true
end

-- Get entries for date range
function M.get_entries_for_range(start_date, end_date)
	local entries = {}

	local current = datetime.parse_date(start_date)
	local end_dt = datetime.parse_date(end_date)

	if not current or not end_dt then
		return entries
	end

	while os.time(current) <= os.time(end_dt) do
		local date_str = datetime.format_date(current, "YYYY-MM-DD")
		local day_entries = calendar_store.get_entries_for_date(date_str)

		if #day_entries > 0 then
			entries[date_str] = day_entries
		end

		-- Next day
		current = datetime.add_days(current, 1)
	end

	return entries
end

-- =============================================================================
-- Calendar Analysis
-- =============================================================================

-- Get calendar statistics
function M.get_stats(opts)
	opts = opts or {}

	local stats = {
		total_entries = 0,
		entries_by_type = {
			task = 0,
			event = 0,
			note = 0,
		},
		entries_by_month = {},
		entries_with_notifications = 0,
		recurring_entries = 0,
		completed_tasks = 0,
		incomplete_tasks = 0,
	}

	-- Ensure loaded
	if not calendar_store.data.entries then
		M.load()
	end

	-- Process all entries
	for date_str, entries in pairs(calendar_store.data.entries) do
		local month_key = date_str:sub(1, 7) -- YYYY-MM
		stats.entries_by_month[month_key] = (stats.entries_by_month[month_key] or 0) + #entries

		for _, entry in ipairs(entries) do
			stats.total_entries = stats.total_entries + 1

			-- Type
			stats.entries_by_type[entry.type] = (stats.entries_by_type[entry.type] or 0) + 1

			-- Notifications
			if entry.attributes.notify then
				stats.entries_with_notifications = stats.entries_with_notifications + 1
			end

			-- Recurring
			if entry.attributes["repeat"] then
				stats.recurring_entries = stats.recurring_entries + 1
			end

			-- Task completion
			if entry.type == "task" then
				if entry.task_status and entry.task_status.key == "[x]" then
					stats.completed_tasks = stats.completed_tasks + 1
				else
					stats.incomplete_tasks = stats.incomplete_tasks + 1
				end
			end
		end
	end

	return stats
end

-- Get upcoming entries
function M.get_upcoming(days_ahead)
	days_ahead = days_ahead or 7

	local today = datetime.get_current_date()
	local end_date = datetime.add_days(today, days_ahead)

	return M.get_entries_for_range(
		datetime.format_date(today, "YYYY-MM-DD"),
		datetime.format_date(end_date, "YYYY-MM-DD")
	)
end

-- =============================================================================
-- Calendar Search
-- =============================================================================

-- Search calendar entries
function M.search(query, opts)
	opts = opts or {}

	local results = {}
	local query_lower = query:lower()

	-- Ensure loaded
	if not calendar_store.data.entries then
		M.load()
	end

	-- Search all entries
	for date_str, entries in pairs(calendar_store.data.entries) do
		for i, entry in ipairs(entries) do
			local text_lower = (entry.display_text or ""):lower()

			if text_lower:find(query_lower, 1, true) then
				table.insert(results, {
					date = date_str,
					entry = entry,
					index = i,
					score = 1, -- Simple scoring for now
				})
			end
		end
	end

	-- Sort by date (most recent first)
	table.sort(results, function(a, b)
		return a.date > b.date
	end)

	return results
end

-- =============================================================================
-- Calendar Integration
-- =============================================================================

-- Check for entries that need notifications
function M.get_pending_notifications(lookahead_minutes)
	lookahead_minutes = lookahead_minutes or 15

	local now = os.time()
	local lookahead = now + (lookahead_minutes * 60)

	local pending = {}

	-- Get today's entries
	local today_str = datetime.format_date(datetime.get_current_date(), "YYYY-MM-DD")
	local entries = calendar_store.get_entries_for_date(today_str)

	for _, entry in ipairs(entries) do
		if entry.attributes.notify and entry.time then
			-- Calculate notification time
			local entry_time = os.time({
				year = datetime.get_current_date().year,
				month = datetime.get_current_date().month,
				day = datetime.get_current_date().day,
				hour = entry.time.hour,
				min = entry.time.min,
				sec = 0,
			})

			-- Check if within window
			if entry_time > now and entry_time <= lookahead then
				table.insert(pending, {
					entry = entry,
					time = entry_time,
					minutes_until = math.floor((entry_time - now) / 60),
				})
			end
		end
	end

	return pending
end

-- =============================================================================
-- Event Handlers
-- =============================================================================

-- Listen for document changes
EventBus.on("document:changed", function(data)
	if data.document and data.document.filepath then
		local calendar_file = fs.get_file_path(constants.FILES.CALENDAR)

		if data.document.filepath == calendar_file then
			-- Reload calendar data
			vim.schedule(function()
				M.load()
			end)
		end
	end
end, {
	priority = 60,
	name = "calendar_service.document_changed",
})

-- =============================================================================
-- Legacy Compatibility
-- =============================================================================

-- Wrap store methods for backward compatibility
M.get_all_entries = function()
	return calendar_store.data.entries or {}
end

M.has_entries = function(date_str)
	local entries = calendar_store.get_entries_for_date(date_str)
	return entries and #entries > 0
end

return M
