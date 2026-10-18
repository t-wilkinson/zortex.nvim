-- ui/calendar/view.lua - The calendar window
--
-- A floating window with a month grid, the selected day's entries and the
-- events coming up after it below. Content comes from ui/calendar/render,
-- keys from ui/calendar/keys; this module owns the window and its state.
local M = {}
local api = vim.api

local datetime = require("zortex.utils.datetime")
local calendar_store = require("zortex.stores.calendar")
local render = require("zortex.ui.calendar.render")

local CalendarState = {
	bufnr = nil,
	win_id = nil,
	current_date = nil,
	marks = {}, -- marks[date_str] = { line, col, end_col, day }: day cells (display columns)
	ns_id = nil, -- Namespace for extmarks
	selected_extmark_id = nil, -- Current selection extmark
}
M.state = CalendarState

-- Config.ui.calendar (setup)
local cfg = {}

-- =============================================================================
-- Window
-- =============================================================================

local function create_buffer()
	local bufnr = api.nvim_create_buf(false, true)
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	api.nvim_buf_set_name(bufnr, "Zortex Calendar")
	return bufnr
end

local function create_window(bufnr)
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
	vim.wo[win_id].number = false
	vim.wo[win_id].relativenumber = false
	vim.wo[win_id].signcolumn = "no"
	vim.wo[win_id].wrap = false
	vim.wo[win_id].cursorline = false
	vim.wo[win_id].winhl = "Normal:Normal,FloatBorder:" .. cfg.colors.border
	return win_id
end

local function apply_highlights(bufnr, highlights)
	local ns_id = CalendarState.ns_id or api.nvim_create_namespace("zortex_calendar")

	for _, hl in ipairs(highlights) do
		api.nvim_buf_add_highlight(bufnr, ns_id, hl.hl, hl.line - 1, hl.col, hl.end_col)
	end
end

-- Highlight the selected day cell
local function update_selected_extmark()
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

	-- Marks are in *display* columns; extmarks need *byte* columns. Wide icons
	-- take two display columns but one character, so convert by width.
	local line_txt = vim.api.nvim_buf_get_lines(CalendarState.bufnr, mark.line - 1, mark.line, false)[1] or ""
	local byte_start = render.display_col_to_byte(line_txt, mark.col)
	local byte_end = render.display_col_to_byte(line_txt, mark.end_col)

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
-- Public API
-- =============================================================================

function M.open()
	calendar_store.load()

	if CalendarState.win_id and api.nvim_win_is_valid(CalendarState.win_id) then
		api.nvim_set_current_win(CalendarState.win_id)
		return
	end

	CalendarState.bufnr = create_buffer()
	CalendarState.win_id = create_window(CalendarState.bufnr)
	CalendarState.ns_id = api.nvim_create_namespace("zortex_calendar")

	if not CalendarState.current_date then
		CalendarState.current_date = datetime.get_current_date()
	end

	require("zortex.ui.calendar.keys").attach(CalendarState.bufnr, cfg)
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

	local win_width = CalendarState.win_id and api.nvim_win_get_width(CalendarState.win_id) or cfg.window.width
	local date = CalendarState.current_date or datetime.get_current_date()
	lines, highlights, CalendarState.marks = render.month(date, CalendarState, cfg, win_width)

	vim.bo[CalendarState.bufnr].modifiable = true
	api.nvim_buf_set_lines(CalendarState.bufnr, 0, -1, false, lines)
	vim.bo[CalendarState.bufnr].modifiable = false
	-- Clear all highlights and extmarks
	api.nvim_buf_clear_namespace(CalendarState.bufnr, CalendarState.ns_id, 0, -1)

	-- The namespace clear destroyed all extmarks. We must nil out the old ID
	-- so update_selected_extmark() doesn't accidentally delete a newly created highlight
	-- that inherited the recycled ID.
	CalendarState.selected_extmark_id = nil

	-- Apply highlights
	apply_highlights(CalendarState.bufnr, highlights)

	-- Update selected date extmark
	update_selected_extmark()
end

function M.setup(opts)
	cfg = opts
end

return M
