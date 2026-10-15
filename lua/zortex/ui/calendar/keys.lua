-- ui/calendar/keys.lua - Calendar keys: moving the selection and actions
--
-- Every function works on ui/calendar/view's state (the selected date and
-- view mode) and re-renders through it. attach() maps cfg.keymaps.
local M = {}
local api = vim.api
local fn = vim.fn

local datetime = require("zortex.utils.datetime")
local calendar_store = require("zortex.stores.calendar")
local fs = require("zortex.utils.filesystem")

local function view()
	return require("zortex.ui.calendar.view")
end

local function state()
	return view().state
end

-- =============================================================================
-- Moving the selection
-- =============================================================================

function M.move_to_date(date)
	state().current_date = date
	view().refresh()
end

function M.next_day()
	local date = state().current_date or datetime.get_current_date()
	M.move_to_date(datetime.add_days(date, 1))
end

function M.prev_day()
	local date = state().current_date or datetime.get_current_date()
	M.move_to_date(datetime.add_days(date, -1))
end

function M.next_week()
	local date = state().current_date or datetime.get_current_date()
	M.move_to_date(datetime.add_days(date, 7))
end

function M.prev_week()
	local date = state().current_date or datetime.get_current_date()
	M.move_to_date(datetime.add_days(date, -7))
end

function M.next_month()
	local date = state().current_date or datetime.get_current_date()
	date.month = date.month + 1
	if date.month > 12 then
		date.month, date.year = 1, date.year + 1
	end
	date.day = math.min(date.day, datetime.get_days_in_month(date.year, date.month))
	M.move_to_date(date)
end

function M.prev_month()
	local date = state().current_date or datetime.get_current_date()
	date.month = date.month - 1
	if date.month < 1 then
		date.month, date.year = 12, date.year - 1
	end
	date.day = math.min(date.day, datetime.get_days_in_month(date.year, date.month))
	M.move_to_date(date)
end

function M.next_year()
	local date = state().current_date or datetime.get_current_date()
	date.year = date.year + 1
	date.day = math.min(date.day, datetime.get_days_in_month(date.year, date.month))
	M.move_to_date(date)
end

function M.prev_year()
	local date = state().current_date or datetime.get_current_date()
	date.year = date.year - 1
	date.day = math.min(date.day, datetime.get_days_in_month(date.year, date.month))
	M.move_to_date(date)
end

function M.go_to_today()
	M.move_to_date(datetime.get_current_date())
end

function M.select_date_at_cursor()
	if not state().win_id or not api.nvim_win_is_valid(state().win_id) then
		return false
	end

	-- Get mouse position
	local mouse_pos = fn.getmousepos()
	if mouse_pos.winid ~= state().win_id then
		return false
	end

	local line = mouse_pos.line
	local col = mouse_pos.column - 1 -- Convert to 0-based

	for date_str, mark in pairs(state().marks) do
		if mark.line == line and col >= mark.col and col < mark.end_col then
			local date = datetime.parse_date(date_str)
			if date then
				M.move_to_date(date)
				return true
			end
		end
	end
	return false
end

-- =============================================================================
-- Actions
-- =============================================================================

function M.add_entry()
	if not state().current_date then
		vim.notify("Please select a date first", vim.log.levels.WARN)
		return
	end
	local date_str = datetime.format_datetime(state().current_date, "YYYY-MM-DD")
	view().close()
	vim.ui.input({ prompt = string.format("Add entry for %s: ", date_str), default = "" }, function(input)
		if input and input ~= "" then
			calendar_store.add_entry(date_str, input)
			vim.notify(string.format("Added entry for %s", date_str), vim.log.levels.INFO)
			view().open()
			M.move_to_date(state().current_date)
		else
			view().open()
		end
	end)
end

function M.view_entries()
	if not state().current_date then
		vim.notify("Please select a date first", vim.log.levels.WARN)
		return
	end
	local date_str = datetime.format_datetime(state().current_date, "YYYY-MM-DD")
	view().close()
	vim.cmd("edit " .. fn.fnameescape(fs.get_calendar_file()))
	local block = calendar_store.date_block(date_str, vim.api.nvim_buf_get_lines(0, 0, -1, false))
	if block then
		vim.api.nvim_win_set_cursor(0, { block.heading_lnum, 0 })
		vim.cmd("normal! zz")
	end
end

-- Pick an entry (newest day first) and jump to it (ui/picker/calendar).
function M.search()
	view().close()
	require("zortex.ui.picker.calendar").open()
end

function M.show_digest()
	state().view_mode = "digest"
	view().refresh()
end

function M.toggle_view()
	if state().view_mode == "month" then
		state().view_mode = "digest"
	else
		state().view_mode = "month"
	end
	view().refresh()
end

function M.go_to_file()
	view().close()
	local cal_file = fs.get_calendar_file()
	vim.cmd("edit " .. fn.fnameescape(cal_file))
end

function M.sync_notifications()
	require("zortex.notifications").calendar.sync({
		on_done = function(msg)
			vim.notify(msg, vim.log.levels.INFO)
		end,
	})
	view().refresh()
end

function M.show_help()
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
		"  /       - Search entries",
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
	vim.bo[buf].modifiable = false
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
-- Keymaps
-- =============================================================================

--- Map the configured keys (cfg.keymaps[action] = { keys }) and the mouse in `bufnr`.
function M.attach(bufnr, cfg)
	local opts = { buffer = bufnr, noremap = true, silent = true }

	local keymap_actions = {
		next_day = M.next_day,
		prev_day = M.prev_day,
		next_week = M.next_week,
		prev_week = M.prev_week,
		next_month = M.next_month,
		prev_month = M.prev_month,
		next_year = M.next_year,
		prev_year = M.prev_year,
		today = M.go_to_today,
		add_entry = M.add_entry,
		view_entries = M.view_entries,
		search = M.search,
		digest = M.show_digest,
		toggle_view = M.toggle_view,
		go_to_file = M.go_to_file,
		sync_notifications = M.sync_notifications,
		help = M.show_help,
		refresh = function()
			view().refresh()
		end,
		close = function()
			view().close()
		end,
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
	vim.keymap.set("n", "<LeftMouse>", M.select_date_at_cursor, opts)
	vim.keymap.set("n", "<2-LeftMouse>", function()
		if M.select_date_at_cursor() then
			M.view_entries()
		end
	end, opts)
end

return M
