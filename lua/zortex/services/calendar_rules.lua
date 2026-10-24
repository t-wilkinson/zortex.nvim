-- services/calendar_rules.lua - The top of the calendar note: day templates
-- and repeating entries
--
-- Above the first day, the calendar note can have two sections (any heading
-- level; each runs to the next heading of its level or above, or to the
-- first day):
--
--   # Templates
--   Weekday:                 the lines a new day starts with, by its name:
--   Outcomes:                monday … sunday (mon … sun), weekday(s),
--   - [ ]                    weekend(s), daily; the most specific one wins
--   09:00                    (sunday over weekend over daily). Every line up
--   ## Sunday                to the next such name is the template, other
--   12:00 Weekly review      labels included. A name is a label ("Daily:")
--                            or a heading below # Templates ("## Daily").
--
--   # Repeating
--   ## Birthdays             headings, labels and plain lines organize it;
--   - Sam @on(03-14) @born(1990)              every item with @repeat(…)
--   - Dad @repeat(yearly) @born(1961-07-02)   or @on(…) is a rule, shown on
--   ## Routines                               the days it lands on:
--   - [ ] Weekly review @repeat(weekly) @on(sun) @at(12:00)
--   - [ ] Bins out @repeat(2w) @from(2026-10-06) @at(18:00)
--   - [ ] Pay rent @repeat(monthly) @on(1st)
--   - Book club @repeat(monthly) @on(last thu) @at(19:00)
--
-- @repeat(…) is how often, @on(…) which days, @at(…) what time:
--   daily · weekly · monthly · yearly · 2d / 3w / 6m / 2y (every n, counted
--   from @from(YYYY-MM-DD), or the date in @born(YYYY-MM-DD))
--   sun … sat, weekdays, weekends          on those days of the week
--   03-14                                  on that day every year
--   1, 15th                                on that day of every month
--   2nd tue, last fri, last                that weekday of the month (1st …
--                                          5th, last), the month's last day
-- Days may go in @repeat too ("@repeat(weekly, sun)", "@repeat(15)"), and
-- @on alone repeats on its days ("@on(weekdays)" is every weekday).
-- "2w sun" is every other Sunday from @from.
-- @from(YYYY-MM-DD) and @to(YYYY-MM-DD) bound it (both days included); a
-- @from or @to holding a time (@from(07:00)) is the entry's time, as on any
-- calendar line. @born(1990) adds the age to the text on the day: "Sam (36)".
--
-- The planner writes the repeating tasks due on a day into it when it opens
-- the day (ui.planner.repeating_tasks); the copy stands for the occurrence.
--
-- A repeating task isn't ticked in place: ticking it copies it, done, into
-- the day you did it (today), with @for(YYYY-MM-DD) when that isn't the day
-- it was due. The copy stands for that day's occurrence: on its own day the
-- copy shows instead, on another day the occurrence shows the copy's state.
-- zortex serve reads the same (app/web calrules.go; tests/fixtures/calendar.json).
local M = {}

local datetime = require("zortex.utils.datetime")

-- =============================================================================
-- Sections
-- =============================================================================

local SPECIAL = { templates = "templates", repeating = "repeating" }

local function fence(line)
	return line:match("^%s*```") or line:match("^%s*~~~")
end

