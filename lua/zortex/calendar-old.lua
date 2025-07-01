-- calendar.lua - Enhanced Calendar view and management for Zortex
-- Provides popup calendar view, weekly view, and Telescope integration
-- Stores calendar data in Calendar.zortex file

local M = {}

-- Dependencies
local api = vim.api
local fn = vim.fn

-- Constants
local CALENDAR_FILE = "calendar.zortex"
local DAYS = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
local DAYS_FULL = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = {
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

-- State
local state = {
	current_date = nil, -- Selected date (cursor position)
	today = nil, -- Today's actual date
	calendar_data = {},
	calendar_buf = nil,
	calendar_win = nil,
	view_mode = "month", -- "month" or "week"
}

-- Initialize current date
local function init_current_date()
	local today = os.date("*t")
	state.today = {
		year = today.year,
		month = today.month,
		day = today.day,
	}
	state.current_date = {
		year = today.year,
		month = today.month,
		day = today.day,
	}
end

init_current_date()

-- =============================================================================
-- CALENDAR DATA MANAGEMENT
-- =============================================================================

--- Get calendar file path
local function get_calendar_path()
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir then
		vim.notify("g:zortex_notes_dir not set", vim.log.levels.ERROR)
		return nil
	end
	-- Ensure trailing slash
	if not notes_dir:match("/$") then
		notes_dir = notes_dir .. "/"
	end
	return notes_dir .. CALENDAR_FILE
end

--- Parse calendar file and load data
function M.load_calendar_data()
	local path = get_calendar_path()
	if not path then
		return {}
	end

	state.calendar_data = {}

	if fn.filereadable(path) == 0 then
		return state.calendar_data
	end

	local current_date = nil
	local current_entries = {}

	for line in io.lines(path) do
		-- Check for date header (MM-DD-YYYY:)
		local month, day, year = line:match("^(%d%d)%-(%d%d)%-(%d%d%d%d):$")
		if month and day and year then
			-- Save previous date's entries
			if current_date then
				state.calendar_data[current_date] = current_entries
			end
			-- Start new date
			current_date = string.format("%04d-%02d-%02d", year, month, day)
			current_entries = {}
		elseif current_date and line:match("^%s+%- ") then
			-- Task/entry line
			local entry = line:match("^%s+%- (.+)$")
			if entry then
				table.insert(current_entries, entry)
			end
		end
	end

	-- Save last date's entries
	if current_date then
		state.calendar_data[current_date] = current_entries
	end

	return state.calendar_data
end

--- Save calendar data to file
function M.save_calendar_data()
	local path = get_calendar_path()
	if not path then
		return false
	end

	local file = io.open(path, "w")
	if not file then
		vim.notify("Failed to open calendar file for writing", vim.log.levels.ERROR)
		return false
	end

	-- Sort dates
	local dates = {}
	for date in pairs(state.calendar_data) do
		table.insert(dates, date)
	end
	table.sort(dates)

	-- Write organized by month
	local last_month = nil
	local last_week = nil

	for _, date in ipairs(dates) do
		local year, month, day = date:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
		year, month, day = tonumber(year), tonumber(month), tonumber(day)

		local entries = state.calendar_data[date]
		if entries and #entries > 0 then
			-- Month header
			local month_header = string.format("# %s %d", MONTHS[month], year)
			if last_month ~= month_header then
				if last_month then
					file:write("\n")
				end
				file:write(month_header .. "\n\n")
				last_month = month_header
			end

			-- Week header (optional, using ISO week)
			local t = os.time({ year = year, month = month, day = day })
			local week = tonumber(os.date("%V", t))
			local week_header = string.format("## Week %d", week)
			if last_week ~= week_header then
				file:write(week_header .. "\n\n")
				last_week = week_header
			end

			-- Date and entries (using MM-DD-YYYY format as requested)
			file:write(string.format("%02d-%02d-%04d:\n", month, day, year))
			for _, entry in ipairs(entries) do
				file:write("  - " .. entry .. "\n")
			end
			file:write("\n")
		end
	end

	file:close()
	return true
end

--- Add entry to calendar
function M.add_entry(date_str, entry)
	if not state.calendar_data[date_str] then
		state.calendar_data[date_str] = {}
	end
	table.insert(state.calendar_data[date_str], entry)
	M.save_calendar_data()
end

-- =============================================================================
-- CALENDAR UTILITIES
-- =============================================================================

--- Get days in month
local function days_in_month(year, month)
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
		return 29
	end
	return days[month]
end

--- Get day of week (0 = Sunday, 6 = Saturday)
local function day_of_week(year, month, day)
	local t = os.time({ year = year, month = month, day = day })
	return tonumber(os.date("%w", t))
end

--- Get ISO week number
local function get_week_number(year, month, day)
	local t = os.time({ year = year, month = month, day = day })
	return tonumber(os.date("%V", t))
end

--- Get week start date (Monday)
local function get_week_start(year, month, day)
	local t = os.time({ year = year, month = month, day = day })
	local dow = tonumber(os.date("%w", t))
	-- Adjust to Monday as start (0 = Sunday, so we need to go back)
	local days_back = dow == 0 and 6 or dow - 1
	local week_start = t - (days_back * 86400)
	local date = os.date("*t", week_start)
	return date.year, date.month, date.day
end

-- =============================================================================
-- MONTH VIEW
-- =============================================================================

--- Generate calendar lines for a month with week numbers
local function generate_month_lines(year, month, show_week_nums)
	local lines = {}
	local num_days = days_in_month(year, month)
	local first_dow = day_of_week(year, month, 1)

	-- Month header
	local header = string.format("%s %d", MONTHS[month], year)
	local header_padding = math.floor((25 - #header) / 2)
	if show_week_nums then
		header_padding = math.floor((28 - #header) / 2)
	end
	table.insert(lines, string.format("%s%s", string.rep(" ", header_padding), header))
	table.insert(lines, "")

	-- Day headers
	if show_week_nums then
		table.insert(lines, " Su Mo Tu We Th Fr Sa  Wk")
	else
		table.insert(lines, " Su Mo Tu We Th Fr Sa")
	end

	-- Calendar grid
	local line = ""
	local week_num = nil

	-- Leading spaces
	for i = 1, first_dow do
		line = line .. "   "
	end

	-- Days
	for day = 1, num_days do
		local date_str = string.format("%04d-%02d-%02d", year, month, day)
		local has_entries = state.calendar_data[date_str] and #state.calendar_data[date_str] > 0

		-- Get week number for first day of each week
		if show_week_nums and ((first_dow + day - 1) % 7 == 0 or day == 1) then
			week_num = get_week_number(year, month, day)
		end

		-- Highlight current selection, today, and days with entries
		local day_str = string.format("%2d", day)
		local is_selected = year == state.current_date.year
			and month == state.current_date.month
			and day == state.current_date.day
		local is_today = year == state.today.year and month == state.today.month and day == state.today.day

		if is_selected then
			day_str = "[" .. day .. "]" -- Selected day marker
		elseif is_today then
			day_str = ">" .. day_str:sub(2) -- Today marker
		elseif has_entries then
			day_str = "*" .. day_str:sub(2) -- Entry marker
		end

		line = line .. string.format("%3s", day_str)

		-- New line after Saturday
		if (first_dow + day - 1) % 7 == 6 then
			if show_week_nums and week_num then
				line = line .. string.format("  %2d", week_num)
			end
			table.insert(lines, line)
			line = ""
			week_num = nil
		end
	end

	-- Last partial week
	if line ~= "" then
		if show_week_nums and week_num then
			-- Pad to align week number
			local remaining_days = 7 - ((first_dow + num_days - 1) % 7) - 1
			for i = 1, remaining_days do
				line = line .. "   "
			end
			line = line .. string.format("  %2d", week_num)
		end
		table.insert(lines, line)
	end

	return lines
end

--- Generate three-month calendar view
local function generate_three_month_view()
	local lines = {}
	local year = state.current_date.year
	local month = state.current_date.month

	-- Calculate previous and next months
	local prev_month = month - 1
	local prev_year = year
	if prev_month < 1 then
		prev_month = 12
		prev_year = year - 1
	end

	local next_month = month + 1
	local next_year = year
	if next_month > 12 then
		next_month = 1
		next_year = year + 1
	end

	-- Generate calendars
	local prev_cal = generate_month_lines(prev_year, prev_month, false)
	local curr_cal = generate_month_lines(year, month, true) -- Show week numbers for current month
	local next_cal = generate_month_lines(next_year, next_month, false)

	-- Find max lines
	local max_lines = math.max(#prev_cal, #curr_cal, #next_cal)

	-- Combine side by side
	for i = 1, max_lines do
		local prev_line = prev_cal[i] or ""
		local curr_line = curr_cal[i] or ""
		local next_line = next_cal[i] or ""

		-- Pad lines to consistent width
		prev_line = string.format("%-21s", prev_line)
		curr_line = string.format("%-28s", curr_line) -- Extra width for week numbers
		next_line = string.format("%-21s", next_line)

		table.insert(lines, prev_line .. " │ " .. curr_line .. " │ " .. next_line)
	end

	return lines
end

-- =============================================================================
-- WEEK VIEW
-- =============================================================================

--- Generate week view
local function generate_week_view()
	local lines = {}
	local year, month, day = get_week_start(state.current_date.year, state.current_date.month, state.current_date.day)

	-- Week header
	local week_num = get_week_number(state.current_date.year, state.current_date.month, state.current_date.day)
	table.insert(lines, string.format("Week %d, %d", week_num, state.current_date.year))
	table.insert(lines, string.rep("─", 70))
	table.insert(lines, "")

	-- Show each day of the week
	for i = 0, 6 do
		local t = os.time({ year = year, month = month, day = day }) + (i * 86400)
		local date = os.date("*t", t)
		local date_str = string.format("%04d-%02d-%02d", date.year, date.month, date.day)

		-- Day header
		local day_header = string.format("%s, %s %d", DAYS_FULL[date.wday], MONTHS[date.month], date.day)
		local is_today = date.year == state.today.year
			and date.month == state.today.month
			and date.day == state.today.day
		local is_selected = date.year == state.current_date.year
			and date.month == state.current_date.month
			and date.day == state.current_date.day

		if is_selected then
			day_header = "▶ " .. day_header
		elseif is_today then
			day_header = "● " .. day_header
		else
			day_header = "  " .. day_header
		end

		table.insert(lines, day_header)
		table.insert(lines, "  " .. string.rep("─", 50))

		-- Entries for this day
		local entries = state.calendar_data[date_str]
		if entries and #entries > 0 then
			for _, entry in ipairs(entries) do
				table.insert(lines, "    • " .. entry)
			end
		else
			table.insert(lines, "    (no entries)")
		end
		table.insert(lines, "")
	end

	return lines
end

-- =============================================================================
-- CALENDAR VIEW
-- =============================================================================

--- Create calendar buffer content
local function create_calendar_content()
	local lines = {}

	-- Navigation help
	if state.view_mode == "month" then
		table.insert(lines, "Navigation: h/l = day, j/k = week, J/K = month, H/L = year, w = week view")
	else
		table.insert(lines, "Navigation: j/k = day, J/K = week, m = month view")
	end
	table.insert(lines, "Actions: Enter = go to day, a = add entry, t = today, q = quit")
	table.insert(lines, "Markers: [n] = selected, >n = today, *n = has entries")
	table.insert(lines, string.rep("─", 80))
	table.insert(lines, "")

	if state.view_mode == "month" then
		-- Three-month view
		local month_lines = generate_three_month_view()
		for _, line in ipairs(month_lines) do
			table.insert(lines, line)
		end
	else
		-- Week view
		local week_lines = generate_week_view()
		for _, line in ipairs(week_lines) do
			table.insert(lines, line)
		end
	end

	-- Show entries for selected day
	table.insert(lines, "")
	table.insert(lines, string.rep("─", 80))
	local selected_date =
		string.format("%04d-%02d-%02d", state.current_date.year, state.current_date.month, state.current_date.day)
	table.insert(lines, string.format("Selected: %s", os.date("%A, %B %d, %Y", os.time(state.current_date))))
	table.insert(lines, "")

	local entries = state.calendar_data[selected_date]
	if entries and #entries > 0 then
		for _, entry in ipairs(entries) do
			table.insert(lines, "  • " .. entry)
		end
	else
		table.insert(lines, "  (no entries)")
	end

	return lines
end

--- Update calendar display
local function update_calendar_display()
	if not state.calendar_buf or not api.nvim_buf_is_valid(state.calendar_buf) then
		return
	end

	local lines = create_calendar_content()
	vim.bo[state.calendar_buf].modifiable = true
	api.nvim_buf_set_lines(state.calendar_buf, 0, -1, false, lines)
	vim.bo[state.calendar_buf].modifiable = false

	-- Apply highlights
	local ns_id = api.nvim_create_namespace("zortex_calendar")
	api.nvim_buf_clear_namespace(state.calendar_buf, ns_id, 0, -1)

	for i, line in ipairs(lines) do
		-- Highlight selected day
		local pattern = "%[%d+%]"
		local start_col = line:find(pattern)
		if start_col then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Visual", i - 1, start_col - 1, start_col + 2)
		end

		-- Highlight today
		local today_pattern = ">%d+"
		local today_col = line:find(today_pattern)
		if today_col then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Special", i - 1, today_col - 1, today_col + 2)
		end

		-- Highlight days with entries
		local entry_pattern = "%*%d+"
		local entry_col = line:find(entry_pattern)
		if entry_col then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Directory", i - 1, entry_col - 1, entry_col + 2)
		end

		-- Highlight week view markers
		if line:find("^▶") then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Visual", i - 1, 0, 2)
		elseif line:find("^●") then
			api.nvim_buf_add_highlight(state.calendar_buf, ns_id, "Special", i - 1, 0, 2)
		end
	end
end

--- Calendar navigation
local function navigate_calendar(direction)
	local year = state.current_date.year
	local month = state.current_date.month
	local day = state.current_date.day

	if state.view_mode == "week" then
		-- Simplified navigation for week view
		if direction == "next_day" or direction == "next_week" then
			local t = os.time({ year = year, month = month, day = day })
			local days_to_add = direction == "next_day" and 1 or 7
			local new_t = t + (days_to_add * 86400)
			local new_date = os.date("*t", new_t)
			year, month, day = new_date.year, new_date.month, new_date.day
		elseif direction == "prev_day" or direction == "prev_week" then
			local t = os.time({ year = year, month = month, day = day })
			local days_to_sub = direction == "prev_day" and 1 or 7
			local new_t = t - (days_to_sub * 86400)
			local new_date = os.date("*t", new_t)
			year, month, day = new_date.year, new_date.month, new_date.day
		elseif direction == "today" then
			local today = os.date("*t")
			year, month, day = today.year, today.month, today.day
			state.today = {
				year = today.year,
				month = today.month,
				day = today.day,
			}
		end
	else
		-- Original month view navigation
		if direction == "next_month" then
			month = month + 1
			if month > 12 then
				month = 1
				year = year + 1
			end
		elseif direction == "prev_month" then
			month = month - 1
			if month < 1 then
				month = 12
				year = year - 1
			end
		elseif direction == "next_year" then
			year = year + 1
		elseif direction == "prev_year" then
			year = year - 1
		elseif direction == "next_week" then
			day = day + 7
			local max_days = days_in_month(year, month)
			if day > max_days then
				day = day - max_days
				month = month + 1
				if month > 12 then
					month = 1
					year = year + 1
				end
			end
		elseif direction == "prev_week" then
			day = day - 7
			if day < 1 then
				month = month - 1
				if month < 1 then
					month = 12
					year = year - 1
				end
				day = days_in_month(year, month) + day
			end
		elseif direction == "next_day" then
			day = day + 1
			local max_days = days_in_month(year, month)
			if day > max_days then
				day = 1
				month = month + 1
				if month > 12 then
					month = 1
					year = year + 1
				end
			end
		elseif direction == "prev_day" then
			day = day - 1
			if day < 1 then
				month = month - 1
				if month < 1 then
					month = 12
					year = year - 1
				end
				day = days_in_month(year, month)
			end
		elseif direction == "today" then
			local today = os.date("*t")
			year = today.year
			month = today.month
			day = today.day
			-- Also update the global today state in case date changed
			state.today = {
				year = today.year,
				month = today.month,
				day = today.day,
			}
		end
	end

	-- Ensure day is valid for the month
	local max_days = days_in_month(year, month)
	if day > max_days then
		day = max_days
	end

	state.current_date = { year = year, month = month, day = day }
	update_calendar_display()
end

--- Toggle view mode
local function toggle_view_mode()
	if state.view_mode == "month" then
		state.view_mode = "week"
	else
		state.view_mode = "month"
	end
	update_calendar_display()
end

--- Setup calendar keymaps
local function setup_calendar_keymaps()
	local buf = state.calendar_buf
	local opts = { noremap = true, silent = true, buffer = buf }

	-- View toggle
	vim.keymap.set("n", "w", function()
		if state.view_mode == "month" then
			toggle_view_mode()
		end
	end, opts)
	vim.keymap.set("n", "m", function()
		if state.view_mode == "week" then
			toggle_view_mode()
		end
	end, opts)

	-- Month/Year navigation (only in month view)
	vim.keymap.set("n", "H", function()
		if state.view_mode == "month" then
			navigate_calendar("prev_year")
		end
	end, opts)
	vim.keymap.set("n", "L", function()
		if state.view_mode == "month" then
			navigate_calendar("next_year")
		end
	end, opts)
	vim.keymap.set("n", "K", function()
		if state.view_mode == "month" then
			navigate_calendar("prev_month")
		else
			navigate_calendar("prev_week")
		end
	end, opts)
	vim.keymap.set("n", "J", function()
		if state.view_mode == "month" then
			navigate_calendar("next_month")
		else
			navigate_calendar("next_week")
		end
	end, opts)

	-- Day navigation (vim-style)
	vim.keymap.set("n", "h", function()
		if state.view_mode == "month" then
			navigate_calendar("prev_day")
		end
	end, opts)
	vim.keymap.set("n", "l", function()
		if state.view_mode == "month" then
			navigate_calendar("next_day")
		end
	end, opts)
	vim.keymap.set("n", "k", function()
		if state.view_mode == "month" then
			navigate_calendar("prev_week")
		else
			navigate_calendar("prev_day")
		end
	end, opts)
	vim.keymap.set("n", "j", function()
		if state.view_mode == "month" then
			navigate_calendar("next_week")
		else
			navigate_calendar("next_day")
		end
	end, opts)

	-- Arrow key support
	vim.keymap.set("n", "<Left>", function()
		navigate_calendar("prev_day")
	end, opts)
	vim.keymap.set("n", "<Right>", function()
		navigate_calendar("next_day")
	end, opts)
	vim.keymap.set("n", "<Up>", function()
		if state.view_mode == "month" then
			navigate_calendar("prev_week")
		else
			navigate_calendar("prev_day")
		end
	end, opts)
	vim.keymap.set("n", "<Down>", function()
		if state.view_mode == "month" then
			navigate_calendar("next_week")
		else
			navigate_calendar("next_day")
		end
	end, opts)

	-- Actions
	vim.keymap.set("n", "t", function()
		navigate_calendar("today")
	end, opts)
	vim.keymap.set("n", "<CR>", function()
		M.go_to_date()
	end, opts)
	vim.keymap.set("n", "a", function()
		M.add_entry_interactive()
	end, opts)
	vim.keymap.set("n", "q", function()
		M.close_calendar()
	end, opts)
	vim.keymap.set("n", "<Esc>", function()
		M.close_calendar()
	end, opts)
end

--- Open calendar view
function M.open_calendar()
	-- Load calendar data
	M.load_calendar_data()

	-- Create buffer
	state.calendar_buf = api.nvim_create_buf(false, true)
	vim.bo[state.calendar_buf].buftype = "nofile"
	vim.bo[state.calendar_buf].bufhidden = "wipe"
	vim.bo[state.calendar_buf].filetype = "zortex-calendar"

	-- Calculate window size
	local width = 85
	local height = 30
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Create window
	state.calendar_win = api.nvim_open_win(state.calendar_buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Zortex Calendar ",
		title_pos = "center",
	})

	-- Setup keymaps and display
	setup_calendar_keymaps()
	update_calendar_display()
end

--- Close calendar view
function M.close_calendar()
	if state.calendar_win and api.nvim_win_is_valid(state.calendar_win) then
		api.nvim_win_close(state.calendar_win, true)
	end
	state.calendar_win = nil
	state.calendar_buf = nil
	state.view_mode = "month" -- Reset to month view
end

--- Go to selected date
function M.go_to_date()
	local date = state.current_date
	local date_str = string.format("%04d-%02d-%02d", date.year, date.month, date.day)

	-- Close calendar
	M.close_calendar()

	local path = get_calendar_path()
	-- Create or open daily note
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir then
		vim.notify("g:zortex_notes_dir not set", vim.log.levels.ERROR)
		return
	end

	-- Ensure trailing slash
	if not notes_dir:match("/$") then
		notes_dir = notes_dir .. "/"
	end

	-- Use format: YYYYMMDD.zortex
	local filename = string.format("%04d%02d%02d%s", date.year, date.month, date.day, vim.g.zortex_extension or ".md")
	local filepath = notes_dir .. filename

	vim.cmd("edit " .. vim.fn.fnameescape(filepath))

	-- If new file, add header
	if fn.line("$") == 1 and fn.getline(1) == "" then
		local lines = {
			"@@" .. os.date("%B %d, %Y", os.time(date)),
			"",
			"# Daily Log",
			"",
		}
		api.nvim_buf_set_lines(0, 0, -1, false, lines)
	end
end

--- Add entry interactively
function M.add_entry_interactive()
	local date = state.current_date
	local date_str = string.format("%04d-%02d-%02d", date.year, date.month, date.day)

	vim.ui.input({
		prompt = string.format("Add entry for %s: ", date_str),
	}, function(input)
		if input and input ~= "" then
			M.add_entry(date_str, input)
			update_calendar_display()
		end
	end)
end

-- =============================================================================
-- TELESCOPE INTEGRATION
-- =============================================================================

--- Telescope calendar picker
function M.telescope_calendar(opts)
	opts = opts or {}

	-- Load calendar data
	M.load_calendar_data()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local conf = require("telescope.config").values
	local entry_display = require("telescope.pickers.entry_display")

	-- Create entries
	local entries = {}
	for date_str, date_entries in pairs(state.calendar_data) do
		if #date_entries > 0 then
			local year, month, day = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
			if year and month and day then
				local date_obj = os.time({
					year = tonumber(year),
					month = tonumber(month),
					day = tonumber(day),
				})
				local formatted_date = os.date("%a, %b %d, %Y", date_obj)

				table.insert(entries, {
					value = date_str,
					display_date = formatted_date,
					ordinal = formatted_date .. " " .. table.concat(date_entries, " "),
					entries = date_entries,
					date_obj = date_obj,
				})
			end
		end
	end

	-- Sort by date
	table.sort(entries, function(a, b)
		return a.date_obj > b.date_obj
	end)

	pickers
		.new(opts, {
			prompt_title = "Calendar Entries",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.display_date .. " │ " .. #entry.entries .. " entries",
						ordinal = entry.ordinal,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = require("telescope.previewers").new_buffer_previewer({
				title = "Calendar Entry Preview",
				define_preview = function(self, entry)
					local lines = {
						"Date: " .. entry.value.display_date,
						"",
						"Entries:",
						"",
					}
					for _, e in ipairs(entry.value.entries) do
						table.insert(lines, "  • " .. e)
					end

					api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						-- Go to date
						local year, month, day = selection.value.value:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
						state.current_date = {
							year = tonumber(year),
							month = tonumber(month),
							day = tonumber(day),
						}
						M.go_to_date()
					end
				end)
				return true
			end,
		})
		:find()
end

-- =============================================================================
-- QUICK ADD
-- =============================================================================

--- Quick add entry for today
function M.quick_add_today(entry)
	local today = os.date("%Y-%m-%d")
	M.load_calendar_data()
	M.add_entry(today, entry)
	vim.notify("Added to calendar: " .. entry)
end

--- Quick add with date picker
function M.quick_add()
	vim.ui.input({
		prompt = "Date (YYYY-MM-DD) or relative (today/tomorrow/+N): ",
	}, function(date_input)
		if not date_input then
			return
		end

		local date_str
		if date_input == "today" or date_input == "" then
			date_str = os.date("%Y-%m-%d")
		elseif date_input == "tomorrow" then
			date_str = os.date("%Y-%m-%d", os.time() + 86400)
		elseif date_input:match("^%+%d+$") then
			local days = tonumber(date_input:sub(2))
			date_str = os.date("%Y-%m-%d", os.time() + days * 86400)
		else
			-- Validate date format
			local year, month, day = date_input:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
			if not year then
				vim.notify("Invalid date format. Use YYYY-MM-DD", vim.log.levels.ERROR)
				return
			end
			date_str = date_input
		end

		vim.ui.input({
			prompt = string.format("Add entry for %s: ", date_str),
		}, function(entry)
			if entry and entry ~= "" then
				M.load_calendar_data()
				M.add_entry(date_str, entry)
				vim.notify("Added to calendar: " .. entry)
			end
		end)
	end)
end

return M
