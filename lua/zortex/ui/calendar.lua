-- ui/calendar.lua - Calendar UI module for Zortex
local M = {}
local api = vim.api
local fn = vim.fn

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local calendar = require("zortex.modules.calendar")

-- =============================================================================
-- Calendar State and Configuration
-- =============================================================================

local CalendarState = {
	bufnr = nil,
	win_id = nil,
	current_date = nil,
	view_mode = "month", -- month, week, day
	marks = {}, -- Date marks for highlighting
}

-- Default configuration, can be overridden in main config
local Config = {
	window = {
		relative = "editor",
		width = 82, -- Default width if unable to get from window
		height = 0.8,
		border = "rounded",
		title = " 📅 Zortex Calendar ",
		title_pos = "center",
	},
	colors = {
		today = "DiagnosticOk",
		selected = "Visual", -- Use a block highlight instead of CursorLine
		today_selected = "DiffAdd", -- Special highlight for when today is also selected
		weekend = "Comment",
		has_entry = "DiagnosticInfo",
		header = "Title",
		border = "FloatBorder",
	},
	icons = {
		event = "🎉",
		task = "📝",
		task_done = "✔",
		notification = "🔔",
		has_items = "•", -- Default dot for days with any entry
	},
	pretty_attributes = true, -- Enable/disable pretty display of attributes
	keymaps = {
		close = { "q", "<Esc>" },
		next_day = { "l", "<Right>" },
		prev_day = { "h", "<Left>" },
		next_week = { "j", "<Down>" },
		prev_week = { "k", "<Up>" },
		next_month = { "J" },
		prev_month = { "K" },
		next_year = { "L" },
		prev_year = { "H" },
		today = { "t" },
		add_entry = { "a", "i" },
		view_entries = { "<CR>", "o" },
		telescope_search = { "/" },
		toggle_view = { "v" },
		digest = { "d" },
		go_to_file = { "g" },
	},
}

-- =============================================================================
-- Date Utilities
-- =============================================================================

local DateUtil = {}

function DateUtil.get_current_date()
	local now = os.date("*t")
	return {
		year = now.year,
		month = now.month,
		day = now.day,
		wday = now.wday,
	}
end

function DateUtil.get_days_in_month(year, month)
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
		return 29
	end
	return days[month]
end

function DateUtil.get_first_weekday(year, month)
	local time = os.time({ year = year, month = month, day = 1 })
	return os.date("*t", time).wday
end

function DateUtil.format_date(date)
	return string.format("%04d-%02d-%02d", date.year, date.month, date.day)
end

function DateUtil.format_month_year(date)
	local months = {
		"January",
		"February",
		"March",
		"April",
		"May",
		"June",
		"July",
		"August",
		"September",
		"October",
		"November",
		"December",
	}
	return string.format("%s %d", months[date.month], date.year)
end

function DateUtil.add_days(date, days)
	local time = os.time(date)
	local new_time = time + (days * 86400)
	local new_date = os.date("*t", new_time)
	return { year = new_date.year, month = new_date.month, day = new_date.day, wday = new_date.wday }
end

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
	local width
	if Config.window.width <= 1 then -- Treat as percentage if <= 1
		width = math.floor(vim.o.columns * Config.window.width)
	else -- Treat as fixed column count
		width = Config.window.width
	end
	local height = math.floor(vim.o.lines * Config.window.height)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Create window
	local win_id = api.nvim_open_win(bufnr, true, {
		relative = Config.window.relative,
		width = width,
		height = height,
		row = row,
		col = col,
		border = Config.window.border,
		title = Config.window.title,
		title_pos = Config.window.title_pos,
		style = "minimal",
	})

	-- Set window options
	api.nvim_win_set_option(win_id, "number", false)
	api.nvim_win_set_option(win_id, "relativenumber", false)
	api.nvim_win_set_option(win_id, "signcolumn", "no")
	api.nvim_win_set_option(win_id, "wrap", false)
	api.nvim_win_set_option(win_id, "winhl", "Normal:Normal,FloatBorder:" .. Config.colors.border)

	return win_id
