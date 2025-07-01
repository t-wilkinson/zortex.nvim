-- UI and interaction layer for the Zortex calendar.
-- Renders the calendar views, handles navigation, and user input.

-- The data layer, responsible for all data operations.
local data = require("zortex.calendar.data")

local M = {}

-- Dependencies
local api = vim.api

-- =============================================================================
-- Constants
-- =============================================================================

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

-- =============================================================================
-- UI State
-- =============================================================================

local ui_state = {
	current_date = nil, -- Table: {year, month, day} for the selected date
	today = nil, -- Table: {year, month, day} for the actual current date
	calendar_buf = nil,
	calendar_win = nil,
	view_mode = "month", -- "month" or "week"
}

--- Initialize current date to today.
local function init_current_date()
	local today = os.date("*t")
	ui_state.today = { year = today.year, month = today.month, day = today.day }
	ui_state.current_date = { year = today.year, month = today.month, day = today.day }
end

-- =============================================================================
-- Private Helper Functions
-- =============================================================================

--- Date/Time helpers for UI rendering
local function days_in_month(year, month)
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
		return 29
	end
	return days[month]
end

local function day_of_week(year, month, day)
	return tonumber(os.date("%w", os.time({ year = year, month = month, day = day })))
end

local function get_week_number(year, month, day)
	return tonumber(os.date("%V", os.time({ year = year, month = month, day = day })))
end

local function get_week_start(year, month, day)
	local t = os.time({ year = year, month = month, day = day })
	local dow = tonumber(os.date("%w", t))
	local days_back = dow == 0 and 6 or dow - 1
	local week_start_t = t - (days_back * 86400)
	local date = os.date("*t", week_start_t)
	return date.year, date.month, date.day
end

--- Count entries by type for a given date.
local function count_entries_by_type(date_str)
	local counts = { tasks = 0, events = 0, notes = 0, total = 0 }
	local entries = data.get_entries_for_date(date_str)
	for _, entry in ipairs(entries) do
		counts.total = counts.total + 1
		if entry.type == "task" then
			counts.tasks = counts.tasks + 1
		elseif entry.type == "event" then
			counts.events = counts.events + 1
		else
			counts.notes = counts.notes + 1
		end
	end
	return counts
end

--- Format a parsed entry for display in the UI.
local function format_entry_display(parsed_entry, show_attributes)
	local display = ""

	if parsed_entry.task_status then
		display = parsed_entry.task_status.symbol .. " "
	end

	display = display .. parsed_entry.display_text

	if parsed_entry.is_recurring_instance then
		display = display .. " 🔁"
	end
	if parsed_entry.is_due_date_instance then
		display = display .. " ❗"
	end

	if show_attributes then
		local attrs = {}
		if parsed_entry.attributes.at then
			table.insert(attrs, "🕐 " .. parsed_entry.attributes.at)
		end
		if parsed_entry.attributes.due and not parsed_entry.is_due_date_instance then
			table.insert(attrs, "📅 " .. parsed_entry.attributes.due)
		end
		if parsed_entry.attributes.repeating then
			table.insert(attrs, "🔁 " .. parsed_entry.attributes.repeating)
		end
		if parsed_entry.attributes.priority then
			table.insert(attrs, "P" .. parsed_entry.attributes.priority)
		end
		if #attrs > 0 then
			display = display .. " (" .. table.concat(attrs, ", ") .. ")"
		end
	end

	return display
end

-- =============================================================================
-- UI Rendering
-- =============================================================================

local update_calendar_display -- Forward declaration

