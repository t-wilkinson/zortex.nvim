-- ui/planner.lua - Plan a day: calendar on the left, candidates on the right
--
-- :ZortexPlan [YYYY-MM-DD] (default today)
--   1. opens calendar.zortex at the day, creating it from the day's template
--      (ui.planner.templates: weekday / saturday / sunday / monday ...), and
--      carries the open tasks of the days before to it (the old lines marked
--      [>]; ui.planner.carry_forward, :ZortexCarryForward)
--   2. opens zortex://plan beside it: projects, each with its ranked tasks
--      under a "## <project link>" heading; key results; to-dos (the TODO
--      project, the Projects note's own tasks, calendar tasks left open);
--      areas; what is left in the inbox.
--
-- Two ways to put a project task on the day (services/mirrors):
--   a copy      "- [ ] [P/#1.4 - zortex/-Improve website] @id(aB3x9)" (p, P):
--               its own checkbox and the task's @id; checking either checks
--               both, XP is paid once. Under the day's block for its project
--               ("09:00 [P/#1.4 - zortex]") it is "[./-Improve website]".
--   a reference "09:00 Improve website [P/…/-Improve website]" (<CR>, i, o):
--               no checkbox; it shows the task's state and toggling it
--               toggles the task. A timed line can't hold a checkbox, so
--               this is the way to give a task a time.
--
-- In the plan buffer:
--   p          add it to the day: a task as a copy (under its project's block
--              when the day has one), anything else as "- text"; stay here
--              (walk the list adding what you want)
--   P          on a project (or a task): a block for the project with its
--              next open tasks copied under it (ui.planner.project_tasks,
--              default 3; 5P for five)
--   i / o / O  put the text on the current / next / previous calendar line
--              (no marker added) and jump there in insert mode at the start of
--              the line, ready to type a time ("09:00 ")
--   <CR>       put the text at the calendar cursor (single spaces around it;
--              never inside a "09:00" or "- " marker; "- text" on a blank line)
--   <C-n> <C-p> move the calendar cursor down / up
--   <Tab>      go to the calendar window
--   gx / K     follow / preview the link on the line
--   r          refresh   q  close   ?  these keys
local M = {}

local planner = require("zortex.services.planner")
local datetime = require("zortex.utils.datetime")

local BUF_NAME = "zortex://plan"
local NS = vim.api.nvim_create_namespace("zortex_planner")

local state = { buf = nil, win = nil, cal_win = nil, cal_buf = nil, date = nil, items = {} }

local function cfg()
	return (require("zortex.config").ui or {}).planner or {}
end

-- =============================================================================
-- Rendering
-- =============================================================================

--- Lines, badges and line -> candidate map for a candidates table:
---   # Coming up    the events of the next ui.planner.upcoming_days days
---                  (agenda.upcoming_events), to plan around
---   # Projects     a "## <project link>" heading per project, its ranked
---                  tasks under it; under a project a key result links,
---                  folded, its other open tasks and each sub-project
---                  ("### <link>") with its own (the 4th return value:
---                  the folds, { first, last } line ranges)
---   # Key results
---   # Tasks        to-dos: the TODO project, the Projects note's own tasks,
---                  open calendar tasks of earlier days
---   # Areas
---   # Inbox        what is left in inbox.zortex (when anything is)
function M.render(candidates, date)
	local lines, badges, items, folds = {}, {}, {}, {}
	local function add(text, c, b)
		lines[#lines + 1] = text
		items[#lines] = c
		badges[#lines] = table.concat(b or (c and c.badges) or {}, " · ")
	end
	local function section(title, list)
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("# %s (%d)", title, #list)
		for _, c in ipairs(list) do
			add(c.text, c)
		end
	end
	add("@@Plan " .. (date or ""), nil, {
		candidates.focus_week and ("focus: " .. candidates.focus_week) or "no focus projects picked (:ZortexReview week)",
		"? keys",
	})
	if candidates.capacity_line then
		add(candidates.capacity_line, nil, candidates.capacity_badges)
	end

	-- the events of the coming days, to plan around (not put on the day)
	local upcoming = candidates.upcoming or {}
	if #upcoming > 0 then
		local days = cfg().upcoming_days or 7
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("# Coming up (next %d day%s)", days, days == 1 and "" or "s")
		for _, day in ipairs(upcoming) do
			local t = os.time({ year = tonumber(day.date:sub(1, 4)), month = tonumber(day.date:sub(6, 7)), day = tonumber(day.date:sub(9, 10)), hour = 12 })
			for i, item in ipairs(day.items) do
				local when = i == 1 and os.date("%a %m-%d", t) or string.rep(" ", 9)
				local e = item.entry and item.entry.timing and item.entry.timing["end"]
				local ends = type(e) == "table" and e.hour and string.format("–%02d:%02d", e.hour, e.min or 0) or ""
				local text = (item.time and (item.time .. ends .. " ") or "") .. item.text
				add(string.format("%s  %s", when, text), nil, {})
			end
		end
	end

	local groups = candidates.groups or {}
	lines[#lines + 1] = ""
	lines[#lines + 1] = string.format("# Projects (%d)", #groups)
	for i, g in ipairs(groups) do
		if i > 1 then
			lines[#lines + 1] = ""
		end
		-- its tasks are listed: no "next: …" badge
		add("## " .. g.project.text, g.project, #g.tasks > 0 and vim.tbl_filter(function(b)
			return not b:find("^next: ")
		end, g.project.badges or {}) or nil)
		for _, t in ipairs(g.tasks) do
			-- the project is the heading: leave its name out of the badges
			add(t.text, t, vim.tbl_filter(function(b)
				return b ~= t.project_name
			end, t.badges or {}))
		end
		-- a project a key result links: the rest of its tree, folded (zo)
		local open = {} -- open sections: { depth, start }
		local function close_to(depth)
			while #open > 0 and open[#open].depth >= depth do
				local o = table.remove(open)
				folds[#folds + 1] = { o.start, #lines }
			end
		end
		for _, sec in ipairs(g.more or {}) do
			close_to(sec.depth)
			local hashes = string.rep("#", math.min(6, 2 + sec.depth))
			local title = sec.own and string.format("More of this project (%d)", #sec.tasks) or sec.project.text
			add(hashes .. " " .. title, not sec.own and sec.project or nil, not sec.own and sec.project.badges or {})
			open[#open + 1] = { depth = sec.depth, start = #lines }
			for _, t in ipairs(sec.tasks) do
				add(t.text, t, {})
			end
		end
		close_to(1)
	end
	section("Key results", candidates.key_results or {})
	section("Tasks", candidates.todos or {})
	section("Areas", candidates.areas or {})
	if candidates.inbox and #candidates.inbox > 0 then
		section("Inbox", candidates.inbox)
	end
	return lines, badges, items, folds
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

--- The window showing the calendar beside the plan, or nil (closed, or now
--- showing something else).
local function calendar_window()
	local win = state.cal_win
	if win and vim.api.nvim_win_is_valid(win) and win ~= state.win and vim.api.nvim_win_get_buf(win) == state.cal_buf then
		return win
	end
	return nil
end

local function current_item()
	return state.items[vim.api.nvim_win_get_cursor(0)[1]]
end

local function is_task(item)
	return item.kind == "task" and item.link and item.file and item.lnum
end

--- Put the candidate under the cursor at the calendar cursor.
function M.put()
	local item = current_item()
	local win = calendar_window()
	if not item or not win then
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local row, col = unpack(vim.api.nvim_win_get_cursor(win))
	local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
	local new, end_col = planner.put(line, col, item.text)
	require("zortex.core.workspace").set_line(buf, row, new)
	vim.api.nvim_win_set_cursor(win, { row, math.max(0, end_col) })
	M.update_capacity()
	if cfg().advance then
		local last = vim.api.nvim_buf_line_count(buf)
		vim.api.nvim_win_set_cursor(win, { math.min(row + 1, last), 0 })
	end
end

--- Put the candidate's text on the calendar line `where` ("current", "next"
--- or "previous" relative to the calendar cursor), without a marker, then go
--- there in insert mode at the start of the line to type a time.
function M.place(where)
	local item = current_item()
	local win = calendar_window()
	if not item or not win then
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local workspace = require("zortex.core.workspace")
	local row = vim.api.nvim_win_get_cursor(win)[1]
	local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
	local indent = line:match("^%s*")
	local target
	if where == "current" then
		target = row
		local new = line:find("%S") and (line:gsub("%s*$", "") .. " " .. item.text) or (indent .. item.text)
		workspace.set_line(buf, row, new)
	else
		target = where == "next" and row + 1 or row
		workspace.insert_lines(buf, target, { indent .. item.text })
	end
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_win_set_cursor(win, { target, #indent })
	vim.cmd("startinsert")
end

--- Add the candidate to the planned day; focus stays here. A task goes in
--- as a copy (under its project's block when the day has one), anything
--- else as "- text" after the day's last entry.
function M.append()
	local item = current_item()
	if not item or not state.date then
		return
	end
	if is_task(item) then
		local at, added = planner.add_task(state.date, item)
		local win = calendar_window()
		if at and win then
			vim.api.nvim_win_set_cursor(win, { at, 0 })
		end
		M.update_capacity()
		vim.api.nvim_echo({ { (added and "Added to " or "Already on ") .. state.date .. ": " .. item.text, "Comment" } }, false, {})
		return
	end
	local calendar = require("zortex.stores.calendar")
	local win = calendar_window()
	local buf = win and vim.api.nvim_win_get_buf(win) or require("zortex.utils.filesystem").get_calendar_file()
	local lines = require("zortex.core.workspace").get_lines(buf)
	local block = calendar.date_block(state.date, lines)
	if not block then
		calendar.ensure_date(state.date, planner.template(state.date))
		lines = require("zortex.core.workspace").get_lines(buf)
		block = calendar.date_block(state.date, lines)
	end
	local at = block.last_lnum + 1
	require("zortex.core.workspace").insert_lines(buf, at, { "- " .. item.text })
	if win then
		vim.api.nvim_win_set_cursor(win, { at, 0 })
	end
	M.update_capacity()
	vim.api.nvim_echo({ { "Added to " .. state.date .. ": " .. item.text, "Comment" } }, false, {})
end

--- Add the project of the candidate (a project, or a task's project) to the
--- planned day as a block with its next open tasks copied under it
--- (ui.planner.project_tasks, or a count: 5P).
function M.append_project()
	local item = current_item()
	if not item or not state.date or not item.project_key then
		return M.append()
	end
	local count = vim.v.count > 0 and vim.v.count or nil
	local at, added = planner.add_project(state.date, item, { count = count })
	local win = calendar_window()
	if at and win then
		vim.api.nvim_win_set_cursor(win, { at, 0 })
	end
	M.update_capacity()
	vim.api.nvim_echo({
		{ string.format("%s on %s: %d task%s added", item.project_link or item.text, state.date, added, added == 1 and "" or "s"), "Comment" },
	}, false, {})
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
	-- the keys: zortex.keys ("plan")
	require("zortex.keys").map(buf, "plan", {
		put = M.put,
		place_current = function()
			M.place("current")
		end,
		place_next = function()
			M.place("next")
		end,
		place_previous = function()
			M.place("previous")
		end,
		append = M.append,
		append_project = M.append_project,
		calendar_down = function()
			move_calendar(1)
		end,
		calendar_up = function()
			move_calendar(-1)
		end,
		calendar = function()
			local win = calendar_window()
			if win then
				vim.api.nvim_set_current_win(win)
			end
		end,
		follow = function()
			require("zortex.features.links").open_link()
		end,
		preview = function()
			require("zortex.features.preview").preview_link()
		end,
		refresh = function()
			M.refresh()
		end,
		close = function()
			M.close()
		end,
		help = function()
			require("zortex.ui.keyhelp").show("plan")
		end,
	})
	state.buf = buf
	return buf
end

local CAPACITY_LNUM = 2

local function capacity_line()
	local ok, c = pcall(planner.capacity, state.date)
	if not ok or not c then
		return nil, nil
	end
	local badges = {}
	if c.over > 0 then
		badges[1] = "more than fits: move some to another day"
	end
	return planner.capacity_line(c), badges
end

--- Redraw the capacity line only (after putting something on the day, or
--- an edit in the calendar).
function M.update_capacity()
	local buf = state.buf
	if not (buf and vim.api.nvim_buf_is_valid(buf) and state.date) then
		return
	end
	local text, b = capacity_line()
	if not text or vim.api.nvim_buf_line_count(buf) < CAPACITY_LNUM then
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, CAPACITY_LNUM - 1, CAPACITY_LNUM, false, { text })
	vim.bo[buf].modifiable = false
	state.badges = state.badges or {}
	state.badges[CAPACITY_LNUM] = table.concat(b or {}, " · ")
	paint(buf, state.badges)
end

function M.refresh()
	local buf = state.buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local candidates = planner.candidates({ today = state.date })
	candidates.capacity_line, candidates.capacity_badges = capacity_line()
	local lines, badges, items, folds = M.render(candidates, state.date)
	state.items, state.badges = items, badges
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	pcall(require("zortex.features.highlights").highlight_buffer, buf)
	paint(buf, badges)
	-- the rest of a key result's project, folded (manual folds, closed)
	if state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_buf(state.win) == buf then
		vim.api.nvim_win_call(state.win, function()
			vim.wo.foldmethod = "manual"
			vim.wo.foldenable = true
			vim.wo.foldlevel = 0
			vim.cmd("silent! normal! zE")
			table.sort(folds, function(a, b)
				return a[1] > b[1] -- inner (later-starting) folds first
			end)
			for _, f in ipairs(folds) do
				if f[2] > f[1] then
					vim.cmd(string.format("silent! %d,%dfold", f[1], f[2]))
				end
			end
			vim.cmd("silent! normal! zM")
		end)
	end
end

function M.close()
	if state.win and vim.api.nvim_win_is_valid(state.win) and #vim.api.nvim_list_wins() > 1 then
		vim.api.nvim_win_close(state.win, true)
	end
	state.win = nil
end

--- :ZortexToday [date] (<leader>zd): today's day in calendar.zortex, made
--- from the day's template (ui.planner.templates) when it isn't there yet,
--- opened in this window with the cursor on its first line. Unlike
--- :ZortexPlan it opens no candidate list and carries nothing forward.
--- Returns the calendar buffer and the day's heading line, or nil.
function M.open_day(date)
	date = (date and date ~= "") and date or os.date("%Y-%m-%d")
	local parsed = datetime.parse_date(date)
	if not parsed then
		vim.notify("Not a date: " .. tostring(date), vim.log.levels.ERROR, { title = "Zortex" })
		return nil
	end
	date = datetime.format_datetime(parsed, "YYYY-MM-DD")
	local calendar = require("zortex.stores.calendar")
	local heading, created = calendar.ensure_date(date, planner.template(date))
	if not heading then
		vim.notify("Couldn't add " .. date .. " to the calendar: " .. tostring(created), vim.log.levels.ERROR, { title = "Zortex" })
		return nil
	end
	-- the buffer as is: the day may have just been written into it unsaved
	-- (":edit" would stop at E37)
	local path = vim.fn.fnamemodify(require("zortex.utils.filesystem").get_calendar_file(), ":p")
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	vim.bo[buf].buflisted = true
	vim.api.nvim_win_set_buf(0, buf)
	if vim.bo[buf].filetype == "" then
		vim.bo[buf].filetype = "zortex"
	end
	-- the day's first line, or the heading when the day is empty
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local target = heading
	local next_line = lines[heading + 1]
	if next_line and next_line:match("%S") and not datetime.date_heading(next_line) then
		target = heading + 1
	end
	vim.api.nvim_win_set_cursor(0, { target, 0 })
	vim.cmd("normal! zvzt")
	if created then
		vim.notify("Added " .. date .. " to the calendar", vim.log.levels.INFO, { title = "Zortex" })
	end
	return buf, heading
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
	-- open tasks of the days before come along (today's plan only)
	if cfg().carry_forward ~= false and date == os.date("%Y-%m-%d") then
		local moved, added = planner.carry_forward(date, { days = cfg().carry_days })
		if added > 0 then
			vim.notify(string.format("Carried %d open task%s to today", added, added == 1 and "" or "s"), vim.log.levels.INFO, { title = "Zortex" })
		elseif moved > 0 then
			vim.notify(string.format("Marked %d task%s carried ([>])", moved, moved == 1 and "" or "s"), vim.log.levels.INFO, { title = "Zortex" })
		end
	end

	-- Calendar on the left, at the day. Its buffer is shown as is: the day
	-- and the carried tasks were just written into it when it is loaded, so
	-- ":edit" would stop at the unsaved changes (E37, or a "Save changes?"
	-- dialog with 'confirm'). The plan window never shows it.
	local path = vim.fn.fnamemodify(require("zortex.utils.filesystem").get_calendar_file(), ":p")
	local cal_buf = vim.fn.bufadd(path)
	vim.fn.bufload(cal_buf)
	vim.bo[cal_buf].buflisted = true
	local cal_win = calendar_window()
	if not cal_win or cal_win == state.win then
		local shown = vim.fn.bufwinid(cal_buf)
		cal_win = (shown ~= -1 and shown ~= state.win) and shown or nil
	end
	if cal_win then
		vim.api.nvim_set_current_win(cal_win)
	elseif state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_get_current_win() == state.win then
		-- run from the plan window: the calendar goes beside it, on the left
		vim.cmd("leftabove vsplit")
	end
	vim.api.nvim_win_set_buf(0, cal_buf)
	if vim.bo[cal_buf].filetype == "" then
		vim.bo[cal_buf].filetype = "zortex"
	end
	state.cal_win, state.cal_buf, state.date = vim.api.nvim_get_current_win(), cal_buf, date
	local last = vim.api.nvim_buf_line_count(state.cal_buf)
	vim.api.nvim_win_set_cursor(state.cal_win, { math.min(heading + 1, last), 0 })
	vim.cmd("normal! zvzt")
	-- editing the day by hand keeps the capacity line current
	local group = vim.api.nvim_create_augroup("ZortexPlanCapacity", { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
		group = group,
		buffer = state.cal_buf,
		callback = function()
			if state.buf and vim.api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) ~= -1 then
				M.update_capacity()
			end
		end,
	})

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