end

-- Pretty‑print attributes
local function format_pretty_attrs(entry)
	if not Config.pretty_attributes then
		return ""
	end
	local parts = {}
	if entry.attributes.at then
		table.insert(parts, "🕑 " .. entry.attributes.at)
	end
	if entry.attributes.duration then
		table.insert(parts, string.format("⏳ %sm", entry.attributes.duration))
	end
	if entry.attributes.notification_enabled then
		table.insert(parts, Config.icons.notify)
	end
	if entry.attributes.repeating then
		table.insert(parts, "🔁" .. entry.attributes.repeating)
	end
	if entry.attributes.from then
		table.insert(parts, string.format("◂", entry.attributes.from))
	end
	if entry.attributes.to then
		table.insert(parts, string.format("▸", entry.attributes.to))
	end

	if #parts > 0 then
		return "  " .. table.concat(parts, "  ")
	else
		return ""
	end
end

function Renderer.render_month_view(date)
	-- Get the actual window width. Fallback to config if window not ready.
	local win_width = CalendarState.win_id and api.nvim_win_get_width(CalendarState.win_id) or Config.window.width

	local lines = {}
	local highlights = {}
	local today = DateUtil.get_current_date()

	-- Define layout constants
	local MARGIN_STR = "  "
	local CELL_WIDTH = 7 -- Each day cell is 7 columns wide
	local GRID_WIDTH = 7 * CELL_WIDTH -- 7 days * 7 cols = 49
	local CONTENT_WIDTH = fn.strwidth(MARGIN_STR) + GRID_WIDTH -- 2 + 49 = 51

	-- Calculate centering padding based on the actual window width
	local total_padding = win_width - CONTENT_WIDTH
	local left_pad_str = string.rep(" ", math.max(0, math.floor(total_padding / 2)))

	-- Header
	local header_text = DateUtil.format_month_year(date)
	local nav_hint = "←/→/↑/↓ move | H/L year | J/K month | t today"
	local header_space = win_width - (fn.strwidth(left_pad_str) + fn.strwidth(header_text) + fn.strwidth(nav_hint))
	local header_padding = string.rep(" ", math.max(1, header_space))
	local header_line = left_pad_str .. header_text .. header_padding .. nav_hint

	table.insert(lines, header_line)
	table.insert(highlights, {
		line = 1,
		col = fn.strwidth(left_pad_str),
		end_col = fn.strwidth(left_pad_str) + fn.strwidth(header_text),
		hl = Config.colors.header,
	})

	-- Separator
	table.insert(lines, left_pad_str .. MARGIN_STR .. string.rep("─", GRID_WIDTH))

	-- Day headers
	local day_header_parts = {}
	for _, name in ipairs({ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }) do
		table.insert(day_header_parts, "  " .. name .. "  ") -- Center "Sun" in 7 spaces
	end
	table.insert(lines, left_pad_str .. MARGIN_STR .. table.concat(day_header_parts, ""))
	table.insert(lines, "") -- Blank line for spacing

	-- Load calendar data
	calendar.load()

	-- Build calendar grid
	local days_in_month = DateUtil.get_days_in_month(date.year, date.month)
	local first_weekday = DateUtil.get_first_weekday(date.year, date.month)
	local current_day = 1
	local line_num = #lines + 1

	for week = 1, 6 do
		if current_day > days_in_month then
			break
		end

		local week_line_parts = { left_pad_str, MARGIN_STR }

		for weekday = 1, 7 do
			local day_cell_str
			if (week == 1 and weekday >= first_weekday) or (week > 1 and current_day <= days_in_month) then
				local day_num = current_day
				local date_str = string.format("%04d-%02d-%02d", date.year, date.month, day_num)
				local entries = calendar.get_entries_for_date(date_str)
				local is_today = date.year == today.year and date.month == today.month and day_num == today.day
				local is_selected = CalendarState.current_date
					and date.year == CalendarState.current_date.year
					and date.month == CalendarState.current_date.month
					and day_num == CalendarState.current_date.day

				-- Determine icon
				local day_icon = " "
				if #entries > 0 then
					day_icon = Config.icons.has_items
					local has_task, has_event, has_notification = false, false, false
					for _, entry in ipairs(entries) do
						if entry.attributes.notification_enabled then
							has_notification = true
						end
						if entry.type == "event" then
							has_event = true
						end
						if entry.type == "task" then
							has_task = true
						end
					end
					if has_notification then
						day_icon = Config.icons.notification
					elseif has_event then
						day_icon = Config.icons.event
					elseif has_task then
						day_icon = Config.icons.task
					end
				end

				-- Format the cell respecting icon width
				local day_num_str = string.format("%2d", day_num)
				local cell_content = day_icon .. " " .. day_num_str
				local content_w = fn.strwidth(cell_content)
				local padding_w = CELL_WIDTH - content_w
				local lpad = string.rep(" ", math.max(0, math.floor(padding_w / 2)))
				local rpad = string.rep(" ", math.max(0, math.ceil(padding_w / 2)))
				day_cell_str = lpad .. cell_content .. rpad

				-- Calculate 0-based column position for highlights
				local base_col_0based = fn.strwidth(left_pad_str) + fn.strwidth(MARGIN_STR) + (weekday - 1) * CELL_WIDTH

				-- Add highlights for the whole cell
				local hl_group = nil
				if is_selected and is_today then
					hl_group = Config.colors.today_selected
				elseif is_selected then
					hl_group = Config.colors.selected
				elseif is_today then
					hl_group = Config.colors.today
				elseif weekday == 1 or weekday == 7 then
					hl_group = Config.colors.weekend
				end

				if hl_group then
					table.insert(highlights, {
						line = line_num,
						col = base_col_0based,
						end_col = base_col_0based + CELL_WIDTH,
						hl = hl_group,
					})
				end

				-- Highlight icon separately if there are entries but no other highlight
				if #entries > 0 and not (is_selected or is_today) then
					local icon_col_start = base_col_0based + fn.strwidth(lpad)
					table.insert(highlights, {
						line = line_num,
						col = icon_col_start,
						end_col = icon_col_start + fn.strwidth(day_icon),
						hl = Config.colors.has_entry,
					})
				end

				-- Store position for navigation (0-based column)
				CalendarState.marks[date_str] = { line = line_num, col = base_col_0based, day = day_num }

				current_day = current_day + 1
			else
				day_cell_str = string.rep(" ", CELL_WIDTH) -- Empty cell
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
		local date_str = DateUtil.format_date(CalendarState.current_date)
		local entries = calendar.get_entries_for_date(date_str)

		local summary_header = string.format(
			"%s - %s",
			os.date("%A, %B %d, %Y", os.time(CalendarState.current_date)),
			#entries > 0 and string.format("%d items", #entries) or "No items"
		)
		table.insert(lines, left_pad_str .. MARGIN_STR .. summary_header)
		table.insert(lines, left_pad_str) -- Blank line

		if #entries > 0 then
			for _, entry in ipairs(entries) do
				local icon = Config.icons.has_items
				if entry.type == "task" then
					icon = (entry.task_status and entry.task_status.key == "[x]") and Config.icons.task_done
						or Config.icons.task
				elseif entry.type == "event" then
					icon = Config.icons.event
				end
				if entry.attributes.notification_enabled then
					icon = Config.icons.notification
				end

				local time_str = ""
				if entry.attributes.from and entry.attributes.to then
					time_str = string.format("%s-%s ", entry.attributes.from, entry.attributes.to)
				elseif entry.attributes.at then
					time_str = entry.attributes.at .. " "
				end

				local attr_str = format_pretty_attrs(entry)
				local entry_line = string.format("  %s %s%s%s", icon, time_str, entry.display_text, attr_str)
				table.insert(lines, left_pad_str .. MARGIN_STR .. entry_line)
			end
		end
	end

	return lines, highlights