--- The Templates and Repeating sections of the calendar's `lines`, above its
--- first day: { templates = { { first, last } }, repeating = { … } }.
function M.sections(lines)
	local out = { templates = {}, repeating = {} }
	local open
	local function close(last)
		if open then
			if last >= open.first then
				table.insert(out[open.kind], { first = open.first, last = last })
			end
			open = nil
		end
	end
	local in_code = false
	for lnum, line in ipairs(lines or {}) do
		if fence(line) then
			in_code = not in_code
		elseif not in_code then
			if datetime.date_heading(line) then
				close(lnum - 1)
				return out
			end
			local hashes, text = line:match("^(#+)%s+(.-)%s*$")
			if hashes then
				if open and #hashes <= open.level then
					close(lnum - 1)
				end
				local kind = not open and SPECIAL[text:lower()]
				if kind then
					open = { kind = kind, level = #hashes, first = lnum + 1 }
				end
			end
		end
	end
	close(#(lines or {}))
	return out
end

-- =============================================================================
-- Templates
-- =============================================================================

-- label -> { key, specificity }
local SELECTOR = {
	daily = { "daily", 1 },
	weekday = { "weekday", 2 },
	weekdays = { "weekday", 2 },
	weekend = { "weekend", 2 },
	weekends = { "weekend", 2 },
}
local DAY_NAMES = { "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" }
for _, name in ipairs(DAY_NAMES) do
	SELECTOR[name] = { name, 3 }
	SELECTOR[name:sub(1, 3)] = { name, 3 }
end

--- The template a line names ("Weekday:" or "## Weekday" -> "weekday"), or
--- nil.
function M.template_name(line)
	local name = line:match("^%s*(%a+):%s*$") or line:match("^#+%s+(%a+)%s*$")
	local sel = name and SELECTOR[name:lower()]
	return sel and sel[1] or nil
end

--- The templates of the calendar's `lines`: { [name] = { lines } }, each
--- without its leading and trailing blank lines and its common indent.
function M.templates(lines)
	local out = {}
	for _, r in ipairs(M.sections(lines).templates) do
		local cur
		for lnum = r.first, r.last do
			local line = lines[lnum]
			local name = M.template_name(line)
			if name then
				cur = {}
				out[name] = cur
			elseif cur then
				cur[#cur + 1] = line
			end
		end
	end
	for name, t in pairs(out) do
		while #t > 0 and not t[1]:match("%S") do
			table.remove(t, 1)
		end
		while #t > 0 and not t[#t]:match("%S") do
			table.remove(t)
		end
		local indent
		for _, l in ipairs(t) do
			if l:match("%S") then
				local w = #l:match("^%s*")
				indent = indent and math.min(indent, w) or w
			end
		end
		for i, l in ipairs(t) do
			t[i] = l:sub((indent or 0) + 1)
		end
		out[name] = t
	end
	return out
end

local function weekday_of(date)
	local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
	return os.date("*t", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })).wday
end

--- The template lines for a new day `date` ("YYYY-MM-DD") from the
--- calendar's `lines`: its weekday's, else weekday / weekend, else daily.
function M.template(lines, date)
	local t = M.templates(lines)
	local wday = weekday_of(date)
	local name = DAY_NAMES[wday]
	local group = (wday == 1 or wday == 7) and "weekend" or "weekday"
	return vim.deepcopy(t[name] or t[group] or t.daily or {})
end

-- =============================================================================
-- Repeat rules
-- =============================================================================

local WEEKDAY = {
	sun = 1, sunday = 1, mon = 2, monday = 2, tue = 3, tues = 3, tuesday = 3,
	wed = 4, wednesday = 4, thu = 5, thur = 5, thurs = 5, thursday = 5,
	fri = 6, friday = 6, sat = 7, saturday = 7,
}
local UNITS = { daily = "d", weekly = "w", monthly = "m", yearly = "y", annually = "y" }
-- "2nd tue": which weekday of the month (-1: the last)
local ORDINAL = {
	["1st"] = 1, first = 1, ["2nd"] = 2, second = 2, ["3rd"] = 3, third = 3,
	["4th"] = 4, fourth = 4, ["5th"] = 5, fifth = 5, last = -1,
}

--- @repeat(…) / @on(…)'s value -> { weekdays = set, dates = set ("MM-DD"),
--- monthdays = set, nth = set ("2:3" = 2nd Tuesday, "-1:6" = last Friday),
--- last_day?, unit?, n?, bad? }
function M.parse_spec(spec)
	local r = { weekdays = {}, dates = {}, monthdays = {}, nth = {} }
	local toks = {}
	for tok in tostring(spec or ""):lower():gmatch("[^,%s]+") do
		toks[#toks + 1] = tok
	end
	local i = 0
	while i < #toks do
		i = i + 1
		local tok = toks[i]
		local n, unit = tok:match("^(%d+)([dwmy])$")
		local md = tok:match("^(%d%d?)$") or tok:match("^(%d%d?)[snrt][tdh]$")
		local next_day = toks[i + 1] and WEEKDAY[toks[i + 1]]
		if ORDINAL[tok] and next_day then
			r.nth[ORDINAL[tok] .. ":" .. next_day] = true
			i = i + 1
		elseif tok == "last" then
			r.last_day = true
		elseif WEEKDAY[tok] then
			r.weekdays[WEEKDAY[tok]] = true
		elseif tok == "weekdays" or tok == "weekday" then
			for d = 2, 6 do
				r.weekdays[d] = true
			end
		elseif tok == "weekends" or tok == "weekend" then
			r.weekdays[1], r.weekdays[7] = true, true
		elseif tok:match("^%d%d%-%d%d$") then
			r.dates[tok] = true
		elseif md and tonumber(md) >= 1 and tonumber(md) <= 31 then
			r.monthdays[tonumber(md)] = true
		elseif UNITS[tok] then
			r.unit, r.n = UNITS[tok], 1
		elseif n and tonumber(n) > 0 then
			r.unit, r.n = unit, tonumber(n)
		else
			r.bad = true
		end
	end
	return r
end

local function days_in_month(y, m)
	return os.date("*t", os.time({ year = y, month = m + 1, day = 0, hour = 12 })).day
end

local function day_number(date)
	local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
	return math.floor(os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) / 86400)
