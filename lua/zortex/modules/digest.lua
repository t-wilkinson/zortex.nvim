-- modules/digest.lua - Today's digest and summary functionality
local M = {}

local datetime = require("zortex.core.datetime")
local calendar = require("zortex.modules.calendar")
local projects = require("zortex.modules.projects")
local fs = require("zortex.core.filesystem")

-- =============================================================================
-- Configuration
-- =============================================================================

local config = {
	upcoming_days = 7, -- Show events for next 7 days
	include_high_priority = true, -- Include high priority projects
	include_overdue = true, -- Include overdue tasks
	time_format = "%I:%M %p", -- 12-hour format
}

-- =============================================================================
-- Helper Functions
-- =============================================================================

local function format_time(time_str)
	-- Convert 24-hour format to 12-hour format if needed
	if time_str and time_str:match("^%d+:%d+$") then
		local hour, min = time_str:match("^(%d+):(%d+)$")
		hour = tonumber(hour)
		min = tonumber(min)

		if hour == 0 then
			return string.format("12:%02d AM", min)
		elseif hour < 12 then
			return string.format("%d:%02d AM", hour, min)
		elseif hour == 12 then
			return string.format("12:%02d PM", min)
		else
			return string.format("%d:%02d PM", hour - 12, min)
		end
	end
	return time_str
end

local function get_entry_priority(entry)
	-- Calculate priority score for sorting
	local score = 0

	-- Time-based priority
	if entry.attributes.at then
		local hour, min = entry.attributes.at:match("^(%d+):(%d+)")
		if hour and min then
			score = score + (24 - tonumber(hour)) * 100 + (60 - tonumber(min))
		end
	end

	-- Priority/importance
	if entry.attributes.p == "1" then
		score = score + 1000
	end
	if entry.attributes.p == "2" then
		score = score + 500
	end
	if entry.attributes.i == "1" then
		score = score + 800
	end
	if entry.attributes.i == "2" then
		score = score + 400
	end

	-- Type priority
	if entry.type == "event" then
		score = score + 300
	end
	if entry.type == "task" and not entry.task_status then
		score = score + 200
	end
	if entry.attributes.notify then
		score = score + 600
	end

	return score
end

-- =============================================================================
-- Digest Generation
-- =============================================================================

function M.get_today_digest()
	local today = datetime.get_current_date()
	local digest = {
		date = today,
		entries = {},
		upcoming = {},
		high_priority_projects = {},
		overdue_tasks = {},
		notifications = {},
		stats = {
			total_tasks = 0,
			completed_tasks = 0,
			total_events = 0,
			total_notifications = 0,
		},
	}

	-- Load calendar data
	calendar.load()

	-- Get today's entries
	local today_str = datetime.format_date(today, "YYYY-MM-DD")
	digest.entries = calendar.get_entries_for_date(today_str)

	-- Sort today's entries by priority
	table.sort(digest.entries, function(a, b)
		return get_entry_priority(a) > get_entry_priority(b)
	end)

	-- Get upcoming entries
	for i = 1, config.upcoming_days do
		local date = datetime.add_days(today, i)
		local date_str = datetime.format_date(date, "YYYY-MM-DD")
		local entries = calendar.get_entries_for_date(date_str)

		if #entries > 0 then
			table.insert(digest.upcoming, {
				date = date,
				date_str = date_str,
				entries = entries,
				relative_day = i,
			})
		end
	end

	-- Get high priority projects
	if config.include_high_priority then
		projects.load()
		local all_projects = projects.get_all_projects()

		for _, project in ipairs(all_projects) do
			if project.attributes.p == "1" or project.attributes.i == "1" then
				table.insert(digest.high_priority_projects, project)
			end
		end

		-- Sort by priority
		table.sort(digest.high_priority_projects, function(a, b)
			local a_score = (a.attributes.p == "1" and 2 or 0) + (a.attributes.i == "1" and 1 or 0)
			local b_score = (b.attributes.p == "1" and 2 or 0) + (b.attributes.i == "1" and 1 or 0)
			return a_score > b_score
		end)
	end

	-- Calculate statistics
	for _, entry in ipairs(digest.entries) do
		if entry.type == "task" then
			digest.stats.total_tasks = digest.stats.total_tasks + 1
			if entry.task_status and entry.task_status.key == "[x]" then
				digest.stats.completed_tasks = digest.stats.completed_tasks + 1
			end
		elseif entry.type == "event" then
			digest.stats.total_events = digest.stats.total_events + 1
		end

		if entry.attributes.notify then
			digest.stats.total_notifications = digest.stats.total_notifications + 1
		end
	end

	return digest
end

-- =============================================================================
-- Digest Formatting
-- =============================================================================