end

function Renderer.render_week_view(date)
	-- This view can be enhanced similarly if needed
	local lines, highlights = {}, {}
	table.insert(lines, "Week view not yet implemented with new renderer.")
	return lines, highlights
end

function Renderer.apply_highlights(bufnr, highlights)
	local ns_id = api.nvim_create_namespace("zortex_calendar")
	api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

	for _, hl in ipairs(highlights) do
		api.nvim_buf_add_highlight(bufnr, ns_id, hl.hl, hl.line - 1, hl.col, hl.end_col)
	end
end

-- =============================================================================
-- Calendar Navigation
-- =============================================================================

local Navigation = {}

function Navigation.move_to_date(date)
	CalendarState.current_date = date
	M.refresh()

	if CalendarState.view_mode == "month" then
		local date_str = DateUtil.format_date(date)
		local mark = CalendarState.marks[date_str]
		if mark then
			-- mark.col is the 0-based start of the date cell, move cursor near the middle
			pcall(api.nvim_win_set_cursor, CalendarState.win_id, { mark.line, mark.col + 3 })
		end
	end
end

function Navigation.next_day()
	local date = CalendarState.current_date or DateUtil.get_current_date()
	Navigation.move_to_date(DateUtil.add_days(date, 1))
end

function Navigation.prev_day()
	local date = CalendarState.current_date or DateUtil.get_current_date()
	Navigation.move_to_date(DateUtil.add_days(date, -1))
