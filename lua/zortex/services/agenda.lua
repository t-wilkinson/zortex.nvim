-- services/agenda.lua - What's on, what's due, and what needs attention
--
-- One query over the calendar, project tasks and projects, used by the
-- calendar view, the digest file and the email digest. review() collects the
-- findings a weekly review needs.
--
--   local A = require("zortex.services.agenda")
--   A.day("2026-10-09")                     -- items for one day
--   A.range("2026-10-09", "2026-10-15")     -- { { date, items }, ... }
--   A.upcoming(7)                           -- today + 6 days
--   A.review({ days = 7 })                  -- weekly review findings
--
-- An item:
--   kind      "event" | "task" | "note"   (calendar entries)
--             "due"                       (project task with @due on the day)
--             "project_due"               (project with @due on the day)
--   date, time ("HH:MM" or nil), text, done, priority ("1".."3" or nil)
--   moved     a calendar task carried to a later day ([>], services/mirrors)
--   ref       a calendar line without a checkbox linking a task: the task
--             ({ file, lnum, task }); done is the task's
--   entry     CalendarEntry (calendar items)
--   task      project task (due items)
--   project   Project the item belongs to / links to (if any)
--   file, lnum
local M = {}

local datetime = require("zortex.utils.datetime")

local function projects()
	return require("zortex.services.projects")
end

local function fmt(date)
	return datetime.format_datetime(date, "YYYY-MM-DD")
end

local function today_str(opts)
	return (opts and opts.today) or fmt(datetime.get_current_date())
end

local function add_days(date_str, n)
	return fmt(datetime.add_days(datetime.parse_date(date_str), n))
end

local function date_of(attr)
	if type(attr) == "table" and attr.year then
		return fmt(attr)
	end
	return nil
end

-- =============================================================================
-- Item sources
-- =============================================================================

-- Project linked from a calendar line (via the link index)
local function calendar_projects()
	local path = require("zortex.utils.filesystem").get_calendar_file()
	local by_line = {}
	for _, ref in ipairs(require("zortex.core.link_index").links_from(path)) do
		if ref.target and not by_line[ref.lnum] then
			by_line[ref.lnum] = projects().at(ref.target.file, ref.target.lnum)
		end
	end
	return by_line, path
end

