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
	local items = {}
	for _, entry in ipairs(require("zortex.stores.calendar").get_entries_for_date(date)) do
		items[#items + 1] = {
			kind = entry.type,
			date = date,
			time = entry:get_time_string(),
			text = entry.display_text,
			done = entry.type == "task" and entry.task and entry.task.completed or false,
			priority = entry.attributes.p,
			entry = entry,
			project = ctx.calendar_projects[entry.lnum],
			file = ctx.calendar_path,
			lnum = entry.lnum,
		}
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
---@param opts { days?: integer, today?: string }?
function M.review(opts)
	opts = opts or {}
	local days = opts.days or 7
	local today = today_str(opts)
	local past = add_days(today, -days)
	local future = add_days(today, days - 1)
	local r = {
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

	-- Calendar tasks in the review window
	for _, day in ipairs(M.range(past, today, { kinds = { task = true } })) do
		for _, item in ipairs(day.items) do
			if item.done then
				local done = date_of(item.entry.attributes.done) or day.date
				table.insert(r.completed, vim.tbl_extend("force", item, { date = done }))
			elseif day.date < today then
				table.insert(r.overdue, item)
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
	return r
end

return M
