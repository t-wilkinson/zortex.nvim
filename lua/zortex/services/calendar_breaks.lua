-- services/calendar_breaks.lua - Short breaks inside a longer block
--
-- A timed line with an end (a duration, "12:00 Break @15m", or a range,
-- "12:00 - 12:15 Break") that starts while an earlier block is still on
-- interrupts it, and the block resumes when it ends:
--
--   10:00 Study                 10:00 - 14:00 Study
--   12:00 Break @15m              12:00 Break @15m
--   14:00 Gym
--
-- Both read "Study, a break at 12:00, Study again from 12:15". Flat (left),
-- the block is the latest earlier line still running (no end, or an end
-- after the break's); nested (right), the line it is under. The block
-- resumes until the next timed line starts (or its own end); when the next
-- line starts as the break ends, nothing resumes: that's a switch. A line
-- without an end starts something new. An @event without an end (an
-- appointment) is a moment, not a block, and a done or carried task isn't
-- resumed.
--
-- Over a day's own lines in file order (stores/calendar); the web app
-- (app/web calbreaks.go) reads them the same (tests/fixtures/calendar.json,
-- "resumes"). Notifications say "Back to Study" at the resume, the calendar
-- views show it ("↩ 12:15 Study"), and what's on now (the calendar's now
-- line, the web's time tracking) is the block again.
local M = {}

local function clock(t)
	return t and t.hour and (t.hour * 60 + (t.min or 0)) or nil
end

--- A day's own entries (CalendarEntry, file order, with depth from
--- stores/calendar.day_layout) as rows: { lnum, depth, start, stop, event,
--- closed, entry } (minutes after midnight; stop nil without an end).
function M.rows(entries)
	local out = {}
	for _, e in ipairs(entries) do
		if e.lnum and not e.feed and not e.rule then
			local start = clock(e:get_start_time())
			local stop = start and clock(e:get_end_time())
			if stop and stop <= start then
				stop = nil -- past midnight: no end today
			end
			out[#out + 1] = {
				lnum = e.lnum,
				depth = e.depth or 0,
				start = start,
				stop = stop,
				event = vim.tbl_contains(e.attributes.tags or {}, "event"),
				closed = e.completed or e.mark == ">",
				entry = e,
			}
		end
	end
	return out
end

--- The breaks of a day and what they resume: { block, after, from, to }
--- (rows; minutes; `to` nil: until the next thing, which isn't written
--- yet). `rows` in file order (M.rows).
function M.resumes(rows)
	local timed = {}
	for _, r in ipairs(rows) do
		if r.start then
			timed[#timed + 1] = r
		end
	end
	-- the timed line each one is nested under (the nearest shallower line
	-- above it, when that line is timed)
	local parent = {}
	local stack = {}
	for _, r in ipairs(rows) do
		while #stack > 0 and stack[#stack].depth >= r.depth do
			stack[#stack] = nil
		end
		local up = stack[#stack]
		if r.start and up and up.start then
			parent[r] = up
		end
		stack[#stack + 1] = r
	end
	local can_hold = function(b)
		return not (b.event and not b.stop)
	end
	local interrupts = {}
	-- flat: in time order, against the latest block still running
	local top = {}
	for _, r in ipairs(timed) do
		if not parent[r] then
			top[#top + 1] = r
		end
	end
	table.sort(top, function(a, b)
		if a.start ~= b.start then
			return a.start < b.start
		end
		return a.lnum < b.lnum
	end)
	local bg
	for _, e in ipairs(top) do
		if
			e.stop
			and bg
			and bg.start < e.start
			and (not bg.stop or (bg.stop > e.start and bg.stop >= e.stop))
		then
			interrupts[e] = bg
		elseif can_hold(e) then
			bg = e
		end
	end
	-- nested: under its block
	for _, e in ipairs(timed) do
		local p = parent[e]
		if p and e.stop and e.start >= p.start and (not p.stop or (p.stop > e.start and p.stop >= e.stop)) then
			interrupts[e] = p
		end
	end
	local out = {}
	for _, e in ipairs(timed) do
		local b = interrupts[e]
		if b and not b.closed and can_hold(b) then
			local to = b.stop
			for _, x in ipairs(timed) do
				if x ~= e and x ~= b and parent[x] ~= e and x.start > e.start and (not to or x.start < to) then
					to = x.start
				end
			end
			if not to or to > e.stop then
				out[#out + 1] = { block = b, after = e, from = e.stop, to = to }
			end
		end
	end
	return out
end

--- What is on at `now` (minutes): the row, or the block a break has
--- handed back to (its resume), whichever started last; nil before the
--- day's first timed line. A line still counts after its end, until the
--- next one starts (as the calendar's now line always has).
function M.current(rows, resumes, now)
	local best, best_at, best_resume
	for _, r in ipairs(rows) do
		if r.start and r.start <= now and (not best_at or r.start >= best_at) then
			best, best_at, best_resume = r, r.start, nil
		end
	end
	for _, res in ipairs(resumes) do
		if res.from <= now and (not res.to or now < res.to) and (not best_at or res.from >= best_at) then
			best, best_at, best_resume = res.block, res.from, res
		end
	end
	return best, best_resume
end

--- "HH:MM" of minutes after midnight.
function M.hhmm(minutes)
	return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

return M
