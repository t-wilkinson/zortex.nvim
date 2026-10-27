-- features/calendar_time.lua - Times in the calendar note
--
--   :ZortexNow (<leader>zn)          today in the calendar, at the entry for now:
--                                    the latest one that started by now
--   :ZortexTimeShift 1h30m (<leader>z+ / <leader>z-, also on a selection)
--                                    move the times on the lines later
--                                    (or earlier, -15m): 12:00 -> 13:30
--
-- The times moved are the ones zortex reads as an entry's time: the one a
-- line starts with ("09:00 …", "- 09:00 …", "16:00 [ ] …"), a range
-- ("09:00 - 10:30 …") and @at(…) @from(…) @to(…). Times inside the text
-- ("John 3:16") stay. A line whose times would leave the day is left as is.
local M = {}

-- =============================================================================
-- Offsets
-- =============================================================================

--- Minutes from an offset: "1h30m", "1h30min", "1h 30m", "90m", "90min",
--- "90" (minutes), "1:30", "2h", "-15m", "+1h". nil when it isn't one.
function M.parse_offset(text)
	text = vim.trim(tostring(text or "")):lower()
	local sign = 1
	if text:sub(1, 1) == "-" then
		sign, text = -1, vim.trim(text:sub(2))
	elseif text:sub(1, 1) == "+" then
		text = vim.trim(text:sub(2))
	end
	if text == "" then
		return nil
	end
	if text:match("^%d+$") then
		return sign * tonumber(text)
	end
	local h, m = text:match("^(%d+):(%d%d)$")
	if h then
		return sign * (tonumber(h) * 60 + tonumber(m))
	end
	local total, rest = 0, text
	local any = false
	while rest ~= "" do
		local num, unit, after = rest:match("^(%d+%.?%d*)%s*([a-z]+)%s*(.*)$")
		if not num then
			return nil
		end
		local n = tonumber(num)
		if unit == "h" or unit == "hr" or unit == "hrs" or unit == "hour" or unit == "hours" then
			total = total + n * 60
		elseif unit == "m" or unit == "min" or unit == "mins" or unit == "minute" or unit == "minutes" then
			total = total + n
		else
			return nil
		end
		any, rest = true, after
	end
	if not any then
		return nil
	end
	return sign * math.floor(total + 0.5)
end

--- "1h30m", "-15m", "2h" for minutes.
function M.format_offset(minutes)
	local sign = minutes < 0 and "-" or ""
	minutes = math.abs(minutes)
	local h, m = math.floor(minutes / 60), minutes % 60
	if h > 0 and m > 0 then
		return string.format("%s%dh%dm", sign, h, m)
	elseif h > 0 then
		return string.format("%s%dh", sign, h)
	end
	return string.format("%s%dm", sign, m)
end

-- =============================================================================
-- Shifting the times on a line
-- =============================================================================

-- "9:05" + minutes -> "10:35"; keeps a one-digit hour one digit. nil when
-- the result leaves the day.
local function shift_time(h, m, minutes)
	local t = tonumber(h) * 60 + tonumber(m) + minutes
	if tonumber(h) > 23 or tonumber(m) > 59 or t < 0 or t >= 24 * 60 then
		return nil
	end
	local fmt = #h == 1 and "%d:%02d" or "%02d:%02d"
	return string.format(fmt, math.floor(t / 60), t % 60)
end

local ATTRS = { "at", "from", "to" }

--- `line` with its entry times moved by `minutes`: the new line and how many
--- times moved (0: nothing to move), or nil when one would leave the day.
function M.shift_line(line, minutes)
	local count, failed = 0, false
	local function shift(h, m)
		local t = shift_time(h, m, minutes)
		if not t then
			failed = true
			return h .. ":" .. m
		end
		count = count + 1
		return t
	end

	-- the time the line starts with, and the end of a range after it
	local lead, h1, m1, rest = line:match("^(%s*%-?%s*)(%d%d?):(%d%d)(.*)$")
	if lead and not rest:match("^%d") then
		local out = lead .. shift(h1, m1)
		local sep, h2, m2, after = rest:match("^(%s*%-%s*)(%d%d?):(%d%d)(.*)$")
		if sep and not after:match("^%d") then
			out = out .. sep .. shift(h2, m2)
			rest = after
		end
		line = out .. rest
	end

	-- @at(09:00), @from(2026-10-20 09:00), @to(10:30)
	for _, name in ipairs(ATTRS) do
		line = line:gsub("(@" .. name .. "%(([^)]-))(%d%d?):(%d%d)%)", function(open, _, h, m)
			return open .. shift(h, m) .. ")"
		end)
	end
	if failed then
		return nil, 0
	end
	return line, count