end

function Navigation.next_week()
	local date = CalendarState.current_date or DateUtil.get_current_date()
	Navigation.move_to_date(DateUtil.add_days(date, 7))
end

function Navigation.prev_week()
	local date = CalendarState.current_date or DateUtil.get_current_date()
	Navigation.move_to_date(DateUtil.add_days(date, -7))
end

function Navigation.next_month()
	local date = CalendarState.current_date or DateUtil.get_current_date()
	date.month = date.month + 1
	if date.month > 12 then
		date.month, date.year = 1, date.year + 1
	end
	date.day = math.min(date.day, DateUtil.get_days_in_month(date.year, date.month))
	Navigation.move_to_date(date)
end

function Navigation.prev_month()
	local date = CalendarState.current_date or DateUtil.get_current_date()
	date.month = date.month - 1
	if date.month < 1 then
		date.month, date.year = 12, date.year - 1
	end
	date.day = math.min(date.day, DateUtil.get_days_in_month(date.year, date.month))
	Navigation.move_to_date(date)
end

function Navigation.next_year()
	local date = CalendarState.current_date or DateUtil.get_current_date()
	date.year = date.year + 1
	date.day = math.min(date.day, DateUtil.get_days_in_month(date.year, date.month))
	Navigation.move_to_date(date)
end

function Navigation.prev_year()
	local date = CalendarState.current_date or DateUtil.get_current_date()
	date.year = date.year - 1
	date.day = math.min(date.day, DateUtil.get_days_in_month(date.year, date.month))
	Navigation.move_to_date(date)
end

function Navigation.go_to_today()
	Navigation.move_to_date(DateUtil.get_current_date())
end

