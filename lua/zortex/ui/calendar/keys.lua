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

--- x / 2x: tick (or reopen) task 2 of the listed day (the numbers before
--- its tasks); x alone picks one when there are several.
function M.toggle_task()
	local list = state().tasks or {}
	if #list == 0 then
		vim.notify("No tasks on this day", vim.log.levels.INFO)
		return
	end
	local function toggle(t)
		local res, err
		if t.occurrence then
			res, err = require("zortex.stores.calendar").complete_occurrence(t.occurrence, os.date("%Y-%m-%d"))
		else
			res, err = require("zortex.services.tasks").toggle_at(t.file, t.lnum)
		end
		if not res then
			vim.notify("Can't toggle: " .. tostring(err), vim.log.levels.WARN)
		end
		require("zortex.stores.calendar").load()
		view().refresh()
	end
	local n = vim.v.count
	if n > 0 then
		if not list[n] then
			return vim.notify("No task " .. n .. " on this day", vim.log.levels.WARN)
		end
		return toggle(list[n])
	end
	if #list == 1 then
		return toggle(list[1])
	end
	vim.ui.select(list, {
		prompt = "Tick which task?",
		format_item = function(t)
			return t.text
		end,
	}, function(t)
		if t then
			toggle(t)
		end
	end)
end

function M.show_help()
	require("zortex.ui.keyhelp").show("calendar")
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
		go_to_file = M.go_to_file,
		toggle_task = M.toggle_task,
		sync_notifications = M.sync_notifications,
		help = M.show_help,
		refresh = function()
			view().refresh()
		end,
		close = function()
			view().close()
		end,
	}

	-- descriptions from the key table (zortex.keys), keys from the config
	local desc = {}
	for _, k in ipairs(require("zortex.keys").def("calendar").keys) do
		desc[k[2]] = k[3]
	end
	for action, func in pairs(keymap_actions) do
		local keys = cfg.keymaps[action]
		if keys then
			for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
				vim.keymap.set("n", key, func, vim.tbl_extend("force", opts, { desc = "Zortex calendar view: " .. (desc[action] or action) }))
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
