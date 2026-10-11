-- ui/planner.lua - Plan a day: calendar on the left, candidates on the right
--
-- :ZortexPlan [YYYY-MM-DD] (default today)
--   1. opens calendar.zortex at the day, creating it from the day's template
--      (ui.planner.templates: weekday / saturday / sunday / monday ...)
--   2. opens zortex://plan beside it: ranked tasks (TODOs, priority, due,
--      OKR), projects, key results and areas. Every line is exactly what gets
--      written: the item's text and an explicit link to it.
--
-- In the plan buffer:
--   <CR> / p   put the line at the calendar cursor (single spaces around it;
--              never inside a "09:00" or "- " marker; "- text" on a blank line)
--   o          put it as a new entry below the calendar cursor
--   <C-n> <C-p> move the calendar cursor down / up
--   <Tab>      go to the calendar window
--   gx / K     follow / preview the link on the line
--   r          refresh   q  close
local M = {}

local planner = require("zortex.services.planner")

local BUF_NAME = "zortex://plan"
local NS = vim.api.nvim_create_namespace("zortex_planner")

local state = { buf = nil, win = nil, cal_win = nil, cal_buf = nil, date = nil, items = {} }

local function cfg()
	return (require("zortex.config").ui or {}).planner or {}
end

-- =============================================================================
-- Rendering
-- =============================================================================

local SECTIONS = {
	{ key = "tasks", title = "Tasks" },
	{ key = "projects", title = "Projects" },
	{ key = "key_results", title = "Key results" },
	{ key = "areas", title = "Areas" },
}

--- Lines, badges and line -> candidate map for a candidates table.
function M.render(candidates, date)
	local lines, badges, items = {}, {}, {}
	lines[#lines + 1] = "@@Plan " .. (date or "")
	for _, section in ipairs(SECTIONS) do
		local list = candidates[section.key] or {}
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("# %s (%d)", section.title, #list)
		for _, c in ipairs(list) do
			lines[#lines + 1] = c.text
			items[#lines] = c
			badges[#lines] = table.concat(c.badges or {}, " · ")
		end
	end
	return lines, badges, items
end

local function paint(buf, badges)
	vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
	for lnum, text in pairs(badges) do
		if text ~= "" then
			vim.api.nvim_buf_set_extmark(buf, NS, lnum - 1, 0, {
				virt_text = { { "  " .. text, "Comment" } },
				virt_text_pos = "eol",
			})
		end
	end
end

-- =============================================================================
-- Putting items into the calendar
-- =============================================================================

local function calendar_window()
	if state.cal_win and vim.api.nvim_win_is_valid(state.cal_win) then
		return state.cal_win
	end
	return nil
end

local function current_item()
	return state.items[vim.api.nvim_win_get_cursor(0)[1]]
end

--- Put the candidate under the cursor at the calendar cursor.
---@param below boolean? new entry line below instead
function M.put(below)
	local item = current_item()
	local win = calendar_window()
	if not item or not win then
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local row, col = unpack(vim.api.nvim_win_get_cursor(win))
	local workspace = require("zortex.core.workspace")
	if below then
		local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
		local indent = line:match("^%s*")
		local new, end_col = planner.put(indent, 0, item.text)
		workspace.insert_lines(buf, row + 1, { new })
		vim.api.nvim_win_set_cursor(win, { row + 1, end_col })
	else
		local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
		local new, end_col = planner.put(line, col, item.text)
		workspace.set_line(buf, row, new)
		vim.api.nvim_win_set_cursor(win, { row, math.max(0, end_col) })
		if cfg().advance then
			local last = vim.api.nvim_buf_line_count(buf)
			vim.api.nvim_win_set_cursor(win, { math.min(row + 1, last), 0 })
		end
	end
end

local function move_calendar(delta)
	local win = calendar_window()
	if not win then
		return
	end
	local row = vim.api.nvim_win_get_cursor(win)[1]
	local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
	vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(last, row + delta)), 0 })
end

-- =============================================================================
-- Buffer
-- =============================================================================

local function plan_buffer()
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		return state.buf
	end
	local buf = vim.fn.bufnr(BUF_NAME)
	if buf == -1 then
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, BUF_NAME)
	end
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Zortex plan: " .. desc })
	end
	map("<CR>", function()
		M.put(false)
	end, "put at the calendar cursor")
	map("p", function()
		M.put(false)
	end, "put at the calendar cursor")
	map("o", function()
		M.put(true)
	end, "put as a new entry below the calendar cursor")
	map("<C-n>", function()
		move_calendar(1)
	end, "calendar cursor down")
	map("<C-p>", function()
		move_calendar(-1)
	end, "calendar cursor up")
	map("<Tab>", function()
		local win = calendar_window()
		if win then
			vim.api.nvim_set_current_win(win)
		end
	end, "go to the calendar")
	map("gx", function()
		require("zortex.features.links").open_link()
	end, "follow link")
	map("K", function()
		require("zortex.features.preview").preview_link()
	end, "preview link")
	map("r", function()
		M.refresh()
	end, "refresh")
	map("q", function()
		M.close()
	end, "close")
	state.buf = buf
	return buf
end

function M.refresh()
	local buf = state.buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local lines, badges, items = M.render(planner.candidates({ today = state.date }), state.date)
	state.items = items
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	pcall(require("zortex.features.highlights").highlight_buffer, buf)
	paint(buf, badges)
end

function M.close()
	if state.win and vim.api.nvim_win_is_valid(state.win) and #vim.api.nvim_list_wins() > 1 then
		vim.api.nvim_win_close(state.win, true)
	end
	state.win = nil
end

--- Plan a day.
---@param opts { date?: string }?
function M.open(opts)
	opts = opts or {}
	local date = opts.date or os.date("%Y-%m-%d")
	local calendar = require("zortex.stores.calendar")
	local heading = calendar.ensure_date(date, planner.template(date))
	if not heading then
		vim.notify("Invalid date: " .. tostring(date), vim.log.levels.ERROR)
		return
	end

	-- Calendar on the left, at the day
	vim.cmd("edit " .. vim.fn.fnameescape(require("zortex.utils.filesystem").get_calendar_file()))
	state.cal_win, state.cal_buf, state.date = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf(), date
	local last = vim.api.nvim_buf_line_count(state.cal_buf)
	vim.api.nvim_win_set_cursor(state.cal_win, { math.min(heading + 1, last), 0 })
	vim.cmd("normal! zvzt")

	-- Candidates on the right
	local buf = plan_buffer()
	if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
		vim.cmd("rightbelow vsplit")
		state.win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_width(state.win, cfg().width or 70)
		vim.wo[state.win].wrap = false
		vim.wo[state.win].conceallevel = 2
	end
	vim.api.nvim_win_set_buf(state.win, buf)
	M.refresh()
	vim.api.nvim_set_current_win(state.win)
	return buf
end

-- Test hook
function M._state()
	return state
end

return M
