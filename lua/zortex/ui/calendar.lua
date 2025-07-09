-- ui/calendar.lua - Calendar UI module for Zortex
local M = {}

-- Core dependencies
local parser = require("zortex.core.parser")
local buffer = require("zortex.core.buffer")
local fs = require("zortex.core.filesystem")

-- Feature dependencies
local calendar = require("zortex.features.calendar")
local projects = require("zortex.features.projects")

-- UI dependencies
local api = vim.api
local fn = vim.fn

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

local Config = {
	window = {
		relative = "editor",
		width = 0.8,
		height = 0.8,
		border = "rounded",
		title = " 📅 Zortex Calendar ",
		title_pos = "center",
	},
	colors = {
		today = "DiagnosticOk",
		selected = "CursorLine",
		weekend = "Comment",
		has_entry = "DiagnosticInfo",
		header = "Title",
		border = "FloatBorder",
	},
	keymaps = {
		close = { "q", "<Esc>" },
		next_month = { "l", "<Right>" },
		prev_month = { "h", "<Left>" },
		next_year = { "L" },
		prev_year = { "H" },
		today = { "t" },
		add_entry = { "a", "i" },
		view_entries = { "<CR>", "o" },
		telescope_search = { "/" },
		toggle_view = { "v" },
		digest = { "d" },
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
	}
end

function DateUtil.get_days_in_month(year, month)
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

	-- Check for leap year
	if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
		return 29
	end

	return days[month]
end

function DateUtil.get_first_weekday(year, month)
	local time = os.time({ year = year, month = month, day = 1 })
	local date = os.date("*t", time)
	return date.wday -- 1 = Sunday, 7 = Saturday
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
	local width = math.floor(vim.o.columns * Config.window.width)
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
	api.nvim_win_set_option(win_id, "cursorline", true)
	api.nvim_win_set_option(win_id, "number", false)
	api.nvim_win_set_option(win_id, "relativenumber", false)
	api.nvim_win_set_option(win_id, "signcolumn", "no")
	api.nvim_win_set_option(win_id, "wrap", false)

	return win_id
end

function Renderer.render_month_view(date)
	local lines = {}
	local highlights = {}
	local today = DateUtil.get_current_date()

	-- Header
	local header = DateUtil.format_month_year(date)
	local nav_hint = "← h/l → | H/L year | t today | a add | / search"
	local header_line = string.format("  %s", header)
	local padding = math.max(1, 80 - #header_line - #nav_hint)
	header_line = header_line .. string.rep(" ", padding) .. nav_hint

	table.insert(lines, header_line)
	table.insert(highlights, { line = 1, col = 2, end_col = 2 + #header, hl = Config.colors.header })
	table.insert(lines, string.rep("─", 80))

	-- Day headers
	local day_headers = "  Sun    Mon    Tue    Wed    Thu    Fri    Sat"
	table.insert(lines, day_headers)
	table.insert(lines, "")

	-- Calculate calendar grid
	local days_in_month = DateUtil.get_days_in_month(date.year, date.month)
	local first_weekday = DateUtil.get_first_weekday(date.year, date.month)

	-- Load calendar data
	calendar.load()

	-- Build calendar grid
	local current_day = 1
	local line_num = #lines + 1

	for week = 1, 6 do
		if current_day > days_in_month then
			break
		end

		local week_line = "  "
		local col_offset = 2

		for weekday = 1, 7 do
			local day_str = "   "
			local day_num = nil

			if (week == 1 and weekday >= first_weekday) or (week > 1 and current_day <= days_in_month) then
				day_num = current_day
				day_str = string.format("%3d", current_day)
				current_day = current_day + 1
			end

			week_line = week_line .. day_str .. "    "

			-- Add highlights
			if day_num then
				local date_str = string.format("%04d-%02d-%02d", date.year, date.month, day_num)
				local entries = calendar.get_entries_for_date(date_str)
				local is_today = date.year == today.year and date.month == today.month and day_num == today.day
				local is_selected = CalendarState.current_date
					and date.year == CalendarState.current_date.year
					and date.month == CalendarState.current_date.month
					and day_num == CalendarState.current_date.day

				local hl_group = nil
				if is_selected then
					hl_group = Config.colors.selected
				elseif is_today then
					hl_group = Config.colors.today
				elseif #entries > 0 then
					hl_group = Config.colors.has_entry
				elseif weekday == 1 or weekday == 7 then
					hl_group = Config.colors.weekend
				end

				if hl_group then
					table.insert(highlights, {
						line = line_num,
						col = col_offset,
						end_col = col_offset + 3,
						hl = hl_group,
					})
				end

				-- Store position for navigation
				CalendarState.marks[date_str] = {
					line = line_num,
					col = col_offset,
					day = day_num,
				}
			end

			col_offset = col_offset + 7
		end

		table.insert(lines, week_line)
		line_num = line_num + 1
	end

	-- Add summary section
	table.insert(lines, "")
	table.insert(lines, string.rep("─", 80))
	table.insert(lines, "")

	-- Show entries for selected date
	if CalendarState.current_date then
		local date_str = DateUtil.format_date(CalendarState.current_date)
		local entries = calendar.get_entries_for_date(date_str)
		local project_tasks = calendar.get_project_tasks_for_date(date_str)

		table.insert(
			lines,
			string.format(
				"  %s - %s",
				os.date("%A, %B %d, %Y", os.time(CalendarState.current_date)),
				#entries + #project_tasks > 0 and string.format("%d items", #entries + #project_tasks) or "No items"
			)
		)
		table.insert(lines, "")

		-- Calendar entries
		if #entries > 0 then
			table.insert(lines, "  Calendar:")
			for _, entry in ipairs(entries) do
				local icon = "📅"
				if entry.type == "task" and entry.task_status then
					icon = entry.task_status.symbol
				elseif entry.attributes.notification_enabled then
					icon = "🔔"
				end

				local time_str = ""
				if entry.attributes.from and entry.attributes.to then
					time_str = string.format("%s-%s ", entry.attributes.from, entry.attributes.to)
				elseif entry.attributes.at then
					time_str = entry.attributes.at .. " "
				end

				table.insert(lines, string.format("    %s %s%s", icon, time_str, entry.display_text))
			end
		end

		-- Project tasks
		if #project_tasks > 0 then
			if #entries > 0 then
				table.insert(lines, "")
			end
			table.insert(lines, "  Projects:")
			for _, task in ipairs(project_tasks) do
				local icon = task.status and task.status.symbol or "☐"
				local time_str = task.attributes.at and (task.attributes.at .. " ") or ""
				table.insert(
					lines,
					string.format("    %s %s%s [%s]", icon, time_str, task.display_text, task.project or "Unknown")
				)
			end
		end
	end

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

	-- Position cursor on the date
	local date_str = DateUtil.format_date(date)
	local mark = CalendarState.marks[date_str]
	if mark then
		api.nvim_win_set_cursor(CalendarState.win_id, { mark.line, mark.col })
	end
end

function Navigation.next_month()
	local date = CalendarState.current_date or DateUtil.get_current_date()
	date.month = date.month + 1
	if date.month > 12 then
		date.month = 1
		date.year = date.year + 1
	end
	date.day = math.min(date.day, DateUtil.get_days_in_month(date.year, date.month))
	Navigation.move_to_date(date)
end

function Navigation.prev_month()
	local date = CalendarState.current_date or DateUtil.get_current_date()
	date.month = date.month - 1
	if date.month < 1 then
		date.month = 12
		date.year = date.year - 1
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
	local cursor = api.nvim_win_get_cursor(CalendarState.win_id)
	local line = cursor[1]
	local col = cursor[2]

	-- Find which date the cursor is on
	for date_str, mark in pairs(CalendarState.marks) do
		if mark.line == line and col >= mark.col and col < mark.col + 3 then
			local date = parser.parse_date(date_str)
			if date then
				CalendarState.current_date = date
				M.refresh()
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

	-- Close calendar temporarily
	M.close()

	-- Prompt for entry
	vim.ui.input({
		prompt = string.format("Add entry for %s: ", date_str),
		default = "",
	}, function(input)
		if input and input ~= "" then
			calendar.add_entry(date_str, input)
			calendar.save()
			vim.notify(string.format("Added entry for %s", date_str), vim.log.levels.INFO)

			-- Reopen calendar
			M.open()
			Navigation.move_to_date(CalendarState.current_date)
		else
			-- Reopen calendar even if cancelled
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

	-- Close calendar
	M.close()

	-- Open calendar file at the selected date
	local cal_file = fs.get_file_path("calendar.zortex")
	if cal_file then
		vim.cmd("edit " .. fn.fnameescape(cal_file))

		-- Search for the date in MM-DD-YYYY format
		local search_pattern = string.format(
			"%02d-%02d-%04d:",
			CalendarState.current_date.month,
			CalendarState.current_date.day,
			CalendarState.current_date.year
		)

		vim.fn.search(search_pattern)
		vim.cmd("normal! zz") -- Center the view
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

-- =============================================================================
-- Keymap Setup
-- =============================================================================

local function setup_keymaps(bufnr)
	local opts = { buffer = bufnr, noremap = true, silent = true }

	-- Navigation
	for _, key in ipairs(Config.keymaps.next_month) do
		vim.keymap.set("n", key, Navigation.next_month, opts)
	end
	for _, key in ipairs(Config.keymaps.prev_month) do
		vim.keymap.set("n", key, Navigation.prev_month, opts)
	end
	for _, key in ipairs(Config.keymaps.next_year) do
		vim.keymap.set("n", key, Navigation.next_year, opts)
	end
	for _, key in ipairs(Config.keymaps.prev_year) do
		vim.keymap.set("n", key, Navigation.prev_year, opts)
	end
	for _, key in ipairs(Config.keymaps.today) do
		vim.keymap.set("n", key, Navigation.go_to_today, opts)
	end

	-- Actions
	for _, key in ipairs(Config.keymaps.add_entry) do
		vim.keymap.set("n", key, Actions.add_entry, opts)
	end
	for _, key in ipairs(Config.keymaps.view_entries) do
		vim.keymap.set("n", key, Actions.view_entries, opts)
	end
	for _, key in ipairs(Config.keymaps.telescope_search) do
		vim.keymap.set("n", key, Actions.telescope_search, opts)
	end
	for _, key in ipairs(Config.keymaps.digest) do
		vim.keymap.set("n", key, Actions.show_digest, opts)
	end

	-- Close
	for _, key in ipairs(Config.keymaps.close) do
		vim.keymap.set("n", key, M.close, opts)
	end

	-- Mouse support
	vim.keymap.set("n", "<LeftMouse>", function()
		Navigation.select_date_at_cursor()
	end, opts)

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
	-- Don't open if already open
	if CalendarState.win_id and api.nvim_win_is_valid(CalendarState.win_id) then
		api.nvim_set_current_win(CalendarState.win_id)
		return
	end

	-- Create buffer and window
	CalendarState.bufnr = Renderer.create_buffer()
	CalendarState.win_id = Renderer.create_window(CalendarState.bufnr)

	-- Set initial date
	if not CalendarState.current_date then
		CalendarState.current_date = DateUtil.get_current_date()
	end

	-- Setup keymaps
	setup_keymaps(CalendarState.bufnr)

	-- Initial render
	M.refresh()

	-- Position cursor on current date
	Navigation.move_to_date(CalendarState.current_date)
end

function M.close()
	if CalendarState.win_id and api.nvim_win_is_valid(CalendarState.win_id) then
		api.nvim_win_close(CalendarState.win_id, true)
	end
	CalendarState.win_id = nil
	CalendarState.bufnr = nil
	CalendarState.marks = {}
end

function M.refresh()
	if not CalendarState.bufnr or not api.nvim_buf_is_valid(CalendarState.bufnr) then
		return
	end

	-- Clear marks
	CalendarState.marks = {}

	-- Render calendar
	local lines, highlights = Renderer.render_month_view(CalendarState.current_date or DateUtil.get_current_date())

	-- Update buffer
	api.nvim_buf_set_option(CalendarState.bufnr, "modifiable", true)
	api.nvim_buf_set_lines(CalendarState.bufnr, 0, -1, false, lines)
	api.nvim_buf_set_option(CalendarState.bufnr, "modifiable", false)

	-- Apply highlights
	Renderer.apply_highlights(CalendarState.bufnr, highlights)
end

function M.set_date(year, month, day)
	CalendarState.current_date = {
		year = year,
		month = month,
		day = day,
	}
	if CalendarState.win_id then
		M.refresh()
		Navigation.move_to_date(CalendarState.current_date)
	end
end

function M.toggle()
	if CalendarState.win_id and api.nvim_win_is_valid(CalendarState.win_id) then
		M.close()
	else
		M.open()
	end
end

-- Digest buffer integration
function M.show_digest_buffer()
	-- Create a new buffer for the digest
	local bufnr = api.nvim_create_buf(false, true)
	api.nvim_buf_set_name(bufnr, "Zortex Daily Digest")
	api.nvim_buf_set_option(bufnr, "buftype", "nofile")
	api.nvim_buf_set_option(bufnr, "swapfile", false)
	api.nvim_buf_set_option(bufnr, "modifiable", false)

	-- Load data
	calendar.load()
	projects.load()

	local lines = {}
	local today = os.date("%Y-%m-%d")

	-- Header
	table.insert(
		lines,
		"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	)
	table.insert(lines, "📋 DAILY DIGEST - " .. os.date("%A, %B %d, %Y"))
	table.insert(
		lines,
		"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	)
	table.insert(lines, "")

	-- Today's calendar entries
	local today_entries = calendar.get_entries_for_date(today)
	if #today_entries > 0 then
		table.insert(lines, "📅 TODAY'S SCHEDULE")
		table.insert(lines, string.rep("─", 35))
		for _, entry in ipairs(today_entries) do
			local icon = entry.type == "task" and (entry.task_status and entry.task_status.symbol or "☐") or "•"
			local time = entry.attributes.at and (entry.attributes.at .. " - ") or ""
			table.insert(lines, string.format("  %s %s%s", icon, time, entry.display_text))
		end
		table.insert(lines, "")
	end

	-- Today's project tasks
	local project_tasks = calendar.get_project_tasks_for_date(today)
	if #project_tasks > 0 then
		table.insert(lines, "📁 PROJECT TASKS")
		table.insert(lines, string.rep("─", 35))
		for _, task in ipairs(project_tasks) do
			local icon = task.status and task.status.symbol or "☐"
			local time = task.attributes.at and (task.attributes.at .. " - ") or ""
			table.insert(
				lines,
				string.format("  %s %s%s [%s]", icon, time, task.display_text, task.project or "Unknown")
			)
		end
		table.insert(lines, "")
	end

	-- Upcoming events
	local upcoming = calendar.get_upcoming_events(7)
	if #upcoming > 0 then
		table.insert(lines, "📆 UPCOMING (Next 7 Days)")
		table.insert(lines, string.rep("─", 35))

		local current_date = ""
		for _, event in ipairs(upcoming) do
			if event.date ~= today then
				if event.date ~= current_date then
					current_date = event.date
					local date_obj = parser.parse_date(event.date)
					if date_obj then
						table.insert(lines, "")
						table.insert(lines, "  " .. os.date("%a, %b %d", os.time(date_obj)))
					end
				end

				local icon = event.entry.type == "task"
						and (event.entry.task_status and event.entry.task_status.symbol or "☐")
					or "•"
				local time = event.entry.attributes.at and (event.entry.attributes.at .. " - ") or ""
				table.insert(lines, string.format("    %s %s%s", icon, time, event.entry.display_text))
			end
		end
	end

	-- Set buffer content
	api.nvim_buf_set_option(bufnr, "modifiable", true)
	api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	api.nvim_buf_set_option(bufnr, "modifiable", false)
	api.nvim_buf_set_option(bufnr, "filetype", "markdown")

	-- Open in a new window
	vim.cmd("split")
	api.nvim_set_current_buf(bufnr)

	-- Set up buffer keymaps
	local opts = { buffer = bufnr, noremap = true, silent = true }
	vim.keymap.set("n", "q", ":close<CR>", opts)
	vim.keymap.set("n", "<Esc>", ":close<CR>", opts)
end

-- Setup function for initialization
function M.setup(opts)
	-- Merge with default config
	if opts then
		Config = vim.tbl_deep_extend("force", Config, opts)
	end
end

return M
