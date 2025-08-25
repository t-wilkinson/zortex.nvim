-- ui/calendar/view.lua - Calendar UI module for Zortex
local M = {}
local api = vim.api
local fn = vim.fn

local CELL_WIDTH = 7
local MARGIN_STR = "  "
local GRID_WIDTH = 7 * CELL_WIDTH -- 7 days * 7 cols = 49
local CONTENT_WIDTH = fn.strwidth(MARGIN_STR) + GRID_WIDTH -- 2 + 49 = 51

local constants = require("zortex.constants")
local datetime = require("zortex.utils.datetime")
local calendar_store = require("zortex.stores.calendar")
local fs = require("zortex.utils.filesystem")
local notifications = require("zortex.notifications")

-- =============================================================================
-- Calendar State and cfguration
-- =============================================================================

local CalendarState = {
	bufnr = nil,
	win_id = nil,
	current_date = nil,
	view_mode = "month", -- month, week, day, digest
	marks = {}, -- Date marks for navigation
	ns_id = nil, -- Namespace for extmarks
	selected_extmark_id = nil, -- Current selection extmark
}

-- Default configuration
local cfg = {}

-- =============================================================================
-- Calendar Renderer
-- =============================================================================

local Renderer = {}

function Renderer.create_buffer()
	local bufnr = api.nvim_create_buf(false, true)
	api.nvim_buf_set_option(bufnr, "modifiable", false)
	api.nvim_buf_set_option(bufnr, "buftype", "nofile")
	api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
	api.nvim_buf_set_option(bufnr, "swapfile", false)
	api.nvim_buf_set_name(bufnr, "Zortex Calendar")
	return bufnr
end

function Renderer.create_window(bufnr)
	-- Calculate window dimensions
	local width = cfg.window.width
	if width <= 1 then
		width = math.floor(vim.o.columns * width)
	end
	local height = math.floor(vim.o.lines * cfg.window.height)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Create window
	local win_id = api.nvim_open_win(bufnr, true, {
		relative = cfg.window.relative,
		width = width,
		height = height,
		row = row,
		col = col,
		border = cfg.window.border,
		title = cfg.window.title,
		title_pos = cfg.window.title_pos,
		style = "minimal",
	})

	-- Set window options
	api.nvim_win_set_option(win_id, "number", false)
	api.nvim_win_set_option(win_id, "relativenumber", false)
	api.nvim_win_set_option(win_id, "signcolumn", "no")
	api.nvim_win_set_option(win_id, "wrap", false)
	api.nvim_win_set_option(win_id, "cursorline", false)
	api.nvim_win_set_option(win_id, "winhl", "Normal:Normal,FloatBorder:" .. cfg.colors.border)

	-- Hide cursor
	api.nvim_win_set_option(win_id, "guicursor", "a:block-Cursor/lCursor-blinkon0")

	return win_id
end

function Renderer.center(win_width, text)
	local win_margin = win_width - CONTENT_WIDTH

	local content_padding = math.floor((CONTENT_WIDTH - fn.strwidth(text) + win_margin) / 2)
	local left_padding = string.rep(" ", math.max(1, content_padding))
	local line = left_padding .. text

	return {
		line = line,
		col = content_padding,
		end_col = 2 * content_padding + fn.strwidth(text),
	}
end