end

--- Move the times on lines l1..l2 of `bufnr` by `minutes`, as one change.
--- Returns how many lines changed and how many were left (out of the day).
function M.shift_lines(bufnr, l1, l2, minutes)
	bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
	local lines = vim.api.nvim_buf_get_lines(bufnr, l1 - 1, l2, false)
	local changed, skipped = 0, 0
	for i, line in ipairs(lines) do
		local new, n = M.shift_line(line, minutes)
		if not new then
			skipped = skipped + 1
		elseif n > 0 and new ~= line then
			lines[i] = new
			changed = changed + 1
		end
	end
	if changed > 0 then
		vim.api.nvim_buf_set_lines(bufnr, l1 - 1, l2, false, lines)
	end
	return changed, skipped
end

local last_offset = "1h"

--- Shift the times of the current line (or args.line1..args.line2) by
--- args.args, else by an offset asked for (the last one by default).
--- `direction` -1 moves them earlier.
function M.shift(args, direction)
	args = args or {}
	direction = direction or 1
	local l1 = args.line1 or vim.api.nvim_win_get_cursor(0)[1]
	local l2 = args.line2 or l1
	local function run(text)
		local minutes = M.parse_offset(text)
		if not minutes then
			return vim.notify("Not an offset: " .. tostring(text) .. " (1h30m, 45m, -15m)", vim.log.levels.WARN, { title = "Zortex" })
		end
		last_offset = vim.trim(text):gsub("^[+-]", "")
		local changed, skipped = M.shift_lines(0, l1, l2, minutes * direction)
		local msg = string.format(
			"Moved the times on %d line%s %s",
			changed,
			changed == 1 and "" or "s",
			minutes * direction < 0 and ("earlier by " .. M.format_offset(-minutes * direction)) or ("later by " .. M.format_offset(minutes * direction))
		)
		if skipped > 0 then
			msg = msg .. string.format(" · %d left as they were (they'd leave the day)", skipped)
		end
		vim.notify(msg, changed > 0 and vim.log.levels.INFO or vim.log.levels.WARN, { title = "Zortex" })
	end
	if args.args and vim.trim(args.args) ~= "" then
		return run(args.args)
	end
	vim.ui.input({ prompt = direction < 0 and "Earlier by: " or "Later by: ", default = last_offset }, function(text)
		if text and vim.trim(text) ~= "" then
			run(text)
		end
	end)
end

-- =============================================================================
-- Now
-- =============================================================================

--- The line of the day's entry for `now` ("HH:MM") among `lines` (the
--- calendar), in the day whose heading is at `heading`: the latest entry
--- that started by then (a range still running counts), or the block a
--- break has handed back to (services/calendar_breaks), else nil.
function M.line_for_time(lines, heading, now, date)
	local entries = require("zortex.services.calendar_entry")
	local own = {}
	for lnum = heading + 1, #lines do
		local line = lines[lnum]
		if require("zortex.services.calendar_days").is_boundary(line) then
			break
		end
		local entry = entries.from_text(line, date)
		if entry then
			entry.lnum = lnum
			own[#own + 1] = entry
		end
	end
	local breaks = require("zortex.services.calendar_breaks")
	local rows = breaks.rows(require("zortex.stores.calendar").day_layout(own))
	local h, m = now:match("^(%d+):(%d+)")
	if not h then
		return nil
	end
	local row = breaks.current(rows, breaks.resumes(rows), tonumber(h) * 60 + tonumber(m))
	return row and row.lnum or nil
end

--- Today in the calendar note, with the cursor on the entry for the time now.
function M.goto_now()
	local buf, heading = require("zortex.ui.planner").open_day(nil)
	if not buf then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local lnum = M.line_for_time(lines, heading, os.date("%H:%M"), os.date("%Y-%m-%d"))
	if lnum then
		vim.api.nvim_win_set_cursor(0, { lnum, 0 })
		vim.cmd("normal! zvzz")
	end
	return lnum
end

return M
