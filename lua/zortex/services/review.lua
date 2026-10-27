-- services/review.lua - The reviews note: one entry per week, its days inside
--
-- Reviews are written in one note, reviews.zortex (@@Reviews), newest first:
--
--   @@Reviews
--
--   # 2026-W43
--   Focus:
--   - [P/#3 Car/#3.1 Rebuild the engine]
--   - [P/#2 School/#2.1 Signals and systems]
--   Wins:
--   Lessons:
--
--   ## 2026-10-21
--   Done:
--   Blocked:
--   First thing tomorrow:
--
-- :ZortexReview opens the week's entry (made from its template when it is
-- missing) next to the generated findings (ui/review); :ZortexReview day the
-- day's entry under the week it falls in. What you write stays yours:
-- nothing in the note is regenerated.
--
-- The templates are the note's own, in a "# Templates" section (a new note
-- starts with one, from review.week and review.day):
--
--   # Templates
--   ## Weekly                 a new week's lines
--   Focus:
--   Wins:
--   ## Daily                  a new day's lines
--   Done:
--
-- Without one (or without one of the two), review.week / review.day.
--
-- The week's **focus** is the projects linked under its "Focus:" label.
-- The planner ranks their tasks first (services/planner, weights.focus).
-- A week without focus projects keeps the latest earlier week's.
--
--   week_of(date)              -> "2026-W43", monday, sunday
--   review_week(today)         -> the week a weekly review on `today` plans:
--                                 this one, or the next from review.next_week_from
--   entries(lines)             -> { weeks = { [week] = entry }, order = { week, ... } }
--   focus(date)                -> { week, projects, from_earlier } or nil
--   week_focus(week)           -> that week's focus projects (no fallback)
--   ensure_week(week)          -> line of "# <week>" (made when missing)
--   ensure_day(date)           -> line of "## <date>" (made when missing)
--   toggle_focus(week, project) -> true when added, false when removed
local M = {}

local WEEK_HEADING = "^#%s+(%d%d%d%d%-W%d%d)%f[^%w]"
local DAY_HEADING = "^##%s+(%d%d%d%d%-%d%d%-%d%d)%f[^%w]"
local FOCUS_LABEL = "^(%s*)[Ff]ocus:%s*$"

local WEEKDAYS = { sunday = 7, monday = 1, tuesday = 2, wednesday = 3, thursday = 4, friday = 5, saturday = 6 }

local function cfg()
	return require("zortex.config").review or {}
end

local function workspace()
	return require("zortex.core.workspace")
end

--- Path of the reviews note.
function M.path()
	return require("zortex.utils.filesystem").get_reviews_file()
end

-- =============================================================================
-- Weeks
-- =============================================================================

local DAY = 86400

local function time_of(date_str)
	local y, m, d = date_str:match("^(%d+)%-(%d+)%-(%d+)")
	return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

local function iso_weekday(t)
	return (os.date("*t", t).wday + 5) % 7 + 1 -- Monday 1 .. Sunday 7
end

--- The ISO week of a date: "2026-W43", and its Monday and Sunday.
function M.week_of(date_str)
	local t = time_of(date_str)
	local wd = iso_weekday(t)
	local thursday = os.date("*t", t + (4 - wd) * DAY)
	local week = math.floor((thursday.yday - 1) / 7) + 1
	local monday = t - (wd - 1) * DAY
	return string.format("%d-W%02d", thursday.year, week), os.date("%Y-%m-%d", monday), os.date("%Y-%m-%d", monday + 6 * DAY)
end

--- The week a weekly review held on `today` plans: this week, or the next
--- one from review.next_week_from (default Saturday) on.
function M.review_week(today)
	today = today or os.date("%Y-%m-%d")
	local from = cfg().next_week_from or "saturday"
	from = type(from) == "string" and WEEKDAYS[from:lower()] or tonumber(from) or 6
	local t = time_of(today)
	local wd = iso_weekday(t)
	if wd >= from then
		return (M.week_of(os.date("%Y-%m-%d", t + (8 - wd) * DAY)))
	end
	return (M.week_of(today))
end

-- =============================================================================
-- Reading the note
-- =============================================================================

local function classify(line)
	return require("zortex.core.syntax").classify(line)
end

