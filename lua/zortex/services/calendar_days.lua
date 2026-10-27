-- services/calendar_days.lua - Where the calendar note's days are, and where
-- a new one goes
--
-- A day is a date label ("**2026-10-21:**" or "2026-10-21:") and the lines
-- under it, up to the next day or the next heading. Days are grouped under
-- a heading per month ("# October 2026"; "## October 2026" under a "# Days"
-- heading; "2026-10" reads too): a new day goes into its month, next to its
-- nearest neighbour in time, and with grouping on (ui.calendar.group_days,
-- "month") a missing month heading is made, in month order.
--
-- Plain Lua over a list of lines (no buffers): stores/calendar,
-- services/planner and the server's app/edit (caldays.go) place days the
-- same way (tests/fixtures/caldays.json).
local M = {}

local datetime = require("zortex.utils.datetime")

M.MONTHS = {
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

local MONTH_OF = {}
for i, name in ipairs(M.MONTHS) do
	MONTH_OF[name:lower()] = i
	MONTH_OF[name:sub(1, 3):lower()] = i
end

local function is_fence(line)
	local t = line:match("^%s*(.-)%s*$")
	return t:sub(1, 3) == "```" or t:sub(1, 3) == "~~~"
end

local function blank(line)
	return not line:match("%S")
end

--- A Markdown heading: its level and text, or nil.
function M.heading(line)
	local hashes, text = line:match("^(#+)%s+(.-)%s*$")
	if hashes and #hashes <= 6 then
		return #hashes, text
	end
	return nil
end

--- A month heading ("# October 2026", "## Oct 2026", "# 2026-10"): its
--- "YYYY-MM" and level, or nil.
function M.month_heading(line)
	local level, text = M.heading(line)
	if not level then
		return nil
	end
	local y, m = text:match("^(%d%d%d%d)%-(%d%d)$")
	if y and tonumber(m) >= 1 and tonumber(m) <= 12 then
		return y .. "-" .. m, level
	end
	local name, year = text:match("^(%a+)%.?%s+(%d%d%d%d)$")
	local month = name and MONTH_OF[name:lower()]
	if month then
		return string.format("%s-%02d", year, month), level
	end
	return nil
end

--- The heading a new month gets: "# October 2026" (level 1).
function M.month_heading_line(ym, level)
	local y, m = ym:match("^(%d+)%-(%d+)$")
	return string.rep("#", level or 1) .. " " .. M.MONTHS[tonumber(m)] .. " " .. y
end

--- Does a day end at this line (another day, or a heading)?
function M.is_boundary(line)
	return datetime.date_heading(line) ~= nil or M.heading(line) ~= nil
end

-- One pass over the lines, outside code blocks: the day labels and the
-- headings, in order.
local function scan(lines)
	local marks = {}
	local fence = false
	for i, l in ipairs(lines) do
		if is_fence(l) then
			fence = not fence
		elseif not fence then
			local date = datetime.date_heading(l)
			if date then
				marks[#marks + 1] = { date = date, lnum = i }
			else
				local level, text = M.heading(l)
				if level then
					marks[#marks + 1] = { level = level, text = text, lnum = i }
				end
			end
		end
	end
	return marks
end

local function last_nonblank(lines, from, stop)
	local last = from
	for l = from + 1, stop do
		if not blank(lines[l]) then
			last = l
		end
	end
	return last
end

--- The days in file order: { date, heading, stop, last }. A day runs to
--- the line before the next day or heading (stop); last is its last
--- non-blank line.
function M.days(lines)
	local marks = scan(lines)
	local out = {}
	for i, mk in ipairs(marks) do
		if mk.date then
			local nxt = marks[i + 1]
			local stop = nxt and (nxt.lnum - 1) or #lines
			out[#out + 1] = { date = mk.date, heading = mk.lnum, stop = stop, last = last_nonblank(lines, mk.lnum, stop) }
		end
	end
	return out
end

-- The section a heading opens: to the line before the next heading of the
-- same or a higher level.
local function section_stop(marks, i, lines)
	local level = marks[i].level
	for j = i + 1, #marks do
		if marks[j].level and marks[j].level <= level then
			return marks[j].lnum - 1
		end
	end
	return #lines
end

--- The month headings in file order: { ym, level, heading, stop, last }.
function M.months(lines)
	local marks = scan(lines)
	local out = {}
	for i, mk in ipairs(marks) do
		if mk.level then
			local ym = M.month_heading(lines[mk.lnum])
			if ym then
				local stop = section_stop(marks, i, lines)
				out[#out + 1] = { ym = ym, level = mk.level, heading = mk.lnum, stop = stop, last = last_nonblank(lines, mk.lnum, stop) }
			end
		end
	end
	return out
end

--- The month (from M.months) whose section holds line `lnum`, or nil.
function M.month_containing(months, lnum)
	for _, m in ipairs(months) do
		if lnum > m.heading and lnum <= m.stop then
			return m
		end
	end
	return nil
end

-- A "# Days" heading (any level): { level, heading, stop }, or nil.
local function days_section(lines)
	local marks = scan(lines)
	for i, mk in ipairs(marks) do
		if mk.level and mk.text:lower() == "days" then
			return { level = mk.level, heading = mk.lnum, stop = section_stop(marks, i, lines) }
		end
	end
	return nil
end

--- The day a line belongs to: its { date, heading, stop, last }, or nil
--- (above the first day, in a heading's lines before any day).
function M.day_of(lines, lnum)
	for _, d in ipairs(M.days(lines)) do
		if lnum >= d.heading and lnum <= d.stop then
			return d
		end
	end
	return nil
end

local function day_number(date_str)
	local y, m, d = date_str:match("^(%d+)%-(%d+)%-(%d+)$")
	return math.floor(os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) / 86400)
end

-- Where a day goes among `days` (file order): with no later day, at
-- `fallback`; otherwise next to its nearest neighbour in time, right after
-- the closest earlier day (before the day after it) or right before the
-- closest later day when that one is nearer. A stray block elsewhere (a
-- far-future appointment near the top) doesn't pull today away from
-- yesterday. A day of the same date counts as earlier.
local function nearest(days, date_str, fallback)
	local target = day_number(date_str)
	local before_i, before_n, after_i, after_n
	for i, b in ipairs(days) do
		local n = day_number(b.date)
		if n <= target and (not before_n or n >= before_n) then
			before_i, before_n = i, n
		elseif n > target and (not after_n or n < after_n) then
			after_i, after_n = i, n
		end
	end
	if not after_i then
		return fallback
	end
	if before_i and (target - before_n) <= (after_n - target) then
		local next_day = days[before_i + 1]
		return next_day and next_day.heading or fallback
	end
	return days[after_i].heading
end

--- Where a new day goes: the line it is inserted before, and the month
--- heading to add above it (its text), if any.
--- opts.into_month: always under the month's heading (made when missing),
--- even when other days of the month aren't under one yet.
---@param opts { group?: "month"|false, into_month?: boolean }?
---@return integer at, string|nil month_line
function M.place(lines, date_str, opts)
	opts = opts or {}
	local ym = date_str:sub(1, 7)
	local all = M.days(lines)
	local months = M.months(lines)
	for _, m in ipairs(months) do
		if m.ym == ym then
			local inside = {}
			for _, d in ipairs(all) do
				if d.heading > m.heading and d.heading <= m.stop then
					inside[#inside + 1] = d
				end
			end
			return nearest(inside, date_str, m.stop + 1), nil
		end
	end
	if opts.group ~= "month" then
		return nearest(all, date_str, #lines + 1), nil
	end
	-- days of this month not under a month heading yet (a calendar from
	-- before grouping): the new day joins them; :ZortexCalendarGroup moves
	-- them all into their months
	local loose = {}
	for _, d in ipairs(opts.into_month and {} or all) do
		if d.date:sub(1, 7) == ym and not M.month_containing(months, d.heading) then
			loose[#loose + 1] = d
		end
	end
	if #loose > 0 then
		return nearest(loose, date_str, loose[#loose].stop + 1), nil
	end
	-- a new month: before the first later month, else after the last one
	local days_h = days_section(lines)
	local level = (months[1] and months[1].level) or (days_h and days_h.level + 1) or 1
	local later
	for _, m in ipairs(months) do
		if m.ym > ym and (not later or m.ym < later.ym) then
			later = m
		end
	end
	local at
	if later then
		at = later.heading
	elseif #months > 0 then
		at = months[#months].stop + 1
	elseif days_h then
		at = days_h.stop + 1
	elseif #all > 0 then
		at = all[#all].stop + 1
	else
		at = #lines + 1
	end
	return at, M.month_heading_line(ym, level)
end

--- The lines to insert for a new day, and where: { at, lines, heading }
--- (heading: the new day label's line once inserted). `body` goes under the
--- label; `label` replaces the "**YYYY-MM-DD:**" a new day gets.
---@param opts { group?: "month"|false, label?: string, into_month?: boolean }?
function M.insert_day(lines, date_str, body, opts)
	opts = opts or {}
	local at, month_line = M.place(lines, date_str, opts)
	local new = {}
	if month_line then
		new[#new + 1] = month_line
		new[#new + 1] = ""
	end
	local label_i = #new + 1
	new[#new + 1] = opts.label or datetime.date_heading_line(date_str)
	for _, l in ipairs(body or {}) do
		new[#new + 1] = l
	end
	new[#new + 1] = ""
	if at > #lines then
		at = #lines + 1
		if #lines > 0 and not blank(lines[#lines]) then
			table.insert(new, 1, "")
			label_i = label_i + 1
		end
		table.remove(new) -- no trailing blank at the end of the file
	elseif at > 1 and not blank(lines[at - 1]) then
		table.insert(new, 1, "") -- after a block whose last line isn't blank
		label_i = label_i + 1
	end
	return { at = at, lines = new, heading = at + label_i - 1 }
end

--- `lines` with `ins` (from insert_day) applied: a new list.
function M.apply(lines, ins)
	local out = {}
	for i = 1, ins.at - 1 do
		out[#out + 1] = lines[i]
	end
	for _, l in ipairs(ins.lines) do
		out[#out + 1] = l
	end
	for i = ins.at, #lines do
		out[#out + 1] = lines[i]
	end
	return out
end

-- Is day `d` under the heading of its own month?
local function in_own_month(d, months)
	local m = M.month_containing(months, d.heading)
	return m ~= nil and m.ym == d.date:sub(1, 7)
end

--- The calendar with every day under its month's heading (made when
--- missing, in month order): days not under their month are moved there,
--- one at a time in file order, each next to its nearest neighbour in
--- time. Days already in place, and everything that isn't a day (the
--- header, # Templates, # Repeating, other sections), stay as they are.
--- Returns the new lines and how many days moved.
function M.group(lines)
	local out = {}
	for i, l in ipairs(lines) do
		out[i] = l
	end
	local moved = 0
	local guard = #M.days(out) + 1
	while guard > 0 do
		guard = guard - 1
		local months = M.months(out)
		local day
		for _, d in ipairs(M.days(out)) do
			if not in_own_month(d, months) then
				day = d
				break
			end
		end
		if not day then
			break
		end
		local label = out[day.heading]
		local body = {}
		for l = day.heading + 1, day.last do
			body[#body + 1] = out[l]
		end
		-- cut the day and the blank lines after it
		local rest = {}
		for i = 1, day.heading - 1 do
			rest[#rest + 1] = out[i]
		end
		for i = day.stop + 1, #out do
			rest[#rest + 1] = out[i]
		end
		-- no blank line left dangling at the end
		while #rest > 0 and blank(rest[#rest]) do
			rest[#rest] = nil
		end
		out = M.apply(rest, M.insert_day(rest, day.date, body, { group = "month", label = label, into_month = true }))
		moved = moved + 1
	end
	return out, moved
end

return M