function M.format_digest_text(digest)
	local lines = {}

	-- Header
	table.insert(lines, string.format("=== Today's Digest - %s ===", os.date("%A, %B %d, %Y", os.time(digest.date))))
	table.insert(lines, "")

	-- Summary
	if digest.stats.total_tasks > 0 or digest.stats.total_events > 0 then
		local summary_parts = {}
		if digest.stats.total_tasks > 0 then
			table.insert(
				summary_parts,
				string.format("%d tasks (%d completed)", digest.stats.total_tasks, digest.stats.completed_tasks)
			)
		end
		if digest.stats.total_events > 0 then
			table.insert(summary_parts, string.format("%d events", digest.stats.total_events))
		end
		if digest.stats.total_notifications > 0 then
			table.insert(summary_parts, string.format("%d notifications", digest.stats.total_notifications))
		end
		table.insert(lines, "Summary: " .. table.concat(summary_parts, ", "))
		table.insert(lines, "")
	end

	-- Today's entries
	if #digest.entries > 0 then
		table.insert(lines, "Today:")
		for _, entry in ipairs(digest.entries) do
			local prefix = "  • "
			if entry.type == "task" then
				if entry.task_status and entry.task_status.key == "[x]" then
					prefix = "  ✓ "
				else
					prefix = "  □ "
				end
			elseif entry.type == "event" then
				prefix = "  ◆ "
			end

			local time_str = ""
			if entry.attributes.at then
				time_str = " @ " .. format_time(entry.attributes.at)
			end

			local priority_str = ""
			if entry.attributes.p == "1" then
				priority_str = " [P1]"
			end
			if entry.attributes.i == "1" then
				priority_str = priority_str .. " [I1]"
			end

			table.insert(lines, prefix .. entry.display_text .. time_str .. priority_str)
		end
		table.insert(lines, "")
	else
		table.insert(lines, "No items scheduled for today.")
		table.insert(lines, "")
	end

	-- Upcoming events
	if #digest.upcoming > 0 then
		table.insert(lines, "Upcoming this week:")
		for _, day_data in ipairs(digest.upcoming) do
			local day_name = os.date("%A", os.time(day_data.date))
			if day_data.relative_day == 1 then
				day_name = "Tomorrow"
			end

			table.insert(lines, string.format("  %s (%s):", day_name, os.date("%b %d", os.time(day_data.date))))

			for _, entry in ipairs(day_data.entries) do
				local time_str = ""
				if entry.attributes.at then
					time_str = " @ " .. format_time(entry.attributes.at)
				end
				table.insert(lines, "    • " .. entry.display_text .. time_str)
			end
		end
		table.insert(lines, "")
	end

	-- High priority projects
	if #digest.high_priority_projects > 0 then
		table.insert(lines, "High Priority Projects:")
		for _, project in ipairs(digest.high_priority_projects) do
			local priority_str = ""
			if project.attributes.p == "1" then
				priority_str = " [P1]"
			end
			if project.attributes.i == "1" then
				priority_str = priority_str .. " [I1]"
			end

			local clean_name = project.name:gsub("@%w+%b()", ""):gsub("@%w+", ""):gsub("^%s*(.-)%s*$", "%1")
			table.insert(lines, "  • " .. clean_name .. priority_str)
		end
	end

	return lines
end

-- =============================================================================
-- Digest Display
-- =============================================================================

function M.show_digest_notification()
	local digest = M.get_today_digest()
	local lines = M.format_digest_text(digest)

	-- Create a simple notification
	local message = ""
	if digest.stats.total_tasks > 0 or digest.stats.total_events > 0 then
		local parts = {}
		if digest.stats.total_tasks > 0 then
			table.insert(parts, string.format("%d tasks", digest.stats.total_tasks))
		end
		if digest.stats.total_events > 0 then
			table.insert(parts, string.format("%d events", digest.stats.total_events))
		end
		message = "Today: " .. table.concat(parts, ", ")
	else
		message = "No items scheduled for today"
	end

	vim.notify(message, vim.log.levels.INFO, { title = "Zortex Daily Digest" })
end

function M.save_digest_to_file()
	local digest = M.get_today_digest()
	local lines = M.format_digest_text(digest)

	local digest_dir = fs.get_file_path(".z/digests")
	fs.ensure_directory(digest_dir)

	local filename = string.format("%s/digest_%s.txt", digest_dir, os.date("%Y-%m-%d", os.time(digest.date)))

	fs.write_lines(filename, lines)
	return filename
end

-- =============================================================================
-- Public API
-- =============================================================================

function M.setup(opts)
	if opts then
		config = vim.tbl_deep_extend("force", config, opts)
	end
end

function M.get_config()
	return config
end

return M