--- Week entries of the reviews note:
---   weeks[week] = { week, lnum, last (its last line), own_end (before its
---                   first day), days = { [date] = lnum },
---                   focus = { lnum, from, to } (the label and its lines) }
---   order       = weeks as they appear (newest first, normally)
function M.entries(lines)
	local weeks, order = {}, {}
	local cur
	local fence = false
	for lnum, line in ipairs(lines) do
		local t = vim.trim(line)
		if t:sub(1, 3) == "```" or t:sub(1, 3) == "~~~" then
			fence = not fence
		elseif not fence then
			local wk = line:match(WEEK_HEADING)
			if wk then
				if cur then
					cur.last = lnum - 1
				end
				cur = { week = wk, lnum = lnum, days = {}, own_end = nil }
				if not weeks[wk] then
					weeks[wk] = cur
					order[#order + 1] = wk
				end
			elseif line:match("^#%s") then
				-- another top-level heading ends the week
				if cur then
					cur.last = lnum - 1
					cur = nil
				end
			elseif cur then
				local day = line:match(DAY_HEADING)
				if day then
					cur.days[day] = cur.days[day] or lnum
					cur.own_end = cur.own_end or (lnum - 1)
				end
			end
		end
	end
	if cur then
		cur.last = #lines
	end
	for _, e in pairs(weeks) do
		e.last = e.last or #lines
		e.own_end = e.own_end or e.last
		-- the Focus label and the lines under it (to the next section)
		for l = e.lnum + 1, e.own_end do
			local indent = lines[l]:match(FOCUS_LABEL)
			if indent then
				local to = l
				for k = l + 1, e.own_end do
					local c = classify(lines[k])
					if c.section and (c.kind ~= "label" or (c.indent or 0) <= #indent) then
						break
					end
					if lines[k]:find("%S") then
						to = k
					end
				end
				e.focus = { lnum = l, from = l + 1, to = to }
				break
			end
		end
	end
	return { weeks = weeks, order = order }
end

-- A focus line's link: the project's link, "[P/#1 Programming/#1.4 - zortex]"
local function focus_link(project)
	return require("zortex.services.planner").shown(project.name, project.link)
end

-- The project a line links (its first link that resolves to one)
local function project_on(lines, lnum)
	local link = require("zortex.core.link")
	local projects = require("zortex.services.projects")
	for _, span in ipairs(link.links_on(lines[lnum])) do
		local def = link.absolute(span.definition, lines, lnum)
		if def then
			local ok, list = pcall(projects.for_link, "[" .. def .. "]")
			if ok and list[1] then
				return list[1]
			end
		end
	end
	return nil
end

--- The projects under a week entry's Focus label, in order (with the
--- lines they are on: { project, lnum }).
function M.focus_lines(lines, e)
	local out, seen = {}, {}
	if not (e and e.focus) then
		return out
	end
	for l = e.focus.from, e.focus.to do
		local p = lines[l]:find("[", 1, true) and project_on(lines, l)
		if p and not seen[p.key] then
			seen[p.key] = true
			out[#out + 1] = { project = p, lnum = l }
		end
	end
	return out
end

local function lines_of_note()
	local path = M.path()
	if not path then
		return {}
	end
	return workspace().get_lines(path)
end

--- This week's focus projects (the week `date` is in): { week, projects,
--- from_earlier }, from_earlier when the week has none and an earlier
--- week's are used. nil when no week has any.
function M.focus(date)
	date = date or os.date("%Y-%m-%d")
	local want = M.week_of(date)
	local lines = lines_of_note()
	if #lines == 0 then
		return nil
	end
	local data = M.entries(lines)
	local weeks = vim.tbl_keys(data.weeks)
	table.sort(weeks, function(a, b)
		return a > b
	end)
	for _, wk in ipairs(weeks) do
		if wk <= want then
			local found = M.focus_lines(lines, data.weeks[wk])
			if #found > 0 then
				local projects = {}
				for _, x in ipairs(found) do
					projects[#projects + 1] = x.project
				end
				return { week = wk, projects = projects, from_earlier = wk ~= want }
			end
		end
	end
	return nil
end

--- The projects under exactly this week's Focus label (no fallback).
function M.week_focus(week)
	local lines = lines_of_note()
	local e = #lines > 0 and M.entries(lines).weeks[week] or nil
	local out = {}
	for _, x in ipairs(M.focus_lines(lines, e)) do
		out[#out + 1] = x.project
	end
	return out
end

-- =============================================================================
-- Writing entries
-- =============================================================================

local DEFAULT_WEEK = { "Focus:", "", "Wins:", "", "Lessons:" }
local DEFAULT_DAY = { "Done:", "Blocked:", "First thing tomorrow:" }

-- "## Weekly" / "Weekly:" -> "weekly" (Week, Day too)
local TEMPLATE_NAMES = { weekly = "weekly", week = "weekly", daily = "daily", day = "daily" }

local function template_name(line)
	local name = line:match("^#+%s+(%a+)%s*$") or line:match("^%s*(%a+):%s*$")
	return name and TEMPLATE_NAMES[name:lower()] or nil
end

--- The "# Templates" section of the reviews note's `lines`: { lnum (its
--- heading), last } or nil. It runs to the next top-level heading.
function M.templates_section(lines)
	local fence = false
	for lnum, line in ipairs(lines) do
		local t = vim.trim(line)
		if t:sub(1, 3) == "```" or t:sub(1, 3) == "~~~" then
			fence = not fence
		elseif not fence and line:match("^#%s+[Tt]emplates%s*$") then
			local last = #lines
			for l = lnum + 1, #lines do
				if lines[l]:match("^#%s") then
					last = l - 1
					break
				end
			end
			return { lnum = lnum, last = last }
		end
	end
	return nil
end

--- The note's templates: { weekly = { lines }?, daily = { lines }? }, each
--- without its leading and trailing blank lines and common indent.
function M.templates(lines)
	local out = {}
	local sec = M.templates_section(lines)
	if not sec then
		return out
	end
	local cur
	for lnum = sec.lnum + 1, sec.last do
		local name = template_name(lines[lnum])
		if name then
			cur = {}
			out[name] = cur
		elseif cur then
			cur[#cur + 1] = lines[lnum]
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

-- A new week's or day's lines: the note's template, else the config's
local function template(lines, kind)
	local t = M.templates(lines)[kind]
	if t then
		return vim.deepcopy(t)
	end
	if kind == "weekly" then
		return vim.deepcopy(cfg().week or DEFAULT_WEEK)
	end
	return vim.deepcopy(cfg().day or DEFAULT_DAY)
end

-- A new reviews note: its header and the templates, to edit there
local function new_note()
	local out = { "@@Reviews", "", "# Templates", "## Weekly" }
	vim.list_extend(out, cfg().week or DEFAULT_WEEK)
	out[#out + 1] = "## Daily"
	vim.list_extend(out, cfg().day or DEFAULT_DAY)
	out[#out + 1] = ""
	return out
end

local function ensure_note()
	local path = M.path()
	workspace().ensure_file(path, new_note())
	return path
end

-- Lines `entry` put before line `at`, with one blank line between it and
-- what comes before and after.
local function insert_block(path, lines, at, block)
	local out = vim.deepcopy(block)
	local first = at
	if at > 1 and (lines[at - 1] or ""):find("%S") then
		table.insert(out, 1, "")
		first = at + 1
	end
	if at <= #lines and (lines[at] or ""):find("%S") then
		out[#out + 1] = ""
	end
	workspace().insert_lines(path, at, out)
	return first
end

--- The line of "# <week>", the entry made from review.week when missing:
--- newest first, before the first older week.
function M.ensure_week(week)
	local path = ensure_note()
	local lines = workspace().get_lines(path)
	local data = M.entries(lines)
	if data.weeks[week] then
		return data.weeks[week].lnum
	end
	local at
	for _, wk in ipairs(data.order) do
		if wk < week then
			at = data.weeks[wk].lnum
			break
		end
	end
	if not at then
		-- the oldest week: at the end, or before the templates when they
		-- come after every week
		at = #lines + 1
		local sec = M.templates_section(lines)
		local last_week = data.order[#data.order]
		if sec and last_week and sec.lnum > data.weeks[last_week].lnum then
			at = sec.lnum
		end
	end
	local block = { "# " .. week }
	vim.list_extend(block, template(lines, "weekly"))
	return insert_block(path, lines, at, block)
end

--- The line of "## <date>" in its week's entry (both made when missing):
--- newest first, before the week's first older day.
function M.ensure_day(date)
	local week = M.week_of(date)
	M.ensure_week(week)
	local path = M.path()
	local lines = workspace().get_lines(path)
	local e = M.entries(lines).weeks[week]
	if e.days[date] then
		return e.days[date]
	end
	local at
	for l = e.own_end + 1, e.last do
		local d = lines[l]:match(DAY_HEADING)
		if d and d < date then
			at = l
			break
		end
	end
	if not at then
		-- after the week's last non-blank line
		at = e.lnum + 1
		for l = e.last, e.lnum, -1 do
			if lines[l]:find("%S") then
				at = l + 1
				break
			end
		end
	end
	local block = { "## " .. date }
	vim.list_extend(block, template(lines, "daily"))
	return insert_block(path, lines, at, block)
end

--- Add the project to the week's focus, or take it out when it is there.
--- Returns true when added.
function M.toggle_focus(week, project)
	M.ensure_week(week)
	local path = M.path()
	local lines = workspace().get_lines(path)
	local e = M.entries(lines).weeks[week]
	for _, x in ipairs(M.focus_lines(lines, e)) do
		if x.project.key == project.key then
			workspace().delete_lines(path, x.lnum)
			return false
		end
	end
	if not e.focus then
		workspace().insert_lines(path, e.lnum + 1, { "Focus:", "- " .. focus_link(project) })
		return true
	end
	local indent = lines[e.focus.lnum]:match(FOCUS_LABEL) or ""
	workspace().insert_lines(path, e.focus.to + 1, { indent .. "- " .. focus_link(project) })
	return true
end

return M
