-- notifications/types/digest.lua - Daily digest email notifications
local M = {}

local manager = require("zortex.notifications.manager")
local calendar_store = require("zortex.stores.calendar")
local datetime = require("zortex.utils.datetime")
local store = require("zortex.stores.notifications")

local config = {}

-- Generate digest content
local function generate_digest(days_ahead)
	days_ahead = days_ahead or 7
	local today = datetime.get_current_date()
	local entries_by_date = {}
	local has_content = false

	-- Collect entries for the specified number of days
	for i = 0, days_ahead - 1 do
		local date = datetime.add_days(today, i)
		local date_str = datetime.format_date(date, "YYYY-MM-DD")
		local entries = calendar_store.get_entries_for_date(date_str)

		if #entries > 0 then
			entries_by_date[date_str] = entries
			has_content = true
		end
	end

	if not has_content then
		return nil
	end

	return entries_by_date
end

-- Format digest content (returns both text and HTML)
local function format_digest_content(entries_by_date)
	local text_parts = {}
	local html_parts = {}

	-- Summary
	local total_tasks = 0
	local total_events = 0
	local notifications_today = 0
	local today_str = datetime.format_date(datetime.get_current_date(), "YYYY-MM-DD")

	for date_str, entries in pairs(entries_by_date) do
		for _, entry in ipairs(entries) do
			if entry.type == "task" and (not entry.task_status or entry.task_status.key ~= "[x]") then
				total_tasks = total_tasks + 1
			elseif entry.type == "event" then
				total_events = total_events + 1
			end

			if entry.attributes.notify and date_str == today_str then
				notifications_today = notifications_today + 1
			end
		end
	end

	-- Text summary
	table.insert(text_parts, "SUMMARY")
	table.insert(text_parts, "-------")
	if total_tasks > 0 then
		table.insert(text_parts, string.format("- %d task%s to complete", total_tasks, total_tasks > 1 and "s" or ""))
	end
	if total_events > 0 then
		table.insert(text_parts, string.format("- %d event%s scheduled", total_events, total_events > 1 and "s" or ""))
	end
	if notifications_today > 0 then
		table.insert(
			text_parts,
			string.format("- %d notification%s today!", notifications_today, notifications_today > 1 and "s" or "")
		)
	end
	table.insert(text_parts, "")

	-- HTML summary
	table.insert(
		html_parts,
		'<div style="background: #e8f4f8; padding: 15px; border-radius: 6px; margin-bottom: 20px;">'
	)
	table.insert(html_parts, '<h3 style="margin: 0 0 10px 0;">Summary</h3>')
	table.insert(html_parts, '<ul style="margin: 0; padding-left: 20px;">')

	if total_tasks > 0 then
		table.insert(
			html_parts,
			string.format("<li>%d task%s to complete</li>", total_tasks, total_tasks > 1 and "s" or "")
		)
	end

	if total_events > 0 then
		table.insert(
			html_parts,
			string.format("<li>%d event%s scheduled</li>", total_events, total_events > 1 and "s" or "")
		)
	end

	if notifications_today > 0 then
		table.insert(
			html_parts,
			string.format(
				"<li><strong>%d notification%s today!</strong></li>",
				notifications_today,
				notifications_today > 1 and "s" or ""
			)
		)
	end

	table.insert(html_parts, "</ul>")
	table.insert(html_parts, "</div>")

	-- Daily breakdown
	local dates = vim.tbl_keys(entries_by_date)
	table.sort(dates)

	for _, date_str in ipairs(dates) do
		local entries = entries_by_date[date_str]
		local date = datetime.parse_date(date_str)
		local date_header = datetime.format_relative_date(date)
		local full_date = os.date("%B %d", os.time(date)) -- Escape % for string.format later

		-- Text version
		table.insert(text_parts, string.format("%s - %s", date_header, full_date))
		table.insert(text_parts, string.rep("-", 40))

		-- HTML version
		if date_header == "Today" then
			date_header = string.format("<strong>%s</strong> - %s", date_header, full_date)
		else
			date_header = string.format("%s - %s", date_header, full_date)
		end

		table.insert(
			html_parts,
			string.format('<div class="day-section"><div class="day-header">%s</div>', date_header)
		)

		-- Sort entries by time and priority
		table.sort(entries, function(a, b)
			return a:get_sort_priority() > b:get_sort_priority()
		end)

		for _, entry in ipairs(entries) do
			local text_prefix = "  • "
			local html_style = ""
			local html_icon = "•"

			if entry.type == "task" then
				if entry.task_status and entry.task_status.key == "[x]" then
					text_prefix = "  ✓ "
					html_style = "color: #95a5a6; text-decoration: line-through;"
					html_icon = "✓"
				else
					text_prefix = "  ☐ "
					html_style = "color: #3498db;"
					html_icon = "☐"
				end
			elseif entry.type == "event" then
				text_prefix = "  📅 "
				html_style = "color: #e74c3c;"
				html_icon = "📅"
			end

			if entry.attributes.notify then
				text_prefix = "  🔔 " .. text_prefix:sub(5)
				html_style = html_style .. " font-weight: bold;"
				html_icon = "🔔 " .. html_icon
			end

			local time_str = entry:get_time_string()
			local text_time = time_str and (time_str .. " ") or ""
			local html_time = time_str
					and string.format(
						'<span class="time" style="color: #7f8c8d; font-weight: 500;">%s</span> ',
						time_str
					)
				or ""

			-- Duration
			local duration_str = ""
			if entry.duration then
				local hours = math.floor(entry.duration / 60)
				local mins = entry.duration % 60
				if hours > 0 then
					duration_str = string.format(" (%dh%dm)", hours, mins > 0 and mins or 0)
				else
					duration_str = string.format(" (%dm)", mins)
				end
			end

			-- Text version
			table.insert(text_parts, text_prefix .. text_time .. entry.display_text .. duration_str)

			-- HTML version
			local html_duration = duration_str ~= ""
					and string.format(' <span style="color: #95a5a6; font-size: 0.9em;">%s</span>', duration_str)
				or ""

			table.insert(
				html_parts,
				string.format(
					'<div class="entry" style="padding: 8px 0; border-bottom: 1px solid #eee; %s">%s %s%s%s</div>',
					html_style,
					html_icon,
					html_time,
					vim.fn.escape(entry.display_text, '<>&"'),
					html_duration
				)
			)
		end

		table.insert(text_parts, "")
		table.insert(html_parts, "</div>")
	end

	return table.concat(text_parts, "\n"), table.concat(html_parts, "\n")