function Navigation.select_date_at_cursor()
	if not CalendarState.win_id or not api.nvim_win_is_valid(CalendarState.win_id) then
		return false
	end
	local cursor = api.nvim_win_get_cursor(CalendarState.win_id)
	local line, col = cursor[1], cursor[2] -- line is 1-based, col is 0-based

	for date_str, mark in pairs(CalendarState.marks) do
		-- Check if the 0-based cursor column `col` is within the date cell's width
		if mark.line == line and col >= mark.col and col < mark.col + 7 then -- 7 is CELL_WIDTH
			local date = parser.parse_date(date_str)
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
	local date_str = DateUtil.format_date(CalendarState.current_date)
	M.close()
	vim.ui.input({ prompt = string.format("Add entry for %s: ", date_str), default = "" }, function(input)
		if input and input ~= "" then
			calendar.add_entry(date_str, input)
			vim.notify(string.format("Added entry for %s", date_str), vim.log.levels.INFO)
			M.open()
			Navigation.move_to_date(CalendarState.current_date)
		else
			M.open()
		end
	end)
end

function Actions.view_entries()
	if not CalendarState.current_date then
		if not Navigation.select_date_at_cursor() then
			vim.notify("Please select a date first", vim.log.levels.WARN)
			return
		end
	end
	local date_str = DateUtil.format_date(CalendarState.current_date)
	M.close()
	local cal_file = fs.get_file_path("calendar.zortex")
	if cal_file then
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
end

function Actions.telescope_search()
	M.close()
	require("zortex.ui.telescope").calendar()
end

function Actions.show_digest()
	M.close()
	require("zortex.ui.telescope").today_digest()
end

function Actions.toggle_view()
	if CalendarState.view_mode == "month" then
		CalendarState.view_mode = "week"
	else
		CalendarState.view_mode = "month"
	end
	M.refresh()
end

function Actions.go_to_file()
	M.close()
	local cal_file = fs.get_file_path("calendar.zortex")
	if cal_file then
		vim.cmd("edit " .. fn.fnameescape(cal_file))
	end
end

-- =============================================================================
-- Keymap Setup
-- =============================================================================

local function setup_keymaps(bufnr)
	local opts = { buffer = bufnr, noremap = true, silent = true }
	for name, func in pairs({
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
		close = M.close,
	}) do
		for _, key in ipairs(Config.keymaps[name]) do
			vim.keymap.set("n", key, func, opts)
		end
	end
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
	if CalendarState.win_id and api.nvim_win_is_valid(CalendarState.win_id) then
		api.nvim_set_current_win(CalendarState.win_id)
		return
	end
	CalendarState.bufnr = Renderer.create_buffer()
	CalendarState.win_id = Renderer.create_window(CalendarState.bufnr)
	if not CalendarState.current_date then
		CalendarState.current_date = DateUtil.get_current_date()
	end
	setup_keymaps(CalendarState.bufnr)
	M.refresh()
	Navigation.move_to_date(CalendarState.current_date)
end

function M.close()
	if CalendarState.win_id and api.nvim_win_is_valid(CalendarState.win_id) then
		pcall(api.nvim_win_close, CalendarState.win_id, true)
	end
	CalendarState.win_id = nil
	CalendarState.bufnr = nil
	CalendarState.marks = {}
end

function M.refresh()
	if not CalendarState.bufnr or not api.nvim_buf_is_valid(CalendarState.bufnr) then
		return
	end
	CalendarState.marks = {}
	local lines, highlights
	if CalendarState.view_mode == "month" then
		lines, highlights = Renderer.render_month_view(CalendarState.current_date or DateUtil.get_current_date())
	else
		lines, highlights = Renderer.render_week_view(CalendarState.current_date or DateUtil.get_current_date())
	end
	api.nvim_buf_set_option(CalendarState.bufnr, "modifiable", true)
	api.nvim_buf_set_lines(CalendarState.bufnr, 0, -1, false, lines)
	api.nvim_buf_set_option(CalendarState.bufnr, "modifiable", false)
	Renderer.apply_highlights(CalendarState.bufnr, highlights)
end

function M.toggle()
	if CalendarState.win_id and api.nvim_win_is_valid(CalendarState.win_id) then
		M.close()
	else
		M.open()
	end
end

function M.setup(opts)
	if opts and opts.calendar then
		Config = vim.tbl_deep_extend("force", Config, opts.calendar)
	end
	calendar.load()
end

return M
