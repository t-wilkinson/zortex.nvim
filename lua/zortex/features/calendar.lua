-- features/calendar.lua - Calendar features using CalendarService
local M = {}

local CalendarService = require("zortex.services.calendar_service")
local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local datetime = require("zortex.utils.datetime")
local fs = require("zortex.core.filesystem")
local constants = require("zortex.constants")
local Config = require("zortex.config")

-- =============================================================================
-- Calendar Data Access (Using Service)
-- =============================================================================

-- Load calendar data
function M.load()
	return CalendarService.load()
end

-- Save calendar data
function M.save()
	return CalendarService.save()
end

-- Add calendar entry
function M.add_entry(date_str, entry_text)
	local entry, err = CalendarService.add_entry(date_str, entry_text)

	if entry then
		Logger.info("calendar", "Entry added", { date = date_str })
		return true
	else
		Logger.error("calendar", "Failed to add entry", { date = date_str, error = err })
		return false
	end
end

-- Get entries for date
function M.get_entries_for_date(date_str)
	return CalendarService.get_entries_for_date(date_str)
end

-- =============================================================================
-- Calendar UI Integration
-- =============================================================================

-- Add entry with interactive prompt
function M.add_entry_interactive(date_str)
	date_str = date_str or datetime.format_date(datetime.get_current_date(), "YYYY-MM-DD")

	vim.ui.input({
		prompt = string.format("Add entry for %s: ", date_str),
		default = "",
	}, function(input)
		if input and input ~= "" then
			if M.add_entry(date_str, input) then
				vim.notify(string.format("Added entry for %s", date_str), vim.log.levels.INFO)
			else
				vim.notify("Failed to add entry", vim.log.levels.ERROR)
			end
		end
	end)
end

-- Delete entry with confirmation
function M.delete_entry_interactive(date_str)
	local entries = M.get_entries_for_date(date_str)

	if not entries or #entries == 0 then
		vim.notify("No entries for " .. date_str, vim.log.levels.WARN)
		return
	end

	-- Build selection list
	local items = {}
	for i, entry in ipairs(entries) do
		table.insert(items, string.format("%d. %s", i, entry:format()))
	end

	vim.ui.select(items, {
		prompt = "Select entry to delete:",
	}, function(choice, idx)
		if choice and idx then
			local success, err = CalendarService.remove_entry(date_str, idx)
			if success then
				vim.notify("Entry deleted", vim.log.levels.INFO)
			else
				vim.notify("Failed to delete entry: " .. (err or "unknown error"), vim.log.levels.ERROR)
			end
		end
	end)
end

-- =============================================================================
-- Calendar Search
-- =============================================================================

-- Search calendar entries
function M.search(query)
	local results = CalendarService.search(query)

	if #results == 0 then
		vim.notify("No entries found matching: " .. query, vim.log.levels.INFO)
		return
	end

	-- Format results
	local lines = { string.format("Search Results for '%s':", query), "" }

	for _, result in ipairs(results) do
		table.insert(lines, string.format("%s:", result.date))
		table.insert(lines, "  " .. result.entry:format())
		table.insert(lines, "")
	end

	-- Show in buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_name(buf, "Calendar Search Results")

	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)
end

-- =============================================================================
-- Calendar Statistics
-- =============================================================================

-- Show calendar statistics
function M.show_stats()
	local stats = CalendarService.get_stats()
	local lines = { "Calendar Statistics", "==================", "" }

	-- Overall stats
	table.insert(lines, string.format("Total entries: %d", stats.total_entries))
	table.insert(lines, "")

	-- By type
	table.insert(lines, "By Type:")
	for type_name, count in pairs(stats.entries_by_type) do
		table.insert(lines, string.format("  %s: %d", type_name, count))
	end
	table.insert(lines, "")

	-- Special entries
	table.insert(lines, string.format("With notifications: %d", stats.entries_with_notifications))
	table.insert(lines, string.format("Recurring: %d", stats.recurring_entries))
	table.insert(lines, "")

	-- Task stats
	if stats.entries_by_type.task > 0 then
		table.insert(lines, "Tasks:")
		table.insert(lines, string.format("  Completed: %d", stats.completed_tasks))
		table.insert(lines, string.format("  Incomplete: %d", stats.incomplete_tasks))
		table.insert(lines, "")
	end

	-- By month
	if vim.tbl_count(stats.entries_by_month) > 0 then
		table.insert(lines, "By Month:")
		local months = vim.tbl_keys(stats.entries_by_month)
		table.sort(months)

		for _, month in ipairs(months) do
			table.insert(lines, string.format("  %s: %d", month, stats.entries_by_month[month]))
		end
	end

	-- Show in buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_name(buf, "Calendar Statistics")

	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)
end

-- =============================================================================
-- Calendar Notifications
-- =============================================================================

-- Get pending notifications
function M.get_pending_notifications(lookahead_minutes)
	return CalendarService.get_pending_notifications(lookahead_minutes)
end

-- Check and show notifications
function M.check_notifications()
	local pending = M.get_pending_notifications(15) -- 15 minute lookahead

	if #pending == 0 then
		return
	end

	for _, notif in ipairs(pending) do
		local msg = string.format("Reminder in %d minutes: %s", notif.minutes_until, notif.entry.display_text)

		vim.notify(msg, vim.log.levels.INFO)

		-- Also emit event for notification system
		EventBus.emit("calendar:notification_pending", {
			entry = notif.entry,
			time = notif.time,
			minutes_until = notif.minutes_until,
		})
	end
end

-- =============================================================================
-- Calendar File Operations
-- =============================================================================

-- Open calendar file
function M.open_file()
	local calendar_file = fs.get_file_path(constants.FILES.CALENDAR)
	if calendar_file then
		vim.cmd("edit " .. calendar_file)
		return true
	end
	return false
end

-- Jump to date in calendar file
function M.goto_date(date_str)
	-- Ensure file is open
	if not M.open_file() then
		return false
	end

	-- Format date for search
	local date = datetime.parse_date(date_str)
	if not date then
		return false
	end

	local search_pattern = string.format("%02d-%02d-%04d:", date.month, date.day, date.year)

	-- Search for date
	local found = vim.fn.search(search_pattern, "w")
	if found > 0 then
		vim.cmd("normal! zz")
		return true
	end

	return false
end

-- =============================================================================
-- Event Listeners
-- =============================================================================

-- Listen for calendar changes
EventBus.on("calendar:loaded", function(data)
	Logger.debug("calendar", "Calendar loaded", data)
end, {
	priority = 30,
	name = "calendar_features.loaded",
})

EventBus.on("calendar:entry_added", function(data)
	-- Could trigger UI refresh here
	Logger.debug("calendar", "Entry added", data)
end, {
	priority = 30,
	name = "calendar_features.entry_added",
})

-- =============================================================================
-- Initialization
-- =============================================================================

-- Initialize calendar features
function M.init()
	-- Set up auto-notification checking
	if Config.notifications.enable_calendar ~= false then
		vim.fn.timer_start(60000, function() -- Check every minute
			vim.schedule(function()
				M.check_notifications()
			end)
		end, { ["repeat"] = -1 })
	end

	-- Load calendar on startup
	M.load()

	Logger.info("calendar", "Calendar features initialized")
end

return M