local function calendar_items(date, ctx)
	local mirrors = require("zortex.services.mirrors")
	local items = {}
	for _, entry in ipairs(require("zortex.stores.calendar").get_entries_for_date(date)) do
		local item = {
			kind = entry.type,
			date = date,
			time = entry:get_time_string(),
			text = entry.text,
			done = entry.type == "task" and entry.completed or false,
			moved = entry.mark == mirrors.MOVED,
			priority = entry.attributes.p,
			entry = entry,
			project = ctx.calendar_projects[entry.lnum],
			file = ctx.calendar_path,
			lnum = entry.lnum,
		}
		if entry.type ~= "task" and entry.lnum and ctx.calendar_doc and entry.raw_text:find("[", 1, true) then
			local ref = mirrors.reference(ctx.calendar_doc.lines, entry.lnum, ctx.calendar_doc)
			if ref then
				local id = ref.task.attributes.id
				local copy = id and mirrors.copies()[id]
				item.ref = ref
				item.done = ref.task.completed or (copy and copy.done) or false
			end
		end
		items[#items + 1] = item
	end
	return items
end

-- Project tasks and projects grouped by due date (one pass per query)
local function due_index(include_done)
	local tasks, projs = {}, {}
	for _, p in ipairs(projects().all()) do
		local pd = date_of(p.attributes.due)
		if pd and (include_done or not p:is_done()) then
			projs[pd] = projs[pd] or {}
			table.insert(projs[pd], p)
		end
		for _, task in ipairs(p:tasks()) do
			local d = date_of(task.attributes and task.attributes.due)
			if d and (include_done or not task.completed) then
				tasks[d] = tasks[d] or {}
				table.insert(tasks[d], task)
			end
		end
	end
	return tasks, projs
end

local function sort_items(items)
	table.sort(items, function(a, b)
		-- timed items first, in time order; then by priority; then text
		if (a.time ~= nil) ~= (b.time ~= nil) then
			return a.time ~= nil
		end
		if a.time and b.time and a.time ~= b.time then
			return a.time < b.time
		end
		local pa, pb = tonumber(a.priority) or 9, tonumber(b.priority) or 9
		if pa ~= pb then
			return pa < pb
		end
		return (a.text or "") < (b.text or "")
	end)
	return items
end

local function context(opts)
	local ctx = {}
	ctx.calendar_projects, ctx.calendar_path = calendar_projects()
	ctx.calendar_doc = require("zortex.services.mirrors").calendar_doc()
	ctx.due_tasks, ctx.due_projects = due_index(opts and opts.include_done)
	return ctx
end

local function day_items(date, ctx)
	local items = calendar_items(date, ctx)
	for _, task in ipairs(ctx.due_tasks[date] or {}) do
		items[#items + 1] = {
			kind = "due",
			date = date,
			text = task.text,
			done = task.completed,
			priority = task.attributes.p,
			task = task,
			project = task.project,
			file = task.file,
			lnum = task.lnum,
		}
	end
	for _, p in ipairs(ctx.due_projects[date] or {}) do
		items[#items + 1] = {
			kind = "project_due",
			date = date,
			text = p.name,
			done = p:is_done(),
			priority = p.attributes.p,
			project = p,
			file = p.file,
			lnum = p.lnum,
		}
	end
	return sort_items(items)
end

-- =============================================================================
-- Queries
-- =============================================================================

--- Items for one day ("YYYY-MM-DD").
---@param opts { include_done?: boolean }?  include done due-tasks/projects
function M.day(date, opts)
	return day_items(date, context(opts))
end

--- Days from `from` to `to` (inclusive): { { date, items }, ... }.
---@param opts { include_empty?: boolean, include_done?: boolean, kinds?: table<string, boolean> }?
function M.range(from, to, opts)
	opts = opts or {}
	local ctx = context(opts)
	local out = {}
	local date = from
	while date <= to do
		local items = day_items(date, ctx)
		if opts.kinds then
			items = vim.tbl_filter(function(i)
				return opts.kinds[i.kind]
			end, items)
		end
		if #items > 0 or opts.include_empty then
			out[#out + 1] = { date = date, items = items }
		end
		date = add_days(date, 1)
	end
	return out
end

--- Today and the following days - 1 days.
function M.upcoming(days, opts)
	local from = today_str(opts)
	return M.range(from, add_days(from, (days or 7) - 1), opts)
end

-- =============================================================================
-- Review
-- =============================================================================

local function has_schedule(project, from, to)
	return #project:schedule({ descendants = true, from = from, to = to }) > 0
end

--- What is left in the inbox: every line of inbox.zortex after its header
--- that is not blank and not a finished or carried task ([x], [>]). The web
--- app's "Add to inbox" appends here; the reviews list it to clear.
---@param path string? default: the notes folder's inbox.zortex
---@return { text: string, file: string, lnum: integer }[]
function M.inbox(path)
	path = path or require("zortex.utils.filesystem").get_inbox_file()
	local doc = path and require("zortex.core.document").get(path)
	local out = {}
	if not doc then
		return out
	end
	for lnum = (doc.header.last_lnum or 0) + 1, #doc.lines do
		local text = vim.trim(doc.lines[lnum])
		local d = doc.syntax.lines[lnum]
		local mark = d and d.item and d.item.mark
		if text ~= "" and (mark == nil or mark == " ") then
			out[#out + 1] = { text = text, file = path, lnum = lnum, inbox = true }
		end
	end
	return out
end

--- Findings for a review over the last/next `days` days:
---   overdue                 open project tasks due before today, and open
---                           calendar tasks from the last `days` days
---   due_soon                open project tasks due in the next `days` days
---   completed               tasks marked @done in the last `days` days
---   unscheduled             projects with open tasks and no calendar time in
---                           the next `days` days (sub-projects count)
---   stale                   unscheduled projects that also had no calendar
---                           time in the last `days` days
---   no_next_action          leaf projects (not done) without any tasks
---   krs_without_projects    open key results that link no project
---   objectives_without_krs  open objectives without key results
---   areas_without_projects  areas with no active project (sub-areas count)
---   broken_links            links that resolve nowhere
---   put_off                 open tasks planned on 2+ earlier days and not
---                           done (M.put_off), most often first
--- and, for the plan behind the work:
---   objectives              current objectives: { objective, progress,
---                           expected (share of its window passed), krs =
---                           { { kr, progress, lag } } }, most behind first
---   xp                      awards in the window (services/xp/ledger
---                           window_totals): xp (effort), mastery, by_alignment
---   season                  the season now (services/xp/season.status)
---   time                    time tracked on tasks in the window
---                           (services/time_spent)
---   areas_without_objective areas (two levels) no current objective names
---   unaligned               active projects with neither a key result nor
---                           an area
---   calendar                calendar entries in the window: { entries,
---                           tasks, done, open = { items } }
---   inbox                   what is left in inbox.zortex (M.inbox), then
---                           lines elsewhere marked @project(...)
---                           (services/triage.items)
---
--- opts.scope "day" (the daily review) looks back to the day after the last
--- daily review (at most 7 days; M.day_window) and ahead one day; "week"
--- (the default) `days` back and ahead.
---@param opts { days?: integer, today?: string, scope?: "day"|"week", from?: string }?
function M.review(opts)
	opts = opts or {}
	local scope = opts.scope or "week"
	local days = opts.days or 7
	local today = today_str(opts)
	local past, future
	if scope == "day" then
		past = opts.from or M.day_window(today)
		future = add_days(today, 1)
	else
		past = opts.from or add_days(today, -days)
		future = add_days(today, days - 1)
	end
	local r = {
		scope = scope,
		today = today,
		from = past,
		to = future,
		overdue = {},
		due_soon = {},
		completed = {},
		unscheduled = {},
		stale = {},
		no_next_action = {},
		krs_without_projects = {},
		objectives_without_krs = {},
		areas_without_projects = {},
		broken_links = {},
		-- the inbox, and lines elsewhere marked @project (services/triage)
		inbox = require("zortex.services.triage").items(),
	}

	-- Project tasks
	for _, p in ipairs(projects().all()) do
		for _, task in ipairs(p:tasks()) do
			local due = date_of(task.attributes.due)
			local done = date_of(task.attributes.done)
			if not task.completed and due then
				if due < today then
					table.insert(r.overdue, { kind = "due", date = due, text = task.text, task = task, project = p })
				elseif due <= future then
					table.insert(r.due_soon, { kind = "due", date = due, text = task.text, task = task, project = p })
				end
			end
			if task.completed and done and done >= past and done <= today then
				table.insert(r.completed, { kind = "due", date = done, text = task.text, task = task, project = p })
			end
		end

		if not p:is_root() and not p:is_done() then
			local rollup = p:rollup()
			if rollup.open > 0 and not has_schedule(p, today, future) then
				table.insert(r.unscheduled, p)
				if not has_schedule(p, past, add_days(today, -1)) then
					table.insert(r.stale, p)
				end
			end
			if p:is_leaf() and rollup.total == 0 then
				table.insert(r.no_next_action, p)
			end
		end
	end

	-- Calendar tasks in the review window (and lines standing for a task).
	-- Copies of project tasks and references are completed once, above;
	-- tasks carried to a later day ([>]) are neither open nor done.
	local project_ids = require("zortex.services.mirrors").project_ids()
	for _, day in ipairs(M.range(past, today)) do
		for _, item in ipairs(day.items) do
			if (item.kind == "task" or item.ref) and not item.moved then
				local id = item.entry.attributes.id
				if item.done then
					if not item.ref and not (id and project_ids[id]) then
						local done = date_of(item.entry.attributes.done) or day.date
						table.insert(r.completed, vim.tbl_extend("force", item, { date = done }))
					end
				elseif day.date < today then
					table.insert(r.overdue, item)
				end
			end
		end
	end

	local by_date = function(a, b)
		return (a.date or "") < (b.date or "")
	end
	table.sort(r.overdue, by_date)
	table.sort(r.due_soon, by_date)
	table.sort(r.completed, by_date)

	-- OKR
	local okr = require("zortex.services.okr")
	for _, kr in ipairs(okr.key_results({ open = true })) do
		if next(kr.projects) == nil then
			table.insert(r.krs_without_projects, kr)
		end
	end
	for _, o in ipairs(okr.objectives({ current = true })) do
		if #o.key_results == 0 then
			table.insert(r.objectives_without_krs, o)
		end
	end

	-- Areas
	for _, area in ipairs(require("zortex.services.areas").all({ include_roots = false })) do
		local active = vim.tbl_filter(function(p)
			return not p:is_done()
		end, area:projects({ descendants = true }))
		if #active == 0 then
			table.insert(r.areas_without_projects, area)
		end
	end

	r.broken_links = require("zortex.core.link_index").unresolved()
	r.mirror_issues = require("zortex.services.mirrors").issues()
	r.put_off = M.put_off(today)
	M.plan_findings(r, today)
	return r
end

--- Open tasks that were on the calendar and not done on at least `min`
--- earlier days (default 2), most often first: { id, count, text, task?,
--- project?, file, lnum } (the project task when it is one, else the
--- latest open calendar line).
function M.put_off(today, min)
	local mirrors = require("zortex.services.mirrors")
	local ids = mirrors.project_ids()
	local out = {}
	for id, c in pairs(mirrors.copies(today)) do
		if c.put_off >= (min or 2) and not c.done then
			local pt = ids[id]
			if pt then
				if not pt.task.completed then
					out[#out + 1] = {
						id = id,
						count = c.put_off,
						text = pt.task.text,
						task = pt.task,
						project = pt.project,
						file = pt.file,
						lnum = pt.lnum,
					}
				end
			else
				local last
				for _, t in ipairs(c.lines) do
					if t.mark == " " then
						last = t
					end
				end
				if last then
					out[#out + 1] = { id = id, count = c.put_off, text = last.text, file = last.file, lnum = last.lnum }
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return (a.text or "") < (b.text or "")
	end)
	return out
end

-- =============================================================================
-- The plan behind the work (both reviews)
-- =============================================================================

--- Objectives, XP, time, calendar and alignment findings for r.from..today.
function M.plan_findings(r, today)
	local okr = require("zortex.services.okr")
	local O = require("zortex.services.okr.objective")

	-- Current objectives: progress against the time passed
	r.objectives = {}
	for _, o in ipairs(okr.objectives({ current = true })) do
		local s, e = o:window()
		local krs = {}
		for _, kr in ipairs(o.key_results) do
			krs[#krs + 1] = { kr = kr, progress = kr:progress(), lag = kr:is_done() and 0 or kr:lag(today) }
		end
		table.sort(krs, function(a, b)
			return a.lag > b.lag
		end)
		local worst = krs[1] and krs[1].lag or 0
		r.objectives[#r.objectives + 1] = {
			objective = o,
			progress = o:progress(),
			expected = O.elapsed(s, e, today),
			krs = krs,
			lag = worst,
		}
	end
	table.sort(r.objectives, function(a, b)
		return a.lag > b.lag
	end)

	-- XP and time in the window
	local ok, between = pcall(require("zortex.services.xp.ledger").window_totals, r.from, today)
	r.xp = ok and between or { entries = {}, xp = 0, mastery = 0, by_alignment = { kr = 0, area = 0, none = 0 } }
	local ok_s, season = pcall(function()
		return require("zortex.services.xp.season").status()
	end)
	r.season = ok_s and season or nil
	r.time = require("zortex.services.time_spent").between(r.from, today)

	-- Areas no current objective names (two levels deep)
	local named = {}
	for _, x in ipairs(r.objectives) do
		for _, area in ipairs(x.objective:areas()) do
			local a = area
			while a do
				named[a.key] = true
				a = a.parent
			end
		end
	end
	r.areas_without_objective = {}
	for _, area in ipairs(require("zortex.services.areas").all({ include_roots = false })) do
		if area.depth <= 2 and not named[area.key] then
			local below = false
			for key in pairs(named) do
				if key:sub(1, #area.key + 1) == area.key .. "/" then
					below = true
				end
			end
			if not below then
				r.areas_without_objective[#r.areas_without_objective + 1] = area
			end
		end
	end

	-- Active projects with neither a key result nor an area
	local linked = {}
	for _, kr in ipairs(okr.key_results({ open = true })) do
		for key in pairs(kr:linked_projects()) do
			linked[key] = true
		end
	end
	r.unaligned = {}
	for _, p in ipairs(projects().all()) do
		if not p:is_root() and not p:is_done() and p:rollup().open > 0 then
			local on_kr = false
			local x = p
			while x and not on_kr do
				on_kr = linked[x.key] == true
				x = x.parent
			end
			if not on_kr and #p:areas({ inherit = true }) == 0 then
				r.unaligned[#r.unaligned + 1] = p
			end
		end
	end

	-- The calendar in the window: how many entries, tasks done, tasks left
	r.calendar = { entries = 0, tasks = 0, done = 0, open = {} }
	for _, day in ipairs(M.range(r.from, today)) do
		for _, item in ipairs(day.items) do
			if item.entry then
				r.calendar.entries = r.calendar.entries + 1
				if item.entry.type == "task" then
					r.calendar.tasks = r.calendar.tasks + 1
					if item.done then
						r.calendar.done = r.calendar.done + 1
					else
						r.calendar.open[#r.calendar.open + 1] = item
					end
				end
			end
		end
	end
	return r
end

-- =============================================================================
-- Where the daily review starts
-- =============================================================================

local function review_state()
	return require("zortex.core.state").open("review_state", {
		version = 1,
		default = function()
			return {}
		end,
	})
end

--- The first day the daily review covers: the day after the last daily
--- review (the same window again when it was today), at most 7 days back.
function M.day_window(today)
	local st = review_state():get()
	local earliest = add_days(today, -6)
	local from
	if st.last_day == today and st.from then
		from = st.from
	elseif st.last_day and st.last_day < today then
		from = add_days(st.last_day, 1)
	else
		from = today
	end
	if from < earliest then
		from = earliest
	end
	if from > today then
		from = today
	end
	return from
end

--- Remember that the daily review covered from..today.
function M.mark_day_reviewed(today, from)
	local st = review_state()
	local d = st:get()
	d.last_day, d.from = today, from
	st:save()
end

return M