function Renderer.render_month_view(date)
	local win_width = CalendarState.win_id and api.nvim_win_get_width(CalendarState.win_id) or cfg.window.width
	local lines = {}
	local highlights = {}
	local today = datetime.get_current_date()

	table.insert(lines, "")

	-- Calculate centering
	local total_padding = win_width - CONTENT_WIDTH
	local left_pad_str = string.rep(" ", math.max(0, math.floor(total_padding / 2)))

	-- Header with navigation hints
	local header_text = datetime.format_month_year(date)
	local view_mode_text = CalendarState.view_mode == "month" and "Month View" or "Week View"
	local space_between = CONTENT_WIDTH - (fn.strwidth(header_text) + fn.strwidth(view_mode_text))
	local header_padding = string.rep(" ", math.max(1, space_between))
	local header_line = left_pad_str .. header_text .. header_padding .. view_mode_text

	table.insert(lines, header_line)
	table.insert(highlights, {
		line = 2,
		col = fn.strwidth(left_pad_str),
		end_col = fn.strwidth(header_line),
		hl = cfg.colors.header,
	})

	table.insert(lines, "")

	-- ── Navigation help (top) ────────────────────────────────────────────────
	local nav_hint = "←/→/↑/↓ move • H/L year • J/K • g today • q quit"
	local nav_center = Renderer.center(win_width, nav_hint)

	table.insert(lines, nav_center.line)
	table.insert(highlights, {
		line = #lines,
		col = nav_center.col,
		end_col = nav_center.end_col,
		hl = cfg.colors.footer,
	})

	-- Separator
	-- table.insert(lines, left_pad_str .. MARGIN_STR .. string.rep("─", GRID_WIDTH))
	table.insert(lines, "")
	table.insert(lines, string.rep("─", win_width))
	table.insert(lines, "")

	-- Day headers
	local day_header_parts = {}
	for _, name in ipairs({ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }) do
		table.insert(day_header_parts, "  " .. name .. "  ")
	end

	table.insert(lines, left_pad_str .. MARGIN_STR .. table.concat(day_header_parts, ""))
	table.insert(lines, "")

	-- Build calendar grid
	local days_in_month = datetime.get_days_in_month(date.year, date.month)
	local first_weekday = datetime.get_first_weekday(date.year, date.month)
	local current_day = 1
	local line_num = #lines + 1

	-- Clear marks for rebuilding
	CalendarState.marks = {}

	for week = 1, 6 do
		if current_day > days_in_month then
			break
		end

		local shift_hl = 0 -- Variable for tracking how much the text has shifted by icon unusual icon widths
		local week_line_parts = { left_pad_str, MARGIN_STR }

		for weekday = 1, 7 do
			local day_cell_str

			if (week == 1 and weekday >= first_weekday) or (week > 1 and current_day <= days_in_month) then
				local day_num = current_day
				local date_str = string.format("%04d-%02d-%02d", date.year, date.month, day_num)
				local entries = calendar_store.get_entries_for_date(date_str)
				local is_today = date.year == today.year and date.month == today.month and day_num == today.day
				local is_selected = CalendarState.current_date
					and date.year == CalendarState.current_date.year
					and date.month == CalendarState.current_date.month
					and day_num == CalendarState.current_date.day

				-- Determine icon
				local hl_group = nil
				local hl_group_icon = nil
				local day_icon = cfg.icons.none

				if #entries > 0 then
					day_icon = cfg.icons.has_items

					-- Prioritize icons
					local has_notification = false
					local has_incomplete_task = false
					local has_complete_task = false
					local has_event = false

					for _, entry in ipairs(entries) do
						if entry.attributes.notify then
							has_notification = true
						end
						if entry.type == "task" then
							if entry.task.completed then
								has_complete_task = true
							else
								has_incomplete_task = true
							end
						elseif entry.type == "event" then
							has_event = true
						end
					end

					-- Set icon by priority
					if has_notification then
						day_icon = cfg.icons.notification
					elseif has_event then
						day_icon = cfg.icons.event
					elseif has_incomplete_task then
						day_icon = cfg.icons.task
					elseif has_complete_task then
						day_icon = cfg.icons.task_done
					end
				end

				-- Format day number with brackets if selected
				-- local day_num_str = is_selected and string.format("[%02d]", day_num) or string.format(" %2d ", day_num)
				local day_num_str = is_selected and string.format("%02d", day_num) or string.format(" %2d ", day_num)
				local cell_content = day_icon .. day_num_str
				local content_w = fn.strwidth(cell_content)
				local padding_w = CELL_WIDTH - content_w
				local lpad = string.rep(" ", math.max(0, math.floor(padding_w / 2)))
				local rpad = string.rep(" ", math.max(0, math.ceil(padding_w / 2)))
				day_cell_str = lpad .. cell_content .. rpad

				-- Calculate position
				local base_col_0based = fn.strwidth(left_pad_str) + fn.strwidth(MARGIN_STR) + (weekday - 1) * CELL_WIDTH

				-- Add highlight for whole cell (but not for selected - we'll use extmark)
				if is_today and not is_selected then
					hl_group = cfg.colors.today
				elseif weekday == 1 or weekday == 7 then
					hl_group = cfg.colors.weekend
				end

				-- Highlight icon if entries exist
				-- Icons
				if #entries > 0 and not is_today then
					local icon_col_start = base_col_0based + fn.strwidth(lpad)
					table.insert(highlights, {
						line = line_num,
						col = icon_col_start + shift_hl,
						end_col = icon_col_start + fn.strwidth(day_icon) + shift_hl,
						hl = is_selected and cfg.colors.selected_icon or cfg.colors.has_entry,
					})
				end

				-- Shift highlighting by new icon
				if day_icon ~= cfg.icons.none then
					shift_hl = shift_hl + cfg.icon_width
				end

				-- Date highlights
				if hl_group then
					table.insert(highlights, {
						line = line_num,
						col = base_col_0based + shift_hl,
						end_col = base_col_0based + CELL_WIDTH + shift_hl,
						hl = hl_group,
					})
				end

				-- Store position for navigation and extmark
				CalendarState.marks[date_str] = {
					line = line_num,
					col = base_col_0based,
					day = day_num,
					end_col = base_col_0based + CELL_WIDTH,
				}

				current_day = current_day + 1
			else
				day_cell_str = string.rep(" ", CELL_WIDTH)
			end
			table.insert(week_line_parts, day_cell_str)
		end

		table.insert(lines, table.concat(week_line_parts, ""))
		line_num = line_num + 1
	end

	-- Add summary section
	table.insert(lines, "")
	table.insert(lines, left_pad_str .. MARGIN_STR .. string.rep("─", GRID_WIDTH))
	table.insert(lines, "")

	-- Show entries for selected date
	if CalendarState.current_date then
		local date_str = datetime.format_datetime(CalendarState.current_date, "YYYY-MM-DD")
		local entries = calendar_store.get_entries_for_date(date_str)
		local pending_notifications = notifications.calendar.get_pending_for_date(date_str)

		local summary_header = string.format(
			"%s - %s",
			os.date("%A, %B %d, %Y", os.time(CalendarState.current_date)),
			#entries > 0 and string.format("%d items", #entries) or "No items"
		)
		if #pending_notifications > 0 then
			summary_header = summary_header .. string.format(" • %d notifications", #pending_notifications)
		end

		table.insert(lines, left_pad_str .. MARGIN_STR .. summary_header)
		table.insert(highlights, {
			line = #lines,
			col = fn.strwidth(left_pad_str .. MARGIN_STR),
			end_col = fn.strwidth(left_pad_str .. MARGIN_STR .. summary_header),
			hl = cfg.colors.digest_header,
		})
		table.insert(lines, left_pad_str)

		if #entries > 0 then
			for _, entry in ipairs(entries) do
				local icon = cfg.icons.has_items
				if entry.type == "task" then
					icon = entry.task.completed and cfg.icons.task_done or cfg.icons.task
				elseif entry.type == "event" then
					icon = cfg.icons.event
				end
				if entry.attributes.notify then
					icon = cfg.icons.notification
				end

				-- Use the entry's format method to get the properly formatted string
				local formatted_entry = entry:format()
				local entry_line = string.format("  %s %s", icon, formatted_entry)
				table.insert(lines, left_pad_str .. MARGIN_STR .. entry_line)
			end
		else
			table.insert(lines, left_pad_str .. MARGIN_STR .. "  (no entries)")
		end

		-- Minimum height of 10 lines
		while #lines < line_num + 10 do
			table.insert(lines, "")
		end

		-- Show pending notifications
		if #pending_notifications > 0 then
			table.insert(lines, "")
			table.insert(lines, left_pad_str .. MARGIN_STR .. "Pending Notifications:")
			for _, notif in ipairs(pending_notifications) do
				local notif_line = string.format("  %s %s - %s", cfg.icons.notification, notif.time, notif.title)
				table.insert(lines, left_pad_str .. MARGIN_STR .. notif_line)
			end
		end
	end

	-- ── Footer key‑hints (bottom) ───────────────────────────────────────────
	-- Separator
	table.insert(lines, "")
	-- table.insert(lines, left_pad_str .. MARGIN_STR .. string.rep("─", GRID_WIDTH))
	table.insert(lines, string.rep("─", win_width))
	-- table.insert(highlights, {
	-- 	line = #lines,
	-- 	col = 0,
	-- 	end_col = win_width * 2,
	-- 	hl = cfg.colors.key_hint,
	-- })
	table.insert(lines, "")

	local footer_text = "↵ open • a add‑event • d delete • r rename • ? help"
	local footer_center = Renderer.center(win_width, footer_text)

	table.insert(lines, footer_center.line)
	table.insert(highlights, {
		line = #lines,
		col = footer_center.col,
		end_col = footer_center.end_col,
		hl = cfg.colors.key_hint,
		-- 			col = 0,
		-- 			end_col = fn.strwidth(line),
	})

	return lines, highlights
end

function Renderer.render_digest_view()
	local lines = {}
	local highlights = {}
	local today = datetime.get_current_date()
	local win_width = CalendarState.win_id and api.nvim_win_get_width(CalendarState.win_id) or cfg.window.width

	-- Header
	table.insert(lines, "")
	local header = "📋 Today's Digest & Upcoming Week"
	local header_padding = math.max(0, math.floor((win_width - fn.strwidth(header)) / 2))
	table.insert(lines, string.rep(" ", header_padding) .. header)
	table.insert(highlights, {
		line = 2,
		col = header_padding,
		end_col = header_padding + fn.strwidth(header),
		hl = cfg.colors.header,
	})
	table.insert(lines, string.rep("─", win_width))
	table.insert(lines, "")

	-- Show entries for today and next 7 days
	for i = 0, cfg.digest.show_upcoming_days do
		local date = datetime.add_days(today, i)
		local date_str = datetime.format_datetime(date, "YYYY-MM-DD")
		local entries = calendar_store.get_entries_for_date(date_str)

		if #entries > 0 then
			-- Date header
			local date_header = datetime.format_relative_date(date)
			if i > 1 then
				date_header = date_header .. string.format(" (%s)", os.date("%b %d", os.time(date)))
			end
			table.insert(lines, string.format("  %s", date_header))
			table.insert(highlights, {
				line = #lines,
				col = 2,
				end_col = 2 + fn.strwidth(date_header),
				hl = cfg.colors.digest_header,
			})

			-- Entries
			for _, entry in ipairs(entries) do
				local icon = cfg.icons.has_items
				if entry.type == "task" then
					icon = entry.task.completed and cfg.icons.task_done or cfg.icons.task
				elseif entry.type == "event" then
					icon = cfg.icons.event
				end
				if entry.attributes.notify then
					icon = cfg.icons.notification
				end

				-- Use the formatted entry display
				local formatted_entry = entry:format()
				local entry_line = string.format("    %s %s", icon, formatted_entry)
				table.insert(lines, entry_line)
			end
			table.insert(lines, "")
		end
	end

	-- Show high priority projects
	if cfg.digest.show_high_priority then
		local projects = require("zortex.services.projects")
		projects.load()

		local high_priority = {}
		for _, project in ipairs(projects.get_all_projects()) do
			if project.attributes.p == "1" or project.attributes.i == "1" then
				table.insert(high_priority, project)
			end
		end

		if #high_priority > 0 then
			table.insert(lines, string.rep("─", win_width))
			table.insert(lines, "")
			table.insert(lines, "  🎯 High Priority Projects")
			table.insert(highlights, {
				line = #lines,
				col = 2,
				end_col = 2 + fn.strwidth("🎯 High Priority Projects"),
				hl = cfg.colors.digest_header,
			})
			table.insert(lines, "")

			for _, project in ipairs(high_priority) do
				local priority_str = ""
				if project.attributes.p == "1" then
					priority_str = priority_str .. " [P1]"
				end
				if project.attributes.i == "1" then
					priority_str = priority_str .. " [I1]"
				end

				local project_line = string.format(
					"    • %s%s",
					project.name:gsub("@%w+%b()", ""):gsub("@%w+", ""):gsub("^%s*(.-)%s*$", "%1"),
					priority_str
				)
				table.insert(lines, project_line)
			end
		end
	end

	return lines, highlights
end

function Renderer.apply_highlights(bufnr, highlights)
	local ns_id = CalendarState.ns_id or api.nvim_create_namespace("zortex_calendar")

	for _, hl in ipairs(highlights) do
		api.nvim_buf_add_highlight(bufnr, ns_id, hl.hl, hl.line - 1, hl.col, hl.end_col)
	end
end

function Renderer.update_selected_extmark()
	if not CalendarState.current_date or not CalendarState.bufnr then
		return
	end

	local date_str = datetime.format_datetime(CalendarState.current_date, "YYYY-MM-DD")
	local mark = CalendarState.marks[date_str]
	if not mark then
		return
	end

	-- Clear previous highlight (if any)
	if CalendarState.selected_extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, CalendarState.bufnr, CalendarState.ns_id, CalendarState.selected_extmark_id)
		CalendarState.selected_extmark_id = nil
	end

	-- Convert *screen* columns → *byte* columns so multi‑byte icons don’t skew
	local line_txt = vim.api.nvim_buf_get_lines(CalendarState.bufnr, mark.line - 1, mark.line, false)[1] or ""
	local byte_start = vim.str_byteindex(line_txt, "utf-32", mark.col)
	local byte_end = vim.str_byteindex(line_txt, "utf-32", mark.end_col)

	-- Whole‑cell background
	CalendarState.selected_extmark_id =
		vim.api.nvim_buf_set_extmark(CalendarState.bufnr, CalendarState.ns_id, mark.line - 1, byte_start, {
			end_col = byte_end,
			hl_group = (date_str == datetime.format_datetime(datetime.get_current_date(), "YYYY-MM-DD"))
					and cfg.colors.today_selected
				or cfg.colors.selected,
			priority = 100,
		})

	-- Foreground for the digits so they pop even on a bright bg
	local cell_txt = line_txt:sub(byte_start + 1, byte_end)
	local rel_s, rel_e = cell_txt:find("%d%d?")
	if rel_s then
		vim.api.nvim_buf_add_highlight(
			CalendarState.bufnr,
			CalendarState.ns_id,
			cfg.colors.selected_text,
			mark.line - 1,
			byte_start + rel_s - 1,
			byte_start + rel_e
		)
	end
end

-- =============================================================================
-- Calendar Navigation
-- =============================================================================

local Navigation = {}

function Navigation.move_to_date(date)
	CalendarState.current_date = date
	M.refresh()
end

function Navigation.next_day()
	local date = CalendarState.current_date or datetime.get_current_date()
	Navigation.move_to_date(datetime.add_days(date, 1))
end

function Navigation.prev_day()
	local date = CalendarState.current_date or datetime.get_current_date()
	Navigation.move_to_date(datetime.add_days(date, -1))
end

function Navigation.next_week()
	local date = CalendarState.current_date or datetime.get_current_date()
	Navigation.move_to_date(datetime.add_days(date, 7))
end

function Navigation.prev_week()
	local date = CalendarState.current_date or datetime.get_current_date()
	Navigation.move_to_date(datetime.add_days(date, -7))
end

function Navigation.next_month()
	local date = CalendarState.current_date or datetime.get_current_date()
	date.month = date.month + 1
	if date.month > 12 then
		date.month, date.year = 1, date.year + 1
	end
	date.day = math.min(date.day, datetime.get_days_in_month(date.year, date.month))
	Navigation.move_to_date(date)
end

function Navigation.prev_month()
	local date = CalendarState.current_date or datetime.get_current_date()
	date.month = date.month - 1
	if date.month < 1 then
		date.month, date.year = 12, date.year - 1
	end
	date.day = math.min(date.day, datetime.get_days_in_month(date.year, date.month))
	Navigation.move_to_date(date)
end

function Navigation.next_year()
	local date = CalendarState.current_date or datetime.get_current_date()
	date.year = date.year + 1
	date.day = math.min(date.day, datetime.get_days_in_month(date.year, date.month))
	Navigation.move_to_date(date)
end

function Navigation.prev_year()
	local date = CalendarState.current_date or datetime.get_current_date()
	date.year = date.year - 1
	date.day = math.min(date.day, datetime.get_days_in_month(date.year, date.month))
	Navigation.move_to_date(date)
end

function Navigation.go_to_today()
	Navigation.move_to_date(datetime.get_current_date())
end

function Navigation.select_date_at_cursor()
	if not CalendarState.win_id or not api.nvim_win_is_valid(CalendarState.win_id) then
		return false
	end

	-- Get mouse position
	local mouse_pos = fn.getmousepos()
	if mouse_pos.winid ~= CalendarState.win_id then
		return false
	end

	local line = mouse_pos.line
	local col = mouse_pos.column - 1 -- Convert to 0-based

	for date_str, mark in pairs(CalendarState.marks) do
		if mark.line == line and col >= mark.col and col < mark.end_col then
			local date = datetime.parse_date(date_str)
			if date then
				Navigation.move_to_date(date)
				return true
			end
		end
	end
	return false
end

-- =============================================================================
-- Calendar Actions
-- =============================================================================

local Actions = {}

function Actions.add_entry()
	if not CalendarState.current_date then
		vim.notify("Please select a date first", vim.log.levels.WARN)
		return
	end
	local date_str = datetime.format_datetime(CalendarState.current_date, "YYYY-MM-DD")
	M.close()
	vim.ui.input({ prompt = string.format("Add entry for %s: ", date_str), default = "" }, function(input)
		if input and input ~= "" then
			calendar_store.add_entry(date_str, input)
			vim.notify(string.format("Added entry for %s", date_str), vim.log.levels.INFO)
			M.open()
			Navigation.move_to_date(CalendarState.current_date)
		else
			M.open()
		end
	end)
end

-- -- Delete entry with confirmation
-- function Actions.delete_entry_interactive()
-- 	if not CalendarState.current_date then
-- 		vim.notify("Please select a date first", vim.log.levels.WARN)
-- 		return
-- 	end
-- 	local date_str = datetime.format_datetime(CalendarState.current_date, "YYYY-MM-DD")
--
-- 	local entries = require("zortex.stores.calendar").get_entries_for_date(date_str)
--
-- 	if not entries or #entries == 0 then
-- 		vim.notify("No entries for " .. date_str, vim.log.levels.WARN)
-- 		return
-- 	end
--
-- 	-- Build selection list
-- 	local items = {}
-- 	for i, entry in ipairs(entries) do
-- 		table.insert(items, string.format("%d. %s", i, entry:format()))
-- 	end
--
-- 	vim.ui.select(items, {
-- 		prompt = "Select entry to delete:",
-- 	}, function(choice, idx)
-- 		if choice and idx then
-- 			local success, err = calendar_store.delete_entry_by_index(date_str, idx)
-- 			if success then
-- 				vim.notify("Entry deleted", vim.log.levels.INFO)
-- 			else
-- 				vim.notify("Failed to delete entry: " .. (err or "unknown error"), vim.log.levels.ERROR)
-- 			end
-- 		end
-- 	end)
-- end

function Actions.view_entries()
	if not CalendarState.current_date then
		vim.notify("Please select a date first", vim.log.levels.WARN)
		return
	end
	local date_str = datetime.format_datetime(CalendarState.current_date, "YYYY-MM-DD")
	M.close()
	local cal_file = fs.get_calendar_file()
	vim.cmd("edit " .. fn.fnameescape(cal_file))
	local search_pattern = string.format(
		"%02d-%02d-%04d:",
		CalendarState.current_date.month,
		CalendarState.current_date.day,
		CalendarState.current_date.year
	)
	fn.search(search_pattern)
	vim.cmd("normal! zz")
end

function Actions.telescope_search()
	M.close()
	require("zortex.ui.telescope").calendar()
end

function Actions.show_digest()
	CalendarState.view_mode = "digest"
	M.refresh()
end

function Actions.toggle_view()
	if CalendarState.view_mode == "month" then
		CalendarState.view_mode = "digest"
	else
		CalendarState.view_mode = "month"
	end
	M.refresh()
end

function Actions.go_to_file()
	M.close()
	local cal_file = fs.get_calendar_file()
	vim.cmd("edit " .. fn.fnameescape(cal_file))
end

function Actions.sync_notifications()
	if notifications then
		notifications.sync()
		vim.notify("Notifications synced", vim.log.levels.INFO)
		M.refresh()
	else
		vim.notify("Notification module not available", vim.log.levels.WARN)
	end
end

function Actions.show_help()
	local help_lines = {
		"Zortex Calendar - Key Bindings",
		"",
		"Navigation:",
		"  h/← - Previous day",
		"  l/→ - Next day",
		"  j/↓ - Previous week",
		"  k/↑ - Next week",
		"  J   - Previous month",
		"  K   - Next month",
		"  H   - Previous year",
		"  L   - Next year",
		"  t/T - Go to today",
		"",
		"Actions:",
		"  a/i     - Add entry",
		"  <CR>/o  - View/edit entries",
		"  e       - Edit selected entry",
		"  x       - Delete selected entry",
		"  d/D     - Show digest view",
		"  v       - Toggle view mode",
		"  gf      - Go to calendar file",
		"  n       - Sync notifications",
		"  r/R     - Refresh",
		"  /       - Search with Telescope",
		"  ?       - Show this help",
		"  q/<Esc> - Close calendar",
		"",
		"Mouse:",
		"  Click        - Select date",
		"  Double-click - View entries",
	}

	local width = 40
	local height = #help_lines + 2
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, help_lines)
	api.nvim_buf_set_option(buf, "modifiable", false)

	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		title = " Help ",
		title_pos = "center",
		style = "minimal",
	})

	-- Close on any key
	vim.keymap.set("n", "<Esc>", function()
		api.nvim_win_close(win, true)
	end, { buffer = buf })
	vim.keymap.set("n", "q", function()
		api.nvim_win_close(win, true)
	end, { buffer = buf })