end

--- Whether a rule (parse_spec, plus anchor/from/to dates) lands on
--- `date` ("YYYY-MM-DD").
function M.matches(rule, date)
	local r = rule.spec
	if not r or r.bad then
		return false
	end
	if (rule.from and date < rule.from) or (rule.to and date > rule.to) then
		return false
	end
	local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
	y, m, d = tonumber(y), tonumber(m), tonumber(d)
	local constrained = false
	if next(r.weekdays) then
		constrained = true
		if not r.weekdays[weekday_of(date)] then
			return false
		end
	end
	if next(r.dates) then
		constrained = true
		if not r.dates[date:sub(6)] then
			return false
		end
	end
	if next(r.monthdays) or r.last_day then
		constrained = true
		if not (r.monthdays[d] or (r.last_day and d == days_in_month(y, m))) then
			return false
		end
	end
	if next(r.nth) then
		constrained = true
		local wday = weekday_of(date)
		local from_end = d + 7 > days_in_month(y, m)
		if not (r.nth[math.ceil(d / 7) .. ":" .. wday] or (from_end and r.nth["-1:" .. wday])) then
			return false
		end
	end
	if not r.unit then
		return constrained
	end
	local anchor = rule.anchor
	if r.n == 1 and (constrained or r.unit == "d") then
		return true -- "weekly, Sunday", "monthly 15", "daily"
	end
	if not anchor or date < anchor then
		return false
	end
	local ay, am, ad = anchor:match("^(%d+)%-(%d+)%-(%d+)$")
	ay, am, ad = tonumber(ay), tonumber(am), tonumber(ad)
	local days = day_number(date) - day_number(anchor)
	if r.unit == "d" then
		return days % r.n == 0
	elseif r.unit == "w" then
		if constrained then
			return math.floor(days / 7) % r.n == 0
		end
		return days % (7 * r.n) == 0
	elseif r.unit == "m" then
		local months = (y - ay) * 12 + (m - am)
		return months % r.n == 0 and (constrained or d == ad)
	end
	return (y - ay) % r.n == 0 and (constrained or (m == am and d == ad))
end

local function attr(line, name)
	return line:match("@" .. name .. "%(([^)]*)%)")
end

-- Attributes that only describe the rule (dropped from its entries);
-- @from and @to only when they hold a date (DATE_ATTRS)
local RULE_ATTRS = { "repeat", "on", "born" }
local DATE_ATTRS = { "from", "to" }

local function date_of(v)
	return v and vim.trim(v):match("^(%d%d%d%d%-%d%d%-%d%d)$") or nil
end

-- The first @name(YYYY-MM-DD) on the line (a @from holding a time is skipped)
local function dated(line, name)
	for v in line:gmatch("@" .. name .. "%(([^)]*)%)") do
		local d = date_of(v)
		if d then
			return d
		end
	end
end

--- The rule on a line of the Repeating section (an item with @repeat(…)
--- or @on(…)), or nil: { lnum, line, spec, from?, to?, anchor?, born?
--- (year), bad_on? (@on holds how often, not days) }
function M.rule(line, lnum)
	local spec, on = attr(line, "repeat"), attr(line, "on")
	if not spec and not on then
		return nil
	end
	local born = attr(line, "born")
	local born_date = date_of(born)
	local rule = {
		lnum = lnum,
		line = line,
		spec = M.parse_spec((spec or "") .. "," .. (on or "")),
		bad_on = on and M.parse_spec(on).unit ~= nil or nil,
		from = dated(line, "from"),
		to = dated(line, "to"),
		born = born and tonumber(vim.trim(born):match("^(%d%d%d%d)")) or nil,
	}
	rule.anchor = rule.from or born_date
	return rule
end

