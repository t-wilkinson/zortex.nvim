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
--   <Tab>  go to the reviews note
--   gx     follow the link on the line
--   K      preview the link on the line
--   r      refresh (re-reads the notes)
--   q      close
--   ?      these keys (ui/keyhelp)
--
-- render(review) is pure: it returns the lines, a line -> location map and a
-- line -> entity map, so other front ends (the digest, an app) can reuse the
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
	add(
		string.format(
			"%d overdue · %d due soon · %d completed · %d stale · %d broken links · %d in the inbox",
			#r.overdue,
			#r.due_soon,
			#r.completed,
			#r.stale,
			#r.broken_links,
			#(r.inbox or {})
		)
	)
	M.render_inbox(r, section)
	M.render_week(r, add, section)

	M.render_plan(r, add, section)

	add("")
	add("# Tasks")
	section("Overdue", r.overdue, item_line)
	section("Due soon", r.due_soon, item_line)
	section("Completed", r.completed, item_line)

	add("")
	add("# Projects")
	section("Stale: no calendar time behind or ahead", r.stale, function(p)
		return entity_line(p, project_summary(p))
	end)
	section("Unscheduled: open work, nothing on the calendar ahead", unscheduled, function(p)
		return entity_line(p, project_summary(p))
	end)
	section("No next action", r.no_next_action, function(p)
		return entity_line(p)
	end)

	add("")
	add("# Goals")
	section("Key results without projects", r.krs_without_projects, function(kr)
		local line = "- " .. (kr.id and (kr.id .. ": ") or "") .. (kr.text or "")
		local link = kr.link or (kr.objective and kr.objective.link)
		if link then
			line = line .. " " .. link
		end
		return line, { file = kr.file, lnum = kr.lnum }
	end)
	section("Objectives without key results", r.objectives_without_krs, function(o)
		return entity_line(o)
	end)
	section("Areas without active projects", r.areas_without_projects, function(a)
		return entity_line(a)
	end)
	section("Areas without an objective this period", r.areas_without_objective or {}, function(a)
		return entity_line(a)
	end)
	section("Projects with neither a key result nor an area", r.unaligned or {}, function(p)
		return entity_line(p, project_summary(p))
	end)

	add("")
	add("# Notes")
	section("Broken links", r.broken_links, function(ref)
		return string.format("- %s:%d %s", rel(ref.file), ref.lnum, ref.text or ""),
			{ file = ref.file, lnum = ref.lnum }
	end)
	if r.mirror_issues and #r.mirror_issues > 0 then
		section("Task ids that don't line up", r.mirror_issues, function(x)
			return string.format("- %s:%d %s: %s", rel(x.file), x.lnum, x.text or "", x.problem),
				{ file = x.file, lnum = x.lnum }
		end)
	end

	return lines, locations, entities
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

local function pct(x)
	return string.format("%d%%", math.floor((x or 0) * 100 + 0.5))
end

-- "+60 Mastery XP · 12h of estimated work: 70% on key results, 20% areas only, 10% neither"
local function xp_line(xp)
	if not xp or xp.xp <= 0 then
		return "  no XP in this window"
	end
	local a = xp.by_alignment
	local hours = xp.xp / require("zortex.services.xp.calculator").xp_per_hour()
	return string.format(
		"  +%d Mastery XP · %sh of estimated work: %s on key results, %s areas only, %s neither",
		math.floor(xp.mastery + 0.5),
		(string.format("%.1f", hours):gsub("%.0$", "")),
		pct(a.kr / xp.xp),
		pct(a.area / xp.xp),
		pct(a.none / xp.xp)
	)
end

-- "  Season Q4 2026: 42% of its objectives · Silver · Gold at 70%"
local function season_line(s)
	if not s then
		return nil
	end
	return string.format(
		"  Season %s: %s of its objectives%s%s",
		s.season.name or "",
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
	add("## XP")
	local sl = season_line(r.season)
	if sl then
		add(sl)
	end
	add(xp_line(r.xp))
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
	section("Left on the calendar (put them on another day with :ZortexPlan)", cal.open, item_line)
	section("Overdue", r.overdue, item_line)
	section("Due today and tomorrow", r.due_soon, item_line)
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
		vim.api.nvim_echo({ { "Moved to " .. res.link, "Comment" } }, false, {})
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

	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	map("<CR>", jump, "Zortex review: jump to source")
	map("f", M.toggle_focus, "Zortex review: add the project to the week's focus (or take it out)")
	map("m", M.triage, "Zortex review: move the inbox line to its @project (or pick a place)")
	map("<Tab>", function()
		local win = note_window()
		if win then
			vim.api.nvim_set_current_win(win)
		end
	end, "Zortex review: go to the reviews note")
	map("gx", function()
		require("zortex.features.links").open_link()
	end, "Zortex review: follow link")
	map("K", function()
		require("zortex.features.preview").preview_link()
	end, "Zortex review: preview link")
	map("r", function()
		M.refresh()
	end, "Zortex review: refresh")
	map("q", function()
		M.close()
	end, "Zortex review: close")
	map("?", function()
		require("zortex.ui.keyhelp").show("Zortex review: ", "Review keys")
	end, "Zortex review: these keys")

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