--- Generate lines for a single month grid.
local function generate_month_lines(year, month, show_week_nums)
	local lines = {}
	local num_days = days_in_month(year, month)
	local first_dow = day_of_week(year, month, 1)

	local header = string.format("%s %d", MONTHS[month], year)
	local header_padding = math.floor((show_week_nums and 28 or 21 - #header) / 2)
	table.insert(lines, string.rep(" ", header_padding) .. header)
	table.insert(lines, "")
	table.insert(lines, show_week_nums and " Su Mo Tu We Th Fr Sa  Wk" or " Su Mo Tu We Th Fr Sa")

	local line = string.rep("   ", first_dow)
	for day = 1, num_days do
		local date_str = string.format("%04d-%02d-%02d", year, month, day)
		local counts = count_entries_by_type(date_str)
		local day_str = string.format("%2d", day)

		if
			year == ui_state.current_date.year
			and month == ui_state.current_date.month
			and day == ui_state.current_date.day
		then
			day_str = "[" .. day .. "]"
		elseif year == ui_state.today.year and month == ui_state.today.month and day == ui_state.today.day then
			day_str = ">" .. day_str:sub(2)
		elseif counts.total > 0 then
			if counts.tasks > 0 then
				day_str = "□" .. day_str:sub(2)
			elseif counts.events > 0 then
				day_str = "●" .. day_str:sub(2)
			else
				day_str = "*" .. day_str:sub(2)
			end
		end

		line = line .. string.format("%3s", day_str)

		if (first_dow + day) % 7 == 0 then
			if show_week_nums then
				line = line .. string.format("  %2d", get_week_number(year, month, day))
			end
			table.insert(lines, line)
			line = ""
		end
	end

	if line ~= "" then
		if show_week_nums then
			line = string.format("%-25s", line) .. string.format("  %2d", get_week_number(year, month, num_days))
		end
		table.insert(lines, line)
	end
	return lines
end

--- Generate lines for the three-month view.
local function generate_three_month_view()
	local y, m = ui_state.current_date.year, ui_state.current_date.month
	local prev_m, prev_y = (m == 1) and 12 or m - 1, (m == 1) and y - 1 or y
	local next_m, next_y = (m == 12) and 1 or m + 1, (m == 12) and y + 1 or y

	local prev_cal = generate_month_lines(prev_y, prev_m, false)
	local curr_cal = generate_month_lines(y, m, true)
	local next_cal = generate_month_lines(next_y, next_m, false)

	local max_lines = math.max(#prev_cal, #curr_cal, #next_cal)
	local combined_lines = {}
	for i = 1, max_lines do
		local p = string.format("%-21s", prev_cal[i] or "")
		local c = string.format("%-28s", curr_cal[i] or "")
		local n = string.format("%-21s", next_cal[i] or "")
		table.insert(combined_lines, p .. " │ " .. c .. " │ " .. n)
	end
	return combined_lines
end

--- Generate lines for the week view.
local function generate_week_view()
	local lines = {}
	local y, m, d = get_week_start(ui_state.current_date.year, ui_state.current_date.month, ui_state.current_date.day)
	local week_num = get_week_number(ui_state.current_date.year, ui_state.current_date.month, ui_state.current_date.day)
	table.insert(lines, string.format("Week %d, %d", week_num, ui_state.current_date.year))
	table.insert(lines, string.rep("─", 70))

	for i = 0, 6 do
		local t = os.time({ year = y, month = m, day = d }) + (i * 86400)
		local date = os.date("*t", t)
		local date_str = string.format("%04d-%02d-%02d", date.year, date.month, date.day)
		local day_header = string.format("%s, %s %d", DAYS_FULL[date.wday], MONTHS[date.month], date.day)

		if
			date.year == ui_state.current_date.year
			and date.month == ui_state.current_date.month
			and date.day == ui_state.current_date.day
		then
			day_header = "▶ " .. day_header
		elseif
			date.year == ui_state.today.year
			and date.month == ui_state.today.month
			and date.day == ui_state.today.day
		then
			day_header = "● " .. day_header
		else
			day_header = "  " .. day_header
		end
		table.insert(lines, "")
		table.insert(lines, day_header)

		local entries = data.get_entries_for_date(date_str)
		if #entries > 0 then
			for _, entry in ipairs(entries) do
				table.insert(lines, "    " .. format_entry_display(entry, true))
			end
		else
			table.insert(lines, "    (no entries)")
		end
	end
	return lines
end

--- Create the full content for the calendar buffer.
local function create_calendar_content()
	local lines = {}
	if ui_state.view_mode == "month" then
		table.insert(lines, "Nav: h/l (day), j/k (week), J/K (month), H/L (year)")
		table.insert(lines, "w (week view), a (add), t (today), q (quit)")
	else
		table.insert(lines, "Nav: j/k (day), J/K (week)")
		table.insert(lines, "m (month view), a (add), t (today), q (quit)")
	end
	table.insert(lines, string.rep("─", 80))

	local view_lines = (ui_state.view_mode == "month") and generate_three_month_view() or generate_week_view()
	for _, line in ipairs(view_lines) do
		table.insert(lines, line)
	end

	table.insert(lines, "")
	table.insert(lines, string.rep("─", 80))
	local sel = ui_state.current_date
	local sel_str = string.format("%04d-%02d-%02d", sel.year, sel.month, sel.day)
	table.insert(lines, string.format("Selected: %s", os.date("%A, %B %d, %Y", os.time(sel))))

	local entries = data.get_entries_for_date(sel_str)
	if #entries > 0 then
		for _, entry in ipairs(entries) do
			table.insert(lines, "  " .. format_entry_display(entry, true))
		end
	else
		table.insert(lines, "  (no entries)")
	end

	return lines
end

--- Apply syntax highlighting to the calendar buffer.
local function apply_highlights(lines)
	local ns_id = api.nvim_create_namespace("zortex_calendar")
	api.nvim_buf_clear_namespace(ui_state.calendar_buf, ns_id, 0, -1)

	for i, line in ipairs(lines) do
		-- Helper function to find and highlight a pattern safely.
		local function highlight_pattern(pattern, hl_group)
			local start_col, end_col = line:find(pattern)
			if start_col then
				api.nvim_buf_add_highlight(ui_state.calendar_buf, ns_id, hl_group, i - 1, start_col - 1, end_col)
			end
		end

		-- Highlight various markers in the calendar grid and week view.
		highlight_pattern("%[%d+%]", "Visual") -- Selected day: e.g., [12]
		highlight_pattern(">%d+", "Special") -- Today: e.g., >12
		highlight_pattern("□%d+", "Function") -- Day with tasks: e.g., □12
		highlight_pattern("●%d+", "Constant") -- Day with events: e.g., ●12
		highlight_pattern("%*%d+", "Directory") -- Day with notes: e.g., *12
		highlight_pattern("^▶", "Visual") -- Selected day marker in week view
		highlight_pattern("^●", "Special") -- Today marker in week view

		-- Highlight task status symbols.
		for _, status in pairs(data.TASK_STATUS) do
			-- Loop to find all occurrences of a symbol on a single line.
			local current_pos = 1
			while true do
				local start_col, end_col = line:find(status.symbol, current_pos, true)
				if not start_col then
					break
				end
				api.nvim_buf_add_highlight(ui_state.calendar_buf, ns_id, status.hl, i - 1, start_col - 1, end_col)
				current_pos = end_col + 1
			end
		end
	end
end

--- Update the calendar buffer with new content and highlights.
update_calendar_display = function()
	if not ui_state.calendar_buf or not api.nvim_buf_is_valid(ui_state.calendar_buf) then
		return
	end
	local lines = create_calendar_content()
	vim.bo[ui_state.calendar_buf].modifiable = true
	api.nvim_buf_set_lines(ui_state.calendar_buf, 0, -1, false, lines)
	vim.bo[ui_state.calendar_buf].modifiable = false
	apply_highlights(lines)
end

-- =============================================================================
-- UI Interaction & Navigation
-- =============================================================================

--- Handles calendar navigation logic.
local function navigate_calendar(direction)
	local d = ui_state.current_date
	local t = os.time(d)
	local new_t

	if direction == "today" then
		init_current_date()
	elseif ui_state.view_mode == "week" then
		if direction == "next_day" then
			new_t = t + 86400
		end
		if direction == "prev_day" then
			new_t = t - 86400
		end
		if direction == "next_week" then
			new_t = t + (7 * 86400)
		end
		if direction == "prev_week" then
			new_t = t - (7 * 86400)
		end
	else -- month view
		if direction == "next_day" then
			new_t = t + 86400
		end
		if direction == "prev_day" then
			new_t = t - 86400
		end
		if direction == "next_week" then
			new_t = t + (7 * 86400)
		end
		if direction == "prev_week" then
			new_t = t - (7 * 86400)
		end
		if direction == "next_month" then
			d.month = d.month + 1
		end
		if direction == "prev_month" then
			d.month = d.month - 1
		end
		if direction == "next_year" then
			d.year = d.year + 1
		end
		if direction == "prev_year" then
			d.year = d.year - 1
		end
	end

	if new_t then
		local new_date = os.date("*t", new_t)
		ui_state.current_date = { year = new_date.year, month = new_date.month, day = new_date.day }
	elseif d then
		-- Handle month/year rollovers
		if d.month > 12 then
			d.month = 1
			d.year = d.year + 1
		end
		if d.month < 1 then
			d.month = 12
			d.year = d.year - 1
		end
		-- Ensure day is valid
		d.day = math.min(d.day, days_in_month(d.year, d.month))
		ui_state.current_date = d
	end
	update_calendar_display()
end

--- Toggle between month and week view.
local function toggle_view_mode()
	ui_state.view_mode = (ui_state.view_mode == "month") and "week" or "month"
	update_calendar_display()
end

--- Setup keymaps for the calendar window.
local function setup_calendar_keymaps()
	local buf = ui_state.calendar_buf
	local opts = { noremap = true, silent = true, buffer = buf }
	local map = vim.keymap.set

	map("n", "q", M.close, opts)
	map("n", "<Esc>", M.close, opts)
	map("n", "t", function()
		navigate_calendar("today")
	end, opts)
	map("n", "a", M.add_entry_interactive, opts)
	map("n", "<CR>", M.go_to_date, opts)

	map("n", "w", function()
		if ui_state.view_mode == "month" then
			toggle_view_mode()
		end
	end, opts)
	map("n", "m", function()
		if ui_state.view_mode == "week" then
			toggle_view_mode()
		end
	end, opts)

	map("n", "h", function()
		if ui_state.view_mode == "month" then
			navigate_calendar("prev_day")
		end
	end, opts)
	map("n", "l", function()
		if ui_state.view_mode == "month" then
			navigate_calendar("next_day")
		end
	end, opts)
	map("n", "j", function()
		navigate_calendar(ui_state.view_mode == "month" and "next_week" or "next_day")
	end, opts)
	map("n", "k", function()
		navigate_calendar(ui_state.view_mode == "month" and "prev_week" or "prev_day")
	end, opts)
	map("n", "J", function()
		navigate_calendar(ui_state.view_mode == "month" and "next_month" or "next_week")
	end, opts)
	map("n", "K", function()
		navigate_calendar(ui_state.view_mode == "month" and "prev_month" or "prev_week")
	end, opts)
	map("n", "H", function()
		if ui_state.view_mode == "month" then
			navigate_calendar("prev_year")
		end
	end, opts)
	map("n", "L", function()
		if ui_state.view_mode == "month" then
			navigate_calendar("next_year")
		end
	end, opts)
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Opens the main calendar popup window.
function M.open()
	data.load()
	init_current_date()

	ui_state.calendar_buf = api.nvim_create_buf(false, true)
	vim.bo[ui_state.calendar_buf].buftype = "nofile"
	vim.bo[ui_state.calendar_buf].filetype = "zortex-calendar"

	local width, height = 85, 30
	ui_state.calendar_win = api.nvim_open_win(ui_state.calendar_buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " Zortex Calendar ",
		title_pos = "center",
	})

	setup_calendar_keymaps()
	update_calendar_display()
end

--- Closes the calendar window.
function M.close()
	if ui_state.calendar_win and api.nvim_win_is_valid(ui_state.calendar_win) then
		api.nvim_win_close(ui_state.calendar_win, true)
	end
	ui_state.calendar_win = nil
	ui_state.calendar_buf = nil
	ui_state.view_mode = "month" -- Reset view
end

--- Opens the calendar file, positioned at the selected date.
function M.go_to_date()
	local date = ui_state.current_date

	M.close()

	local path = data.get_calendar_path()
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	local lines = {
		os.date("%B-%d-%Y", os.time(date)) .. ":",
	}
	api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

--- Prompts the user to add a new entry for the selected date.
function M.add_entry_interactive()
	local d = ui_state.current_date
	local date_str = string.format("%04d-%02d-%02d", d.year, d.month, d.day)
	vim.ui.input({ prompt = string.format("Add for %s: ", date_str) }, function(input)
		if input and input ~= "" then
			data.add_entry(date_str, input)
			update_calendar_display()
		end
	end)
end

--- Telescope integration to search and view calendar entries.
function M.telescope_calendar(opts)
	opts = opts or {}
	data.load()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local all_parsed = data.get_all_parsed_entries()
	local entries = {}
	for date_str, parsed_list in pairs(all_parsed) do
		local y, m, d = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
		if y then
			local date_obj = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
			table.insert(entries, {
				value = date_str,
				display_date = os.date("%a, %b %d, %Y", date_obj),
				ordinal = date_obj,
				parsed_entries = parsed_list,
			})
		end
	end

	table.sort(entries, function(a, b)
		return a.ordinal > b.ordinal
	end)

	pickers
		.new(opts, {
			prompt_title = "Calendar Entries",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.display_date,
						ordinal = entry.display_date,
					}
				end,
			}),
			previewer = require("telescope.previewers").new_buffer_previewer({
				title = "Entry Preview",
				define_preview = function(self, entry)
					local lines = { "Date: " .. entry.value.display_date, "" }
					for _, parsed in ipairs(entry.value.parsed_entries) do
						table.insert(lines, "  " .. format_entry_display(parsed, true))
					end
					api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					-- Here you could implement logic to jump to the selected date
				end)
				return true
			end,
		})
		:find()
end

return M
