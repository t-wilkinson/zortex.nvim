-- ui/review.lua - The daily and weekly review: your notes and the findings
--
-- :ZortexReview [day|week|N] opens the review's entry in reviews.zortex (made
-- when missing, services/review) with the findings of
-- services/agenda.review() beside it in a read-only, Zortex-highlighted
-- scratch buffer (zortex://review). What you write goes in the note; the
-- findings are regenerated each time and never written anywhere. Every
-- finding links to its project, area or objective, so gx / K (preview) work
-- as in any note.
--
--   <CR>   jump to the finding's source line (task, calendar entry, heading)
--   f      on a project: add it to (or take it out of) the week's focus
--   m      on an inbox line: move it to its @project(...), else to
--          review.inbox_default, else to a place picked in the search
--   u      take the last move back (:ZortexUndo)
--   <Tab>  go to the reviews note
--   gx     follow the link on the line
--   K      preview the link on the line
--   r      refresh (re-reads the notes)
--   q      close
--   ?      these keys (ui/keyhelp)
--
-- render(review) is pure: it returns the lines, a line -> location map and a
-- line -> entity map, so other front ends (the web app) can reuse the
-- same layout.
local M = {}

local BUF_NAME = "zortex://review"

local state = { bufnr = nil, win = nil, note_win = nil, days = 7, scope = "week", locations = {}, entities = {} }

local function rel(path)
	local dir = require("zortex.config").notes_dir or ""
	if dir ~= "" and path:sub(1, #dir) == dir then
		return path:sub(#dir + 1):gsub("^/", "")
	end
	return vim.fn.fnamemodify(path, ":~:.")
end

local function pct(x)
	return string.format("%d%%", math.floor((x or 0) * 100 + 0.5))
end

local function project_summary(p)
	local r = p:rollup()
	local parts = {}
	if r.total > 0 then
		parts[#parts + 1] = string.format("%d/%d done", r.done, r.total)
	end
	if r.points_open > 0 then
		parts[#parts + 1] = string.format("%.3g pts open", r.points_open)
	end
	return #parts > 0 and ("(" .. table.concat(parts, ", ") .. ")") or ""
end

-- One agenda item (overdue / due soon / completed)
local function item_line(item)
	local when = item.date or ""
	if item.time then
		when = when .. " " .. item.time
	end
	local where
	if item.project and item.project.link then
		where = item.project.link
	elseif item.entry then
		where = "(calendar)"
	end
	local line = string.format("- %s %s", when, item.text or "")
	if where then
		line = line .. " " .. where
	end
	local task = item.task
	return line,
		{
			file = item.file or (task and task.file) or (item.project and item.project.file),
			lnum = item.lnum or (task and task.lnum) or (item.project and item.project.lnum),
		}
end

-- A task finding (overdue, due): x ticks it, d sets its @due, s puts it
-- on a day
local function task_line(item)
	local line, loc = item_line(item)
	return line, loc, { task_item = item, file = loc.file, lnum = loc.lnum }
end

-- An inbox line, as written ("- [ ] Call the plumber"; plain text gets a
-- "- "), with where `m` moves it; a line from another note says which
local function inbox_line(x)
	local line = x.text:match("^[-*+] ") and x.text or ("- " .. x.text)
	local dest = require("zortex.services.triage").destination(x)
	if not x.inbox then
		line = line .. "  (" .. rel(x.file) .. ")"
	end
	if dest and not x.project then
		line = line .. "  → " .. dest
	end
	return line, { file = x.file, lnum = x.lnum }, { triage = x }
end

local function entity_line(e, suffix)
	return "- " .. (e.link or e.name) .. (suffix and (" " .. vim.trim(suffix)) or ""), { file = e.file, lnum = e.lnum }, e
end

local function is_project(e)
	return type(e) == "table" and type(e.link) == "string" and e.link:sub(1, 3) == "[P/" and e.rollup ~= nil
end

-- "- ×4 Lap the valves [P/#3.1 Rebuild the engine]"
local function put_off_line(x)
	local line = string.format("- ×%d %s", x.count, x.text or "")
	if x.project and x.project.link then
		line = line .. " " .. x.project.link
	elseif x.file then
		line = line .. " (calendar)"
	end
	return line, { file = x.file, lnum = x.lnum }
end

--- Lines, line -> { file, lnum } locations and line -> entity (projects,
--- areas, objectives) for a review. r.week, r.focus (that week's focus
--- projects) and r.active (active projects, best first) add the week's
--- section.
---@param r table result of agenda.review()
---@param opts { days?: integer }?
---@return string[] lines, table<integer, { file: string, lnum: integer }> locations, table<integer, table> entities
function M.render(r, opts)
	opts = opts or {}
	local lines, locations, entities = {}, {}, {}

	local function add(line, loc, entity)
		lines[#lines + 1] = line
		if loc and loc.file and loc.lnum then
			locations[#lines] = loc
		end
		if entity then
			entities[#lines] = entity
		end
	end

	local function section(title, list, fn, empty)
		add("")
		add(string.format("## %s (%d)", title, #list))
		if #list == 0 then
			add(empty or "  nothing")
			return
		end
		for _, x in ipairs(list) do
			add(fn(x))
		end
	end

	local stale = {}
	for _, p in ipairs(r.stale) do
		stale[p] = true
	end
	local unscheduled = vim.tbl_filter(function(p)
		return not stale[p]
	end, r.unscheduled)

	if r.scope == "day" then
		M.render_day(r, add, section)
		return lines, locations, entities
	end

	add("@@Weekly Review")
	add(string.format("Today %s · looking back to %s, ahead to %s", r.today, r.from, r.to))
	local broken = #r.broken_links > 0 and string.format(" · %d broken link%s", #r.broken_links, #r.broken_links == 1 and "" or "s")
		or ""
	add(
		string.format(
			"%d overdue · %d due soon · %d completed · %d stale%s · %d in the inbox",
			#r.overdue,
			#r.due_soon,
			#r.completed,
			#r.stale,
			broken,
			#(r.inbox or {})
		)
	)
	M.render_inbox(r, section)
	M.render_top_down(r, add)
	M.render_week(r, add, section)

	M.render_plan(r, add, section, { brief = true })

	add("")
	add("# Tasks")
	section("Overdue", r.overdue, task_line)
	section("Due soon", r.due_soon, task_line)
	section("Completed", r.completed, item_line)

	add("")
	add("# Projects")
	section("Stale: no calendar time behind or ahead (s schedules, n next action, z someday, a archives a done one)", r.stale, function(p)
		return entity_line(p, project_summary(p))
	end)
	section("Unscheduled: open work, nothing on the calendar ahead", unscheduled, function(p)
		return entity_line(p, project_summary(p))
	end)
	section("No next action (n adds one)", r.no_next_action, function(p)
		return entity_line(p)
	end)
	section("Done (a moves it to its note's archive)", r.done_projects or {}, function(p)
		return entity_line(p, project_summary(p))
	end)

	add("")
	add("# Goals")
	section("Key results without projects (L links one)", r.krs_without_projects, function(kr)
		local line = "- " .. (kr.id and (kr.id .. ": ") or "") .. (kr.text or "")
		local link = kr.link or (kr.objective and kr.objective.link)
		if link then
			line = line .. " " .. link
		end
		if kr.is_stuck and kr:is_stuck() then
			line = line .. "  (stuck: no checkbox either, nothing can move it)"
		end
		return line, { file = kr.file, lnum = kr.lnum }, { kr = kr }
	end)
	section("Objectives without key results (R adds one)", r.objectives_without_krs, function(o)
		local line, loc = entity_line(o)
		return line, loc, { objective = o }
	end)
	section("Areas without active projects (p starts one)", r.areas_without_projects, function(a)
		local line, loc = entity_line(a)
		return line, loc, { area = a }
	end)
	section("Areas without an objective this period", r.areas_without_objective or {}, function(a)
		local line, loc = entity_line(a)
		return line, loc, { area = a }
	end)
	section("Projects with neither a key result nor an area", r.unaligned or {}, function(p)
		return entity_line(p, project_summary(p))
	end)

	-- the notes' health only when something is wrong: an empty list is noise
	local mirror_issues = r.mirror_issues or {}
	if #r.broken_links > 0 or #mirror_issues > 0 then
		add("")
		add("# Notes")
	end
	if #r.broken_links > 0 then
		section("Broken links (F: fix from the search)", r.broken_links, function(ref)
			return string.format("- %s:%d %s", rel(ref.file), ref.lnum, ref.text or ""),
				{ file = ref.file, lnum = ref.lnum },
				{ broken = ref }
		end)
	end
	if #mirror_issues > 0 then
		section("Task ids that don't line up", mirror_issues, function(x)
			return string.format("- %s:%d %s: %s", rel(x.file), x.lnum, x.text or "", x.problem),
				{ file = x.file, lnum = x.lnum }
		end)
	end

	return lines, locations, entities
end

--- The plan top down (weekly review): the vision, then each area with its
--- vision, the objectives that name it (against the time passed), their key
--- results and the projects those link, and the area's projects no key
--- result covers. Gaps say so where they are. Keys act on the lines: f, n,
--- s, z, a on a project; R on an objective; L on a key result; p on an area.
function M.render_top_down(r, add)
	if not r.top_down then
		return
	end
	local focused = {}
	for _, p in ipairs(r.focus or {}) do
		focused[p.key] = true
	end
	local function project_line(p, indent, suffix)
		local tags = {}
		if focused[p.key] then
			tags[#tags + 1] = "focus"
		end
		if suffix then
			tags[#tags + 1] = suffix
		end
		local summary = project_summary(p)
		return string.format("%s- %s%s%s", indent, p.link, summary ~= "" and (" " .. summary) or "", #tags > 0 and (" · " .. table.concat(tags, " · ")) or ""),
			{ file = p.file, lnum = p.lnum },
			p
	end
	add("")
	add("# Vision, areas, objectives, key results, projects")
	if r.vision then
		add("Vision: " .. r.vision)
	else
		add("  no vision yet: write one in areas.zortex (Vision: above the first area)")
	end
	for _, node in ipairs(r.top_down) do
		local area = node.area
		local base = string.rep("  ", math.max(0, (node.depth or 1) - 1))
		add("")
		if area then
			add(string.format("%s%s %s", string.rep("#", math.min(6, 1 + (node.depth or 1))), "", area.link or area.name), { file = area.file, lnum = area.lnum }, { area = area })
			if node.vision then
				add(base .. "Vision: " .. node.vision, { file = area.file, lnum = area.lnum })
			end
		else
			add("## Objectives that name no area")
		end
		if #node.objectives == 0 and area then
			add(base .. "  no objective this period", { file = area.file, lnum = area.lnum }, { area = area })
		end
		for _, x in ipairs(node.objectives) do
			local o = x.objective
			local line = string.format("%s- %s %s", base, o.link or o.name, pct(x.progress))
			if x.expected then
				line = line .. string.format(" (expected %s by now)", pct(x.expected))
			end
			add(line, { file = o.file, lnum = o.lnum }, { objective = o })
			if #x.krs == 0 then
				add(base .. "    no key results: R adds one", { file = o.file, lnum = o.lnum }, { objective = o })
			end
			for _, k in ipairs(x.krs) do
				local kr = k.kr
				local status = kr:is_done() and "done" or (k.lag >= 0.05 and (pct(k.lag) .. " behind") or "on track")
				add(
					string.format("%s    - %s: %s %s · %s %s", base, kr.id or "KR", kr.text or "", pct(k.progress), status, kr.link or ""),
					{ file = kr.file, lnum = kr.lnum },
					{ kr = kr }
				)
				if not kr:is_done() and #(k.projects or {}) == 0 then
					add(base .. "        no project moves it: L links one", { file = kr.file, lnum = kr.lnum }, { kr = kr })
				end
				for _, p in ipairs(k.projects or {}) do
					add(project_line(p, base .. "        "))
				end
			end
		end
		for _, p in ipairs(node.area_only or {}) do
			add(project_line(p, base .. "  ", "area only"))
		end
	end
end

--- The week being planned: its focus projects, tasks put off again and
--- again, and the active projects to pick the focus from (f).
function M.render_week(r, add, section)
	if not r.week then
		return
	end
	local focused = {}
	for _, p in ipairs(r.focus or {}) do
		focused[p.key] = true
	end
	add("")
	add("# Week " .. r.week)
	section("Focus (f on a project adds or removes it)", r.focus or {}, function(p)
		return entity_line(p, project_summary(p))
	end, "  none yet: press f on a project below")
	section("Put off on 2+ days: do it, shrink it, or drop it", r.put_off or {}, put_off_line)
	local active = vim.tbl_filter(function(p)
		return not focused[p.key]
	end, r.active or {})
	section("Active projects", active, function(p)
		return entity_line(p, project_summary(p))
	end)
end


-- "+120 XP, 12h of estimated work: 70% on key results, 20% areas only, 10% neither · +60 Mastery XP"
local function xp_line(xp)
	if not xp or xp.xp <= 0 then
		return "  no XP in this window"
	end
	local a = xp.by_alignment
	local calc = require("zortex.services.xp.calculator")
	return string.format(
		"  +%d XP, %s of estimated work: %s on key results, %s areas only, %s neither · +%d Mastery XP",
		math.floor(xp.xp + 0.5),
		calc.hours_text(xp.xp),
		pct(a.kr / xp.xp),
		pct(a.area / xp.xp),
		pct(a.none / xp.xp),
		math.floor(xp.mastery + 0.5)
	)
end

-- "  Season Q4 2026: 42% of its objectives · Silver · Gold at 70%"
local function season_line(s)
	if not s then
		return nil
	end
	return string.format(
		"  %s: %s of its objectives%s%s",
		require("zortex.services.xp.season").label(s.season),
		pct(s.progress),
		s.tier and (" · " .. s.tier.name) or "",
		s.next_tier and string.format(" · %s at %s", s.next_tier.name, pct(s.next_tier.at)) or ""
	)
end

--- Objectives (most behind first), XP and time: the top of both reviews.
function M.render_plan(r, add, section, opts)
	opts = opts or {}
	local fmt_time = require("zortex.services.time_spent").format
	add("")
	add("# Plan")
	add("")
	local xp_on = require("zortex.services.xp.calculator").enabled()
	if xp_on then
		add("## XP (" .. require("zortex.services.xp.calculator").unit_text() .. ")")
		local sl = season_line(r.season)
		if sl then
			add(sl)
		end
		add(xp_line(r.xp))
	end
	if opts.brief then
		-- the weekly review has them top down (render_top_down)
		if r.time and r.time.minutes > 0 then
			section("Time spent: " .. fmt_time(r.time.minutes), r.time.tasks, function(t)
				return string.format("- %s %s (%s)", fmt_time(t.minutes), t.text or "", t.rel or ""),
					t.file and { file = t.file, lnum = t.lnum }
			end)
		end
		return
	end
	section("Objectives", r.objectives or {}, function(x)
		local o = x.objective
		local line = string.format("- %s %s", o.link or o.name, pct(x.progress))
		if x.expected then
			line = line .. string.format(" (expected %s by now)", pct(x.expected))
		end
		return line, { file = o.file, lnum = o.lnum }
	end, "  no current objectives: plan some in okr.zortex")
	-- the key results of each objective, under it (behind schedule first)
	if #(r.objectives or {}) > 0 and not opts.brief then
		add("")
		add("## Key results")
		for _, x in ipairs(r.objectives) do
			for _, k in ipairs(x.krs) do
				local kr = k.kr
				local status = kr:is_done() and "done" or (k.lag >= 0.05 and (pct(k.lag) .. " behind") or "on track")
				add(
					string.format("- %s: %s %s · %s %s", kr.id, kr.text or "", pct(k.progress), status, kr.link or ""),
					{ file = kr.file, lnum = kr.lnum }
				)
			end
		end
	end
	if r.time and r.time.minutes > 0 then
		section("Time spent: " .. fmt_time(r.time.minutes), r.time.tasks, function(t)
			return string.format("- %s %s (%s)", fmt_time(t.minutes), t.text or "", t.rel or ""),
				t.file and { file = t.file, lnum = t.lnum }
		end)
	end
end

--- The inbox, first: thoughts added since (from Neovim or the web app) to
--- move into projects, the calendar or notes. Nothing when it is empty.
function M.render_inbox(r, section)
	if r.inbox and #r.inbox > 0 then
		section("Inbox (m moves each to its @project, or picks a place)", r.inbox, inbox_line)
	end
end

--- The daily review: what today (or since the last daily review) added up to.
function M.render_day(r, add, section)
	local since = r.from == r.today and "today" or ("since " .. r.from)
	add("@@Daily Review")
	add(string.format("%s · %s", r.today, since))
	local cal = r.calendar or { entries = 0, tasks = 0, done = 0, open = {} }
	add(
		string.format(
			"%d completed · %d of %d calendar tasks done · %d overdue · %d due by tomorrow · %d in the inbox",
			#r.completed,
			cal.done,
			cal.tasks,
			#r.overdue,
			#r.due_soon,
			#(r.inbox or {})
		)
	)
	-- how the work done served the plan, in hours
	local xp = r.xp or { xp = 0, by_alignment = {} }
	if xp.xp > 0 then
		local calc = require("zortex.services.xp.calculator")
		local a = xp.by_alignment
		add(string.format(
			"Work done: %s · %s on key results · %s on areas only · %s on neither",
			calc.hours_text(xp.xp),
			pct((a.kr or 0) / xp.xp),
			pct((a.area or 0) / xp.xp),
			pct((a.none or 0) / xp.xp)
		))
	else
		add("Work done: nothing finished yet")
	end
	M.render_inbox(r, section)
	if r.week then
		section("Focus " .. r.week, r.focus or {}, function(p)
			return entity_line(p, project_summary(p))
		end, "  none: pick some in the weekly review (:ZortexReview)")
	end
	if r.put_off and #r.put_off > 0 then
		section("Put off on 2+ days: do it, shrink it, or drop it", r.put_off, put_off_line)
	end
	M.render_plan(r, add, section, { brief = false })
	add("")
	add("# Day")
	section("Completed", r.completed, item_line)
	section("Not done (t: same time tomorrow)", cal.open, function(item)
		local line, loc = item_line(item)
		return line, loc, { next_day = item.lnum, task_item = item, file = loc.file, lnum = loc.lnum }
	end)
	section("Done on neither a key result nor an area (a: archive it)", r.unaligned_done or {}, function(e)
		local calc = require("zortex.services.xp.calculator")
		return string.format("- %s %s (%s, %s)", e.date or "", e.title or "", calc.hours_text(e.xp or 0), rel(e.file)),
			{ file = e.file, lnum = e.lnum },
			{ archive_task = { file = e.file, lnum = e.lnum, title = e.title } }
	end)
	section("Overdue", r.overdue, task_line)
	section("Due today and tomorrow", r.due_soon, task_line)
end

-- =============================================================================
-- Buffer
-- =============================================================================

local function note_window()
	if state.note_win and vim.api.nvim_win_is_valid(state.note_win) then
		return state.note_win
	end
	return nil
end

local function jump()
	local loc = state.locations[vim.api.nvim_win_get_cursor(0)[1]]
	if not loc then
		return
	end
	-- open it where the reviews note is, keeping the findings
	local win = note_window()
	if win then
		vim.api.nvim_set_current_win(win)
	end
	vim.cmd("edit " .. vim.fn.fnameescape(loc.file))
	local last = vim.api.nvim_buf_line_count(0)
	vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(loc.lnum, last)), 0 })
	vim.cmd("normal! zv")
end

--- m: move the inbox line (or @project line) on the cursor line to its
--- project, review.inbox_default, or a place picked in the search.
function M.triage()
	local e = state.entities[vim.api.nvim_win_get_cursor(0)[1]]
	local item = e and e.triage
	if not item then
		vim.api.nvim_echo({ { "Not an inbox line", "WarningMsg" } }, false, {})
		return
	end
	local triage = require("zortex.services.triage")
	local function done(res, err)
		if not res then
			vim.api.nvim_echo({ { "Inbox: " .. tostring(err), "WarningMsg" } }, false, {})
			return
		end
		M.refresh()
		vim.api.nvim_echo({ { "Moved to " .. res.link .. " (u takes it back)", "Comment" } }, false, {})
	end
	if triage.destination(item) then
		return done(triage.move(item))
	end
	-- nowhere set: pick a place in the structural search
	require("zortex.features.move").pick(item.file, item.lnum, nil, function(result)
		if result then
			M.refresh()
		end
	end)
end

local function entity_here()
	return state.entities[vim.api.nvim_win_get_cursor(0)[1]]
end

local function say(msg, warn)
	vim.api.nvim_echo({ { msg, warn and "WarningMsg" or "Comment" } }, false, {})
end

--- a: archive what is on the line: a finished task that served neither a
--- key result nor an area goes to z/archive.tasks.zortex; a done project
--- (its tasks all checked) gets @done and moves to its note's archive.
function M.archive()
	local e = entity_here()
	if e and e.archive_task then
		local path, err = require("zortex.features.archive").archive_task(e.archive_task.file, e.archive_task.lnum)
		if not path then
			return say("Archive: " .. tostring(err), true)
		end
		M.refresh()
		return say("Archived to " .. vim.fn.fnamemodify(path, ":t") .. " (u takes it back)")
	end
	if is_project(e) then
		return M.archive_project(e)
	end
	say("Nothing to archive on this line", true)
end

-- =============================================================================
-- One-key fixes (the weekly review; most work in the daily one too)
-- =============================================================================

local function ws()
	return require("zortex.core.workspace")
end

-- Run an edit of one or more notes as a batch, then refresh and say so
local function fix(label, files, fn, done_msg)
	local res, err = ws().batch(label, files, fn)
	if res == nil or res == false then
		return say(label .. ": " .. tostring(err or "nothing changed"), true)
	end
	M.refresh()
	say((done_msg or label) .. " (u takes it back)")
end

local function today_plus(n)
	return os.date("%Y-%m-%d", os.time() + n * 86400)
end

-- "2026-10-21", "+3" (days from today), "tomorrow", "today" -> YYYY-MM-DD
local function parse_day(text)
	text = vim.trim(text or "")
	if text == "" or text == "tomorrow" then
		return today_plus(1)
	elseif text == "today" then
		return today_plus(0)
	end
	local n = text:match("^%+(%d+)$")
	if n then
		return today_plus(tonumber(n))
	end
	return text:match("^%d%d%d%d%-%d%d%-%d%d$")
end

local function ask(prompt, default, fn)
	vim.ui.input({ prompt = prompt, default = default }, function(text)
		if text and vim.trim(text) ~= "" then
			fn(vim.trim(text))
		end
	end)
end

-- The last non-blank line of an entity's own lines (to add under it)
local function own_end(e)
	local lines = ws().get_lines(e.file)
	local s, last = e:own_range()
	local at = s
	for l = s, last do
		if lines[l] and lines[l]:match("%S") then
			at = l
		end
	end
	return at, lines
end

--- x: tick (or untick) the task on the line.
function M.complete()
	local e = entity_here()
	if not (e and e.task_item) then
		return say("Not a task line", true)
	end
	-- copies of the task (the calendar) follow it
	fix("tick", { e.file, require("zortex.utils.filesystem").get_calendar_file() }, function()
		return require("zortex.services.tasks").toggle_at(e.file, e.lnum)
	end, "Ticked")
end

--- d: set or move the task's @due (a date, +N days, tomorrow).
function M.set_due()
	local e = entity_here()
	if not (e and e.task_item) then
		return say("Not a task line", true)
	end
	local line = ws().get_lines(e.file)[e.lnum] or ""
	local current = line:match("@due%(([^)]+)%)")
	ask("Due (YYYY-MM-DD, +N days): ", current or "+7", function(text)
		local day = parse_day(text)
		if not day then
			return say("Not a date: " .. text, true)
		end
		fix("due", { e.file }, function()
			local now = ws().get_lines(e.file)[e.lnum]
			return ws().set_line(e.file, e.lnum, require("zortex.utils.attributes").update_attribute(now, "due", day))
		end, "Due " .. day)
	end)
end

--- s: put the task, or a block of the project, on a day of the calendar.
function M.schedule()
	local e = entity_here()
	local planner = require("zortex.services.planner")
	local cal = require("zortex.utils.filesystem").get_calendar_file()
	if e and e.task_item then
		local item = e.task_item
		if not (item.task and item.project) then
			return say("Already on the calendar", true)
		end
		ask("Put it on (YYYY-MM-DD, +N, tomorrow): ", "tomorrow", function(text)
			local day = parse_day(text)
			if not day then
				return say("Not a date: " .. text, true)
			end
			fix("schedule", { cal, e.file }, function()
				return planner.add_task(day, { file = e.file, lnum = e.lnum, link = planner.item_link(item.project.link, item.task.raw_text) })
			end, "On " .. day)
		end)
	elseif is_project(e) then
		ask("A block of it on (YYYY-MM-DD, +N, tomorrow): ", "tomorrow", function(text)
			local day = parse_day(text)
			if not day then
				return say("Not a date: " .. text, true)
			end
			fix("schedule", { cal }, function()
				return planner.add_project(day, { project_key = e.key })
			end, e.name .. " on " .. day)
		end)
	else
		say("Not a task or project line", true)
	end
end

--- n: add a next action under the project.
function M.next_action()
	local e = entity_here()
	if not is_project(e) then
		return say("Not a project line", true)
	end
	ask("Next action for " .. e.name .. ": ", nil, function(text)
		fix("next action", { e.file }, function()
			local at = own_end(e)
			local task = text:match("^%- %[") and text or ("- [ ] " .. text:gsub("^%-%s*", ""))
			return ws().insert_lines(e.file, at + 1, { task })
		end, "Added to " .. e.name)
	end)
end

--- z: park the project (@someday: no longer stale or unscheduled), or
--- bring it back.
function M.someday()
	local e = entity_here()
	if not is_project(e) then
		return say("Not a project line", true)
	end
	fix("someday", { e.file }, function()
		local line = ws().get_lines(e.file)[e.lnum]
		local new
		if line:find("@someday", 1, true) then
			new = (line:gsub("%s*@someday%f[^%w]", ""))
		else
			new = line .. " @someday"
		end
		return ws().set_line(e.file, e.lnum, new)
	end, e.name .. ": @someday toggled")
end

--- a on a project: archive it when it is done.
function M.archive_project(e)
	local r = e:rollup()
	if not e:is_done() and r.open > 0 then
		return say(string.format("%s still has %d open task%s: tick them, or mark it done (<leader>zT on its heading)", e.name, r.open, r.open == 1 and "" or "s"), true)
	end
	local path, err = require("zortex.features.archive").archive_section_at(e.file, e.lnum)
	if not path then
		return say("Archive: " .. tostring(err), true)
	end
	M.refresh()
	say("Archived " .. e.name .. " to " .. vim.fn.fnamemodify(path, ":t") .. " (u takes it back)")
end

--- L: link a project to the key result (picked from the active projects).
function M.link_project()
	local e = entity_here()
	if not (e and e.kr) then
		return say("Not a key result line", true)
	end
	local kr = e.kr
	local list = vim.tbl_filter(function(p)
		return not p:is_root() and not p:is_done()
	end, require("zortex.services.projects").all())
	vim.ui.select(list, {
		prompt = "Project that moves " .. (kr.id or "the key result"),
		format_item = function(p)
			return p.link
		end,
	}, function(p)
		if not p then
			return
		end
		fix("link a project", { kr.file }, function()
			local line = ws().get_lines(kr.file)[kr.lnum]
			return ws().set_line(kr.file, kr.lnum, line .. " " .. p.link)
		end, (kr.id or "Key result") .. " → " .. p.link)
	end)
end

--- R: add a key result under the objective.
function M.add_key_result()
	local e = entity_here()
	local o = e and e.objective
	if not o then
		return say("Not an objective line", true)
	end
	local n = #(o.key_results or {}) + 1
	ask(string.format("KR%d of %s: ", n, o.title or o.name), nil, function(text)
		fix("add a key result", { o.file }, function()
			local at = own_end(o)
			return ws().insert_lines(o.file, at + 1, { string.format("- KR%d: [ ] %s", n, text) })
		end, "KR" .. n .. " added")
	end)
end

-- The @area(...) value that names `area`: its heading ("1.2 Vitality"), or
-- "<heading>/<label>" for a label
local function area_value(area)
	if area.kind == "heading" or not area.parent or area.parent:is_root() then
		return area.name
	end
	return area.parent.name .. "/" .. area.name
end

--- p: start a project for the area (a heading at the end of the projects
--- note, with @area(...)).
function M.new_project()
	local e = entity_here()
	local area = e and e.area
	if not area then
		return say("Not an area line", true)
	end
	local path = require("zortex.utils.filesystem").get_projects_file()
	ask("New project for " .. area.name .. ": ", nil, function(text)
		fix("new project", { path }, function()
			local lines = ws().get_lines(path)
			local add = { "# " .. text .. " @area(" .. area_value(area) .. ")", "- [ ] " }
			if lines[#lines] and lines[#lines]:match("%S") then
				table.insert(add, 1, "")
			end
			add[#add] = "- [ ] The first step"
			return ws().insert_lines(path, #lines + 1, add)
		end, "Project " .. text .. " started in " .. vim.fn.fnamemodify(path, ":t"))
	end)
end

--- F: fix a broken link: pick its target in the structural search (the
--- link's text is the prompt); the link is rewritten to the result's.
function M.fix_link()
	local e = entity_here()
	local ref = e and e.broken
	if not ref then
		return say("Not a broken link line", true)
	end
	local link_mod = require("zortex.core.link")
	local search = require("zortex.ui.picker.search")
	local spec = search.spec({ all_sections = true, new_note = false })
	local words = (ref.definition or ""):gsub("[%[%]#:%*%-@/]", " "):gsub("%s+", " ")
	spec.prompt = vim.trim(words)
	spec.on_open = nil
	spec.open = function(result)
		local new = link_mod.build_result_link(result)
		if not new or new == "[?]" then
			return say("No link for that result", true)
		end
		fix("fix a link", { ref.file }, function()
			local line = ws().get_lines(ref.file)[ref.lnum]
			if ref.def_col then
				-- [text](definition): the text stays, the definition changes
				local at = line:find("(" .. ref.definition .. ")", ref.def_col - 1, true)
				if not at then
					return nil, "the link isn't on its line any more"
				end
				local def = new:gsub("^%[", ""):gsub("%]$", "")
				return ws().set_line(
					ref.file,
					ref.lnum,
					line:sub(1, at) .. def .. line:sub(at + 1 + #ref.definition)
				)
			end
			local s, f = line:find("[" .. ref.definition .. "]", 1, true)
			if not s then
				return nil, "the link isn't on its line any more"
			end
			return ws().set_line(ref.file, ref.lnum, line:sub(1, s - 1) .. new .. line:sub(f + 1))
		end, "Link fixed: " .. new)
	end
	require("zortex.ui.picker").pick(spec)
end

--- t: an open calendar task the day left undone goes on the next day, at
--- the same time ([>] on the old line, services/planner.to_next_day).
function M.next_day()
	local e = entity_here()
	if not (e and e.next_day) then
		return say("Not an open calendar task", true)
	end
	local day, err = require("zortex.services.planner").to_next_day(e.next_day)
	if not day then
		return say("Tomorrow: " .. tostring(err), true)
	end
	M.refresh()
	say("On " .. day .. " (u takes it back)")
end

--- u: take back the last move (m), or any batch of edits across notes
--- (core/workspace.undo_last, :ZortexUndo).
function M.undo()
	local label, err = require("zortex.core.workspace").undo_last()
	if not label then
		vim.api.nvim_echo({ { "Undo: " .. err, "WarningMsg" } }, false, {})
		return
	end
	M.refresh()
	vim.api.nvim_echo({ { "Undone: " .. label, "Comment" } }, false, {})
end

--- f: add the project on the cursor line to the week's focus, or take it
--- out.
function M.toggle_focus()
	local e = state.entities[vim.api.nvim_win_get_cursor(0)[1]]
	if not is_project(e) then
		vim.api.nvim_echo({ { "Not a project line", "WarningMsg" } }, false, {})
		return
	end
	local review = require("zortex.services.review")
	local week = state.week or review.review_week(state.today)
	-- the note open without unsaved changes: save the change too, so the
	-- web app and other devices see the focus
	local nb = vim.fn.bufnr(vim.fn.fnamemodify(review.path(), ":p"))
	local clean = nb > 0 and vim.api.nvim_buf_is_loaded(nb) and not vim.bo[nb].modified
	local added = review.toggle_focus(week, e)
	if clean then
		pcall(vim.api.nvim_buf_call, nb, function()
			vim.cmd("silent write")
		end)
	end
	M.refresh()
	vim.api.nvim_echo({
		{ string.format("%s %s %s's focus", e.link, added and "added to" or "taken out of", week), "Comment" },
	}, false, {})
end

local function get_buffer()
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		return state.bufnr
	end
	local buf = vim.fn.bufnr(BUF_NAME)
	if buf == -1 then
		buf = vim.api.nvim_create_buf(true, true)
		vim.api.nvim_buf_set_name(buf, BUF_NAME)
	end
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false

	-- the keys: zortex.keys ("review")
	require("zortex.keys").map(buf, "review", {
		jump = jump,
		focus = M.toggle_focus,
		triage = M.triage,
		undo = M.undo,
		next_day = M.next_day,
		archive = M.archive,
		complete = M.complete,
		due = M.set_due,
		schedule = M.schedule,
		next_action = M.next_action,
		someday = M.someday,
		link_project = M.link_project,
		add_kr = M.add_key_result,
		new_project = M.new_project,
		fix_link = M.fix_link,
		note = function()
			local win = note_window()
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
			require("zortex.ui.keyhelp").show("review")
		end,
	})

	state.bufnr = buf
	return buf
end

-- Active projects for picking the week's focus: open work, best first
local function active_projects()
	local projects = require("zortex.services.projects")
	local list = projects.all({
		filter = function(p)
			return not p:is_root() and not p:is_done() and p:rollup().open > 0
		end,
	})
	require("zortex.services.projects.score").sort(list, "score")
	return vim.list_slice(list, 1, 20)
end

--- Re-render the findings (if open).
function M.refresh()
	local buf = state.bufnr
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local agenda = require("zortex.services.agenda")
	local review = require("zortex.services.review")
	local r = agenda.review({ days = state.days, today = state.today, scope = state.scope, from = state.from })
	if state.scope == "day" then
		-- refreshing keeps the window; the next day's review starts after it
		state.from = r.from
		agenda.mark_day_reviewed(r.today, r.from)
		r.week = review.week_of(r.today)
		local f = review.focus(r.today)
		r.focus = f and f.projects or {}
		if f and f.from_earlier then
			r.week = f.week
		end
	else
		r.week = state.week
		r.focus = review.week_focus(state.week)
		r.active = active_projects()
	end
	local lines, locations, entities = M.render(r)
	state.locations, state.entities = locations, entities
	local view = state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_buf(state.win) == buf
		and vim.api.nvim_win_get_cursor(state.win)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	if view then
		pcall(vim.api.nvim_win_set_cursor, state.win, { math.min(view[1], #lines), 0 })
	end
	pcall(require("zortex.features.highlights").highlight_buffer, buf)
	-- the keys are one "?" away
	local ns = vim.api.nvim_create_namespace("zortex_review_hint")
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	if #lines > 0 then
		vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_text = { { "  ? keys", "Comment" } }, virt_text_pos = "eol" })
	end
end

function M.close()
	if state.win and vim.api.nvim_win_is_valid(state.win) and #vim.api.nvim_list_wins() > 1 then
		vim.api.nvim_win_close(state.win, true)
	elseif state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		vim.api.nvim_buf_delete(state.bufnr, { force = true })
		state.bufnr = nil
	end
	state.win = nil
end

--- Open a review: scope "day" (since the last daily review) or "week"
--- (default: last and next `days`, 7). The reviews note opens at the
--- entry (made when missing), the findings beside it.
---@param opts { days?: integer, today?: string, scope?: "day"|"week", note?: boolean }?
---@return integer bufnr the findings buffer
function M.open(opts)
	opts = opts or {}
	local review = require("zortex.services.review")
	state.days = opts.days or 7
	state.today = opts.today
	state.scope = opts.scope or "week"
	state.from = nil
	local today = opts.today or os.date("%Y-%m-%d")
	state.week = state.scope == "week" and review.review_week(today) or review.week_of(today)

	-- the reviews note at the entry
	if opts.note ~= false then
		local lnum = state.scope == "day" and review.ensure_day(today) or review.ensure_week(state.week)
		local path = review.path()
		local win = note_window()
		if win then
			vim.api.nvim_set_current_win(win)
		end
		-- the note may be open with unsaved changes: show its buffer as is
		local nb = vim.fn.bufadd(vim.fn.fnamemodify(path, ":p"))
		vim.fn.bufload(nb)
		vim.bo[nb].buflisted = true
		vim.api.nvim_win_set_buf(0, nb)
		state.note_win = vim.api.nvim_get_current_win()
		local last = vim.api.nvim_buf_line_count(0)
		vim.api.nvim_win_set_cursor(0, { math.min(lnum, last), 0 })
		vim.cmd("normal! zvzt")
	end

	-- the findings beside it
	local buf = get_buffer()
	if opts.note == false then
		state.win = vim.api.nvim_get_current_win()
	elseif not (state.win and vim.api.nvim_win_is_valid(state.win)) or state.win == state.note_win then
		vim.cmd("rightbelow vsplit")
		state.win = vim.api.nvim_get_current_win()
		local width = (require("zortex.config").review or {}).width or 80
		vim.api.nvim_win_set_width(state.win, math.min(width, math.floor(vim.o.columns / 2)))
		vim.wo[state.win].wrap = false
	end
	vim.api.nvim_win_set_buf(state.win, buf)
	vim.api.nvim_set_current_win(state.win)
	M.refresh()
	return buf
end

-- Test hook
function M._state()
	return state
end

return M
