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
-- :ZortexReview opens the week's entry (made from review.week when it is
-- missing) next to the generated findings (ui/review); :ZortexReview day the
-- day's entry (review.day) under the week it falls in. What you write stays
-- yours: nothing in the note is regenerated.
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

-- A focus line's link: the project shown by its name
local function focus_link(project)
	return require("zortex.core.link").shown(project.name, project.link) or project.link
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

local function ensure_note()
	local path = M.path()
	workspace().ensure_file(path, { "@@Reviews", "" })
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
		at = #lines + 1
	end
	local block = { "# " .. week }
	vim.list_extend(block, cfg().week or DEFAULT_WEEK)
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
	vim.list_extend(block, cfg().day or DEFAULT_DAY)
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
