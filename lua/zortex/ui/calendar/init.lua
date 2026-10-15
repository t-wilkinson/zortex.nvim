-- ui/calendar/init.lua - Calendar commands (entry editing, search, stats, reminders)
-- built on stores/calendar and the CalendarEntry model.
local M = {}

local Config = require("zortex.config")
local datetime = require("zortex.utils.datetime")
local calendar_store = require("zortex.stores.calendar")

-- =============================================================================
-- Store access
-- =============================================================================

function M.load()
	return calendar_store.load()
end

function M.add_entry(date_str, text)
	return calendar_store.add_entry(date_str, text)
end

-- Entries whose text contains `query` (case-insensitive), sorted by date
local function search_entries(query)
	local needle = query:lower()
	local results = {}
	for _, item in ipairs(calendar_store.get_all_entries()) do
		if (item.entry.raw_text or ""):lower():find(needle, 1, true) then
			results[#results + 1] = item
		end
	end
	table.sort(results, function(a, b)
		return a.date < b.date
	end)
	return results
end

local function calendar_stats()
	local stats = {
		total_entries = 0,
		entries_by_type = {},
		entries_with_notifications = 0,
		recurring_entries = 0,
		completed_tasks = 0,
		incomplete_tasks = 0,
		entries_by_month = {},
	}
	for _, item in ipairs(calendar_store.get_all_entries()) do
		local entry = item.entry
		stats.total_entries = stats.total_entries + 1
		stats.entries_by_type[entry.type] = (stats.entries_by_type[entry.type] or 0) + 1
		local notify = entry.attributes.notify
		if notify and notify ~= "no" then
			stats.entries_with_notifications = stats.entries_with_notifications + 1
		end
		if entry.attributes["repeat"] then
			stats.recurring_entries = stats.recurring_entries + 1
		end
		if entry.type == "task" then
			if entry.completed then
				stats.completed_tasks = stats.completed_tasks + 1
			else
				stats.incomplete_tasks = stats.incomplete_tasks + 1
			end
		end
		local month = item.date:sub(1, 7)
		stats.entries_by_month[month] = (stats.entries_by_month[month] or 0) + 1
	end
	return stats
end

-- Today's timed entries starting within the next `lookahead_minutes`
local function pending_notifications(lookahead_minutes)
	local now = os.date("*t")
	local now_minutes = now.hour * 60 + now.min
	local today = os.date("%Y-%m-%d")
	local pending = {}
	for _, entry in ipairs(calendar_store.get_entries_for_date(today)) do
		local start = entry:get_start_time()
		if start and start.hour then
			local minutes_until = start.hour * 60 + (start.min or 0) - now_minutes
			if minutes_until > 0 and minutes_until <= lookahead_minutes then
				pending[#pending + 1] = { entry = entry, time = start, minutes_until = minutes_until }
			end
		end
	end
	return pending
end

-- =============================================================================
-- Calendar Search
-- =============================================================================

-- Search calendar entries
function M.search(query)
	local results = search_entries(query)

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
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.api.nvim_buf_set_name(buf, "Calendar Search Results")

	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)
end

-- =============================================================================
-- Calendar Statistics
-- =============================================================================

-- Show calendar statistics
function M.show_stats()
	local stats = calendar_stats()
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
	if (stats.entries_by_type.task or 0) > 0 then
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
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.api.nvim_buf_set_name(buf, "Calendar Statistics")

	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)
end

-- =============================================================================
-- Calendar Notifications
-- =============================================================================

-- Get pending notifications
function M.get_pending_notifications(lookahead_minutes)
	return pending_notifications(lookahead_minutes or 15)
end

-- Check and show notifications
function M.check_notifications()
	local pending = M.get_pending_notifications(15) -- 15 minute lookahead

	if #pending == 0 then
		return
	end

	for _, notif in ipairs(pending) do
		local msg = string.format("Reminder in %d minutes: %s", notif.minutes_until, notif.entry.text)

		vim.notify(msg, vim.log.levels.INFO)

	end
end

-- =============================================================================
-- Initialization
-- =============================================================================

-- Initialize calendar features
function M.init()
	-- Set up auto-notification checking
	if Config.notifications.enable.calendar ~= false then
		vim.fn.timer_start(60000, function() -- Check every minute
			vim.schedule(function()
				M.check_notifications()
			end)
		end, { ["repeat"] = -1 })
	end

	-- Load calendar on startup
	M.load()
end

return M