end

-- =============================================================================
-- Keymap Setup
-- =============================================================================

local function setup_keymaps(bufnr)
	local opts = { buffer = bufnr, noremap = true, silent = true }

	local keymap_actions = {
		next_day = Navigation.next_day,
		prev_day = Navigation.prev_day,
		next_week = Navigation.next_week,
		prev_week = Navigation.prev_week,
		next_month = Navigation.next_month,
		prev_month = Navigation.prev_month,
		next_year = Navigation.next_year,
		prev_year = Navigation.prev_year,
		today = Navigation.go_to_today,
		add_entry = Actions.add_entry,
		view_entries = Actions.view_entries,
		telescope_search = Actions.telescope_search,
		digest = Actions.show_digest,
		toggle_view = Actions.toggle_view,
		go_to_file = Actions.go_to_file,
		sync_notifications = Actions.sync_notifications,
		help = Actions.show_help,
		refresh = M.refresh,
		close = M.close,
	}

	for action, func in pairs(keymap_actions) do
		local keys = cfg.keymaps[action]
		if keys then
			for _, key in ipairs(keys) do
				vim.keymap.set("n", key, func, opts)
			end
		end
	end

	-- Mouse support
	vim.keymap.set("n", "<LeftMouse>", Navigation.select_date_at_cursor, opts)
	vim.keymap.set("n", "<2-LeftMouse>", function()
		if Navigation.select_date_at_cursor() then
			Actions.view_entries()
		end
	end, opts)