--- Every rule of the calendar's `lines` (items with @repeat or @on in the
--- Repeating sections), in file order.
function M.rules(lines)
	local out = {}
	for _, r in ipairs(M.sections(lines).repeating) do
		local in_code = false
		for lnum = r.first, r.last do
			local line = lines[lnum]
			if fence(line) then
				in_code = not in_code
			elseif not in_code then
				local cls = require("zortex.core.syntax").classify(line)
				if cls.kind == "item" then
					local rule = M.rule(line, lnum)
					if rule then
						out[#out + 1] = rule
					end
				end
			end
		end
	end
	return out
end

-- Whether a spec needs a first day: every n (2w, 3d), or a bare weekly /
-- monthly / yearly with no day to land on
local function needs_anchor(spec)
	if not spec.unit then
		return false
	end
	local constrained = next(spec.weekdays) or next(spec.dates) or next(spec.monthdays) or next(spec.nth) or spec.last_day
	return not (spec.n == 1 and (constrained or spec.unit == "d"))
end

--- What is wrong with the calendar's repeating entries, for diagnostics:
--- { { lnum, col (0-based), end_col, message } }. A rule has @repeat(how
--- often) and/or @on(which days), and may have @from(first day) and
--- @to(last day); every n needs @from (or @born). @repeat and @on anywhere
--- else are not read.
function M.problems(lines)
	local out = {}
	local function add(lnum, pattern, message)
		local s, e = lines[lnum]:find(pattern)
		out[#out + 1] = { lnum = lnum, col = (s or 1) - 1, end_col = e or #lines[lnum], message = message }
	end
	local in_rules = {}
	for _, r in ipairs(M.rules(lines)) do
		in_rules[r.lnum] = true
		local line = r.line
		local which = attr(line, "repeat") and "@repeat%b()" or "@on%b()"
		if r.bad_on then
			add(r.lnum, "@on%b()", "@on takes days (mon, weekdays, 15th, 03-14, 2nd tue, last fri); how often goes in @repeat")
		elseif r.spec.bad then
			add(r.lnum, which, "Not a repeat: daily, weekly, 2w, mon, weekdays, 03-14, 15th, 2nd tue, last")
		elseif needs_anchor(r.spec) and not r.anchor then
			add(r.lnum, "@repeat%b()", "Every n counts from a first day: add @from(YYYY-MM-DD)")
		end
		if r.from and r.to and r.to < r.from then
			add(r.lnum, "@to%b()", "@to is before @from: it never shows")
		end
		for _, old in ipairs({ { "since", "from" }, { "until", "to" } }) do
			if line:find("@" .. old[1] .. "(", 1, true) then
				add(r.lnum, "@" .. old[1] .. "%b()", string.format("@%s is now @%s", old[1], old[2]))
			end
		end
	end
	local in_code = false
	for lnum, line in ipairs(lines) do
		if fence(line) then
			in_code = not in_code
		elseif not in_code and not in_rules[lnum] then
			for _, name in ipairs({ "repeat", "on" }) do
				if line:find("@" .. name .. "(", 1, true) then
					add(lnum, "@" .. name .. "%b()", "@" .. name .. " is read only in the # Repeating section")
				end
			end
		end
	end
	-- stable: problems of one line keep the order they were found in
	for i, p in ipairs(out) do
		p.order = i
	end
	table.sort(out, function(a, b)
		if a.lnum ~= b.lnum then
			return a.lnum < b.lnum
		end
		return a.order < b.order
	end)
	for _, p in ipairs(out) do
		p.order = nil
	end
	return out
end

--- The rule's line as a day's line: no indent, no rule attributes.
function M.plain_line(line)
	line = vim.trim(line)
	for _, name in ipairs(RULE_ATTRS) do
		line = line:gsub("%s*@" .. name .. "%b()", "")
	end
	for _, name in ipairs(DATE_ATTRS) do
		line = line:gsub("%s*@" .. name .. "%(%s*%d%d%d%d%-%d%d%-%d%d%s*%)", "")
	end
	return line
end

--- The line ticking the occurrence of `rule` on `date` writes into the day
--- `today`: the task, done today (and given an @id: `id`, or a new one),
--- with @for(date) when that isn't today.
function M.done_copy(rule, date, today, id)
	local line = require("zortex.services.tasks").edit_line(M.plain_line(rule.line), "done", { today = today, id = id })
	if line and date ~= today then
		line = line .. " @for(" .. date .. ")"
	end
	return line
end

--- "Sam" -> "Sam (36)" on `date` for a rule with @born.
function M.label(rule, text, date)
	if rule.born then
		local age = tonumber(date:sub(1, 4)) - rule.born
		if age >= 0 then
			return string.format("%s (%d)", text, age)
		end
	end
	return text
end

return M