end

-- Send daily digest
function M.send_digest(options)
	return false, "TODO"
	-- options = options or {}

	-- -- Load calendar data
	-- calendar_store.load()

	-- -- Generate digest
	-- local entries_by_date = generate_digest(options.days_ahead or config.days_ahead or 7)

	-- if not entries_by_date then
	-- 	if options.force then
	-- 		manager.send_notification(
	-- 			"Zortex Daily Digest - No Events",
	-- 			"You have no calendar entries for the next " .. (options.days_ahead or 7) .. " days.",
	-- 			{
	-- 				type = "digest",
	-- 				providers = { "ses" },
	-- 			}
	-- 		)
	-- 	end
	-- 	return false, "No calendar entries to include in digest"
	-- end

	-- -- Format content (get both text and HTML versions)
	-- local text_content, html_content = format_digest_content(entries_by_date)

	-- -- Send via SES - pass the raw HTML content, let the provider handle the wrapper
	-- local results = manager.send_notification(
	-- 	"Zortex Daily Digest - " .. os.date("%B %d, %Y"),
	-- 	text_content, -- Plain text version as the message
	-- 	{
	-- 		type = "digest",
	-- 		providers = { "ses" },
	-- 		format = "digest",
	-- 		html = html_content, -- Raw HTML content without wrapper
	-- 		domain = config.domain,
	-- 	}
	-- )

	-- -- Check results
	-- local sent = false
	-- local error_msg = nil
	-- for _, result in ipairs(results) do
	-- 	if result.provider == "ses" then
	-- 		if result.success then
	-- 			sent = true
	-- 			break
	-- 		else
	-- 			error_msg = result.error
	-- 		end
	-- 	end
	-- end

	-- if sent then
	-- 	store.update_digest_state({ last_digest_sent = os.time() })
	-- 	return true, "Daily digest sent successfully"
	-- else
	-- 	return false, "Failed to send daily digest" .. (error_msg and ": " .. error_msg or "")
	-- end
end

-- Check if digest should be sent
local function should_send_digest()
	local digest_state = store.get_digest_state()
	local last_sent = digest_state.last_digest_sent

	if not last_sent then
		return true
	end

	-- Check if it's been at least 20 hours since last digest
	local hours_since = (os.time() - last_sent) / 3600
	if hours_since < 20 then
		return false
	end

	-- Check if it's the right time of day
	local hour = tonumber(os.date("%H"))
	local send_hour = config.send_hour or 7 -- Default 7 AM

	return hour >= send_hour and hour < send_hour + 2
end

-- Schedule automatic digest
function M.schedule_auto_digest()
	if not config.auto_send then
		return
	end

	-- Check periodically if digest should be sent
	local timer = vim.loop.new_timer()
	timer:start(
		0,
		config.check_interval_minutes * 60 * 1000,
		vim.schedule_wrap(function()
			if should_send_digest() then
				M.send_digest({ days_ahead = config.days_ahead })
			end
		end)
	)

	return timer
end

-- Setup
function M.setup(cfg)
	config = cfg or {}

	-- Schedule automatic digest if enabled
	if config.auto_send then
		M.schedule_auto_digest()
	end
end

-- Manual commands
function M.send_now(days)
	return M.send_digest({
		days_ahead = days or config.days_ahead,
		force = true,
	})
end

function M.preview(days)
	local entries_by_date = generate_digest(days or config.days_ahead)

	if not entries_by_date then
		vim.notify("No calendar entries for digest", vim.log.levels.INFO)
		return
	end

	-- Create preview buffer
	local buf = vim.api.nvim_create_buf(false, true)
	local lines = { "Daily Digest Preview", "==================", "" }

	local dates = vim.tbl_keys(entries_by_date)
	table.sort(dates)

	for _, date_str in ipairs(dates) do
		local entries = entries_by_date[date_str]
		local date = datetime.parse_date(date_str)
		local date_header = datetime.format_relative_date(date)

		table.insert(lines, date_header .. " - " .. os.date("%B %d", os.time(date)))
		table.insert(lines, string.rep("-", 40))

		for _, entry in ipairs(entries) do
			local prefix = "  • "
			if entry.type == "task" then
				prefix = entry.task_status and entry.task_status.key == "[x]" and "  ✓ " or "  ☐ "
			elseif entry.type == "event" then
				prefix = "  📅 "
			end

			local time_str = entry:get_time_string()
			if time_str then
				prefix = prefix .. time_str .. " "
			end

			table.insert(lines, prefix .. entry.display_text)
		end

		table.insert(lines, "")
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_name(buf, "Daily Digest Preview")

	-- Open in split
	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)
end

return M