end

-- =============================================================================
-- Public API
-- =============================================================================

function M.open()
	calendar_store.load()

	if CalendarState.win_id and api.nvim_win_is_valid(CalendarState.win_id) then
		api.nvim_set_current_win(CalendarState.win_id)
		return
	end

	CalendarState.bufnr = Renderer.create_buffer()
	CalendarState.win_id = Renderer.create_window(CalendarState.bufnr)
	CalendarState.ns_id = api.nvim_create_namespace("zortex_calendar")

	if not CalendarState.current_date then
		CalendarState.current_date = datetime.get_current_date()
	end

	setup_keymaps(CalendarState.bufnr)
	M.refresh()

	-- Position cursor out of the way
	api.nvim_win_set_cursor(CalendarState.win_id, { 1, 0 })
end

function M.close()
	if CalendarState.win_id and api.nvim_win_is_valid(CalendarState.win_id) then
		pcall(api.nvim_win_close, CalendarState.win_id, true)
	end
	CalendarState.win_id = nil
	CalendarState.bufnr = nil
	CalendarState.marks = {}
	CalendarState.selected_extmark_id = nil
end

function M.refresh()
	if not CalendarState.bufnr or not api.nvim_buf_is_valid(CalendarState.bufnr) then
		return
	end

	CalendarState.marks = {}
	local lines, highlights

	if CalendarState.view_mode == "digest" then
		lines, highlights = Renderer.render_digest_view()
	else
		lines, highlights = Renderer.render_month_view(CalendarState.current_date or datetime.get_current_date())
	end

	api.nvim_buf_set_option(CalendarState.bufnr, "modifiable", true)
	api.nvim_buf_set_lines(CalendarState.bufnr, 0, -1, false, lines)
	api.nvim_buf_set_option(CalendarState.bufnr, "modifiable", false)

	-- Clear all highlights
	api.nvim_buf_clear_namespace(CalendarState.bufnr, CalendarState.ns_id, 0, -1)

	-- Apply highlights
	Renderer.apply_highlights(CalendarState.bufnr, highlights)

	-- Update selected date extmark
	if CalendarState.view_mode == "month" then
		Renderer.update_selected_extmark()
	end
end

function M.toggle()
	if CalendarState.win_id and api.nvim_win_is_valid(CalendarState.win_id) then
		M.close()
	else
		M.open()
	end
end

function M.open_digest()
	calendar_store.load()
	M.open()
	Actions.show_digest()
end

function M.setup(opts)
	cfg = opts
end

return M
