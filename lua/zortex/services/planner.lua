-- services/planner.lua - What to put on today's calendar
--
-- The data behind :ZortexPlan (ui/planner.lua). Everything here is plain
-- data, so the web app can show the same lists.
--
--   candidates({ today })  -> { tasks, projects, key_results, areas, todos, groups, inbox }
--       each candidate: { kind, text, badges, score, file, lnum }
--       `text` is what gets written into the calendar: the item's text and
--       an explicit link to it ("Improve website [P/#1 Programming/#1.4 - zortex/-Improve website]")
--   template(date)          -> template lines for a new calendar day
--   put(line, col, text)    -> the line with `text` put at the cursor
--   add_task(date, c)       -> a project task onto the day as a copy with its
--                              @id (services/mirrors), under the day's block
--                              for its project when there is one
--   add_project(date, c)    -> a block for the project with its open tasks
--   carry(lines, today, opts) / carry_forward(date)
--                           -> open tasks of earlier days copied to the day
--                              (same @id), the old lines marked [>]
--
-- Ranking: the week's focus projects (services/review: the projects linked
-- under "Focus:" in the week's entry of reviews.zortex) come first, their
-- tasks too. Then signals add up, so a TODO with a high priority that is
-- also due beats any one of those alone (weights in M.weights). Alignment
-- counts most: work on a key result ranks above work that only has an area,
-- which ranks above work with neither, and a key result that is behind
-- schedule (its objective's time passing faster than its progress) pushes
-- its projects' tasks up further. A task that was on the calendar and not
-- done (put off, services/mirrors) ranks higher each day that happened.
local M = {}

local function Config()
	return require("zortex.config")
end

local function cfg()
	local ui = Config().ui or {}
	return ui.planner or {}
end

local datetime = require("zortex.utils.datetime")

M.weights = {
	todo = 3, -- task in the TODO project (ui.planner.todo_link)
	priority = { ["1"] = 3, ["2"] = 2, ["3"] = 1 }, -- @p
	importance = { ["1"] = 2, ["2"] = 1 }, -- @i
	overdue = 4,
	due_today = 3,
	due_3d = 2,
	due_7d = 1,
	okr = 2, -- project linked from an open key result
	kr_behind = 4, -- more, up to this, the further behind its key result is
	kr_behind_full = 0.25, -- ... reached at 25% behind schedule
	area = 1, -- project (or task) with an area but no key result
	project_priority = { ["1"] = 1 }, -- the project's own @p
	put_off = 1, -- per earlier day the task was on the calendar and not done ...
	put_off_max = 5, -- ... up to this
}

-- =============================================================================
-- Helpers
-- =============================================================================

local function today(opts)
	return datetime.parse_date((opts and opts.today) or os.date("%Y-%m-%d"))
end

local function days_until(date, from)
	if type(date) ~= "table" or not date.year then
		return nil
	end
	return datetime.days_between(from, date)
end

--- Explicit link to a list item: its project's (or section's) link plus
--- "-<key or text>".
function M.item_link(base_link, line)
	local comp = require("zortex.core.link").item_component(line)
	if not base_link or not comp then
		return base_link
	end
	return base_link:sub(1, -2) .. "/" .. comp .. "]"
end

-- Text without its links ("Ship it [P/#X]" -> "Ship it"): the candidate
-- gets one explicit link of its own.
local function plain(text)
	local syntax = require("zortex.core.syntax")
	local out, pos = {}, 1
	for _, span in ipairs(syntax.links(text)) do
		out[#out + 1] = text:sub(pos, span.s)
		pos = span.e + 1
	end
	out[#out + 1] = text:sub(pos)
	return vim.trim((table.concat(out):gsub("%s+", " ")))
end
M.plain = plain

local function todo_project()
	local link = cfg().todo_link
	if not link or link == "" then
		return nil
	end
	local ok, p = pcall(require("zortex.services.projects").resolve, "[" .. link:gsub("^%[", ""):gsub("%]$", "") .. "]")
	return ok and p or nil
end

local function in_subtree(project, root)
	local p = project
	while p do
		if p == root or p.key == root.key then
			return true
		end
		p = p.parent
	end
	return false
end

-- =============================================================================
-- Candidates
-- =============================================================================

-- Open key results linking a project or an ancestor: the one furthest
-- behind, and how far ({ kr, lag }), or nil.
local function kr_for(project, ctx)
	local best
	local p = project
	while p do
		for _, kr in ipairs(ctx.krs[p.key] or {}) do
			local lag = kr:lag(ctx.today_str)
			if not best or lag > best.lag then
				best = { kr = kr, lag = lag }
			end
		end
		p = p.parent
	end
	return best
end

-- Score for alignment: key result (more when behind), else area, else 0
local function alignment(project, task, ctx)
	local w = M.weights
	local link = ctx.kr_of[project]
	if link == nil then
		link = kr_for(project, ctx) or false
		ctx.kr_of[project] = link
	end
	if link then
		local behind = math.min(1, link.lag / w.kr_behind_full)
		local badge = link.kr.id
		if link.lag >= 0.05 then
			badge = string.format("%s %d%% behind", link.kr.id, math.floor(link.lag * 100 + 0.5))
		end
		return w.okr + w.kr_behind * behind, { "OKR", badge }
	end
	local has_area = (task and task.attributes and task.attributes.area) or #project:areas({ inherit = true }) > 0
	if has_area then
		return w.area, { "area" }
	end
	return 0, {}
end
M._alignment = alignment

-- The project, or one of its ancestors, is a focus project of the week
local function focus_of(project, ctx)
	if not ctx.focus or next(ctx.focus) == nil then
		return false
	end
	local p = project
	while p do
		if ctx.focus[p.key] then
			return true
		end
		p = p.parent
	end
	return false
end

local function score_task(task, project, ctx)
	local w, attrs = M.weights, task.attributes or {}
	local score, badges = 0, {}
	if ctx.todo and in_subtree(project, ctx.todo) then
		score = score + w.todo
		badges[#badges + 1] = "TODO"
	end
	if w.priority[attrs.p] then
		score = score + w.priority[attrs.p]
		badges[#badges + 1] = "P" .. attrs.p
	end
	if w.importance[attrs.i] then
		score = score + w.importance[attrs.i]
		badges[#badges + 1] = "I" .. attrs.i
	end
	local days = days_until(attrs.due, ctx.today)
	if days then
		if days < 0 then
			score = score + w.overdue
			badges[#badges + 1] = "overdue " .. datetime.format_datetime(attrs.due, "MM-DD")
		elseif days == 0 then
			score = score + w.due_today
			badges[#badges + 1] = "due today"
		elseif days <= 3 then
			score = score + w.due_3d
			badges[#badges + 1] = "due " .. datetime.format_datetime(attrs.due, "MM-DD")
		elseif days <= 7 then
			score = score + w.due_7d
			badges[#badges + 1] = "due " .. datetime.format_datetime(attrs.due, "MM-DD")
		end
	end
	local a, a_badges = alignment(project, task, ctx)
	score = score + a
	vim.list_extend(badges, a_badges)
	-- planned before and not done: the more often, the higher
	local id = task.attributes and task.attributes.id
	local n = id and require("zortex.services.mirrors").put_off(id, ctx.today_str) or 0
	if n > 0 then
		score = score + math.min(n * w.put_off, w.put_off_max)
		badges[#badges + 1] = "put off ×" .. n
	end
	if focus_of(project, ctx) then
		table.insert(badges, 1, "focus")
	end
	local pp = w.project_priority[project.attributes.p]
	if pp and score > 0 then
		score = score + pp
	end
	return score, badges
end

-- Focus projects' work first (this week's focus, services/review), then by
-- score
local function sort_by_score(list)
	table.sort(list, function(a, b)
		if (a.focus or false) ~= (b.focus or false) then
			return a.focus == true
		end
		if a.score ~= b.score then
			return a.score > b.score
		end
		return (a.text or "") < (b.text or "")
	end)
	return list
end

--- Everything worth considering for a day, ranked.
---@param opts { today?: string, max_tasks?: integer }?
function M.candidates(opts)
	opts = opts or {}
	local projects = require("zortex.services.projects")
	local score = require("zortex.services.projects.score")
	local ctx = { today = today(opts), todo = todo_project(), krs = {}, kr_of = {} }
	ctx.today_str = datetime.format_datetime(ctx.today, "YYYY-MM-DD")
	-- this week's focus projects (the weekly review in the reviews note)
	local focus_ok, focus = pcall(require("zortex.services.review").focus, ctx.today_str)
	ctx.focus = {}
	ctx.focus_week = focus_ok and focus and focus.week or nil
	for _, p in ipairs(focus_ok and focus and focus.projects or {}) do
		ctx.focus[p.key] = true
	end
	-- open key results by the project keys they link
	local okr_ok, open_krs = pcall(require("zortex.services.okr").key_results, { open = true })
	for _, kr in ipairs(okr_ok and open_krs or {}) do
		if not (kr.objective and kr.objective.completed) then
			for key in pairs(kr:linked_projects()) do
				ctx.krs[key] = ctx.krs[key] or {}
				table.insert(ctx.krs[key], kr)
			end
		end
	end

	-- Project tasks
	local tasks = {}
	for _, p in ipairs(projects.all()) do
		for _, task in ipairs(p:tasks()) do
			-- a group is one candidate (its tasks are ticked in the note);
			-- one whose tasks are all done is done
			local open = not task.completed and not task.parent_task and (task.leaf ~= false or (task.open_leaves or 0) > 0)
			if open then
				local s, badges = score_task(task, p, ctx)
				if task.leaf == false then
					local leaves = #require("zortex.services.task_groups").leaves(vim.tbl_filter(function(t)
						local up = t.parent_task
						while up and up ~= task do
							up = up.parent_task
						end
						return up == task
					end, p:tasks()))
					badges[#badges + 1] = string.format("%d of %d tasks open", task.open_leaves, leaves)
				end
				local focused = focus_of(p, ctx)
				if s > 0 or focused then
					badges[#badges + 1] = p.name
					tasks[#tasks + 1] = {
						-- a to-do rather than project work: in the TODO project
						-- (ui.planner.todo_link) or the Projects note's own list
						todo = p:is_root() or (ctx.todo ~= nil and in_subtree(p, ctx.todo)) or nil,
						project_name = p.name,
						kind = "task",
						text = plain(task.text) .. " " .. M.item_link(p.link, task.raw_text),
						link = M.item_link(p.link, task.raw_text),
						component = require("zortex.core.link").item_component(task.raw_text),
						project_key = p.key,
						project_link = p.link,
						badges = badges,
						score = s,
						focus = focused or nil,
						file = task.file,
						lnum = task.lnum,
					}
				end
			end
		end
	end

	-- Open calendar tasks from earlier days
	local ok, review = pcall(require("zortex.services.agenda").review, {
		today = datetime.format_datetime(ctx.today, "YYYY-MM-DD"),
		days = 14,
	})
	if ok then
		local project_ids = require("zortex.services.mirrors").project_ids()
		for _, item in ipairs(review.overdue) do
			local id = item.entry and item.entry.attributes.id
			-- a copy of a project task is listed as that task (above)
			if item.entry and item.entry.type == "task" and not (id and project_ids[id]) then
				local doc = require("zortex.core.document").get(item.file)
				local node = doc and doc:node_at(item.lnum)
				local base = node and require("zortex.core.link").link_for_node(doc, node)
				tasks[#tasks + 1] = {
					kind = "task",
					text = plain(item.text) .. " " .. (M.item_link(base, item.entry.raw_text) or ""),
					badges = { "overdue " .. item.date:sub(6), "calendar" },
					score = M.weights.overdue,
					file = item.file,
					lnum = item.lnum,
				}
			end
		end
	end
	sort_by_score(tasks)
	local max = opts.max_tasks or cfg().max_tasks or 30
	if #tasks > max then
		tasks = vim.list_slice(tasks, 1, max)
	end

	-- Projects: OKR-linked or high priority/importance, with open work
	local function project_candidate(p)
		local r = p:rollup()
		local a, a_badges = alignment(p, nil, ctx)
		local badges = score.indicators(p)
		for _, b in ipairs(a_badges) do
			if b ~= "OKR" and b ~= "area" then
				badges[#badges + 1] = b
			end
		end
		local focused = focus_of(p, ctx)
		if focused then
			table.insert(badges, 1, "focus")
		end
		badges[#badges + 1] = string.format("%d/%d", r.done, r.total)
		for _, t in ipairs(p:tasks()) do
			if not t.completed and not t.parent_task then
				badges[#badges + 1] = "next: " .. t.text
				break
			end
		end
		return {
			kind = "project",
			text = p.link,
			project_key = p.key,
			project_link = p.link,
			badges = badges,
			score = score.project_score(p) + a,
			focus = focused or nil,
			file = p.file,
			lnum = p.lnum,
		}
	end
	local plist = {}
	for _, p in ipairs(projects.all()) do
		local attrs = p.attributes
		local high = (tonumber(attrs.p) or 9) <= 2 or (tonumber(attrs.i) or 9) <= 2
		local _ = alignment(p, nil, ctx) -- fills ctx.kr_of[p]
		if not p:is_root() and not p:is_done() and p:rollup().open > 0 and (ctx.kr_of[p] or high or focus_of(p, ctx)) then
			plist[#plist + 1] = project_candidate(p)
		end
	end
	sort_by_score(plist)

	-- Key results: open, of current objectives
	local krs = {}
	for _, o in ipairs(require("zortex.services.okr").objectives({ current = true })) do
		for _, kr in ipairs(o.key_results) do
			if not kr:is_done() then
				local progress, lag = kr:progress(), kr:lag(ctx.today_str)
				local badges = { kr.id, string.format("%d%%", progress * 100), o.title }
				if lag >= 0.05 then
					table.insert(badges, 3, string.format("%d%% behind", math.floor(lag * 100 + 0.5)))
				end
				krs[#krs + 1] = {
					kind = "key_result",
					text = plain(kr.text) .. " " .. (kr.link or o.link),
					badges = badges,
					-- furthest behind first, then least done
					score = lag * 10 + (1 - progress),
					file = kr.file,
					lnum = kr.lnum,
				}
			end
		end
	end
	sort_by_score(krs)

	-- Areas: two levels deep; areas without a current objective first (they
	-- have no key results pulling work toward them), then fewest projects
	local areas = {}
	local with_objective = {}
	for _, o in ipairs(require("zortex.services.okr").objectives({ current = true })) do
		for _, area in ipairs(o:areas()) do
			local x = area
			while x do
				with_objective[x.key] = true
				x = x.parent
			end
		end
	end
	for _, a in ipairs(require("zortex.services.areas").all({ include_roots = false })) do
		if a.depth <= 2 then
			local active = 0
			for _, p in ipairs(a:projects({ descendants = true })) do
				if not p:is_done() then
					active = active + 1
				end
			end
			local badges = { active == 0 and "no active projects" or (active .. " active") }
			if not with_objective[a.key] then
				table.insert(badges, 1, "no objective")
			end
			areas[#areas + 1] = {
				kind = "area",
				text = a.link,
				badges = badges,
				score = (with_objective[a.key] and -10 or 0) - active,
				file = a.file,
				lnum = a.lnum,
			}
		end
	end
	sort_by_score(areas)

	local todos, groups = M.group(tasks, plist, function(key)
		local p = projects.get(key)
		return p and project_candidate(p)
	end)
	-- What is left in the inbox, as written: p puts a line on the day
	-- ("- [ ] Call the plumber"); the reviews are where it is cleared
	local inbox = {}
	local inbox_ok, left = pcall(require("zortex.services.agenda").inbox)
	for _, x in ipairs(inbox_ok and left or {}) do
		inbox[#inbox + 1] = { kind = "inbox", text = (x.text:gsub("^[-*+]%s+", "")), file = x.file, lnum = x.lnum }
	end
	return {
		tasks = tasks,
		projects = plist,
		key_results = krs,
		areas = areas,
		todos = todos,
		groups = groups,
		inbox = inbox,
		focus_week = ctx.focus_week,
	}
end

--- Split ranked tasks into to-dos (the TODO project, the Projects note's own
--- tasks, open calendar tasks of earlier days) and one group per project:
--- { project = <project candidate>, tasks = { ... } }. Groups come in the
--- order of their best task; projects from `plist` without a ranked task
--- follow, in their own order. `make_project(key)` gives the heading of a
--- project not in `plist`.
function M.group(tasks, plist, make_project)
	local todos, groups, by_key = {}, {}, {}
	local listed = {}
	for _, p in ipairs(plist) do
		listed[p.project_key] = p
	end
	for _, t in ipairs(tasks) do
		if t.todo or not t.project_key then
			todos[#todos + 1] = t
		else
			local g = by_key[t.project_key]
			if not g then
				local project = listed[t.project_key]
					or (make_project and make_project(t.project_key))
					or { kind = "project", text = t.project_link, project_key = t.project_key, project_link = t.project_link, badges = {} }
				g = { project = project, tasks = {} }
				by_key[t.project_key] = g
				groups[#groups + 1] = g
			end
			g.tasks[#g.tasks + 1] = t
		end
	end
	for _, p in ipairs(plist) do
		if not by_key[p.project_key] then
			by_key[p.project_key] = true
			groups[#groups + 1] = { project = p, tasks = {} }
		end
	end
	return todos, groups
end

-- =============================================================================
-- Capacity: the day's planned work against the time it has
-- =============================================================================

local function clock_minutes(t)
	if type(t) == "table" and t.hour then
		return t.hour * 60 + (t.min or 0)
	elseif type(t) == "string" then
		local h, m = t:match("^(%d%d?):(%d%d)")
		if h then
			return tonumber(h) * 60 + tonumber(m)
		end
	end
	return nil
end

-- Minutes of work in a task: @dur / @est on its line, else its @size
-- (xp.sizes.task hours; unsized = md). `project_task`: the project's task
-- it is a copy of; a group (services/task_groups) weighs its open work.
local function task_minutes(attrs, project_task)
	attrs = attrs or {}
	local explicit = attrs.dur or attrs.est
	if type(explicit) == "number" and explicit > 0 then
		return explicit, false
	end
	local fallback = project_task and project_task.attributes
	local size = attrs.size or (fallback and fallback.size)
	if project_task and project_task.leaf == false then
		return (project_task.open_hours or 0) * 60, false
	end
	if not attrs.size and project_task and project_task.hours then
		return project_task.hours * 60, size == nil
	end
	local calc = require("zortex.services.xp.calculator")
	return calc.task_points(size) * 60, size == nil
end

--- How the work planned on `date` compares with the free time it has.
---   planned  minutes of open tasks on the day (copies of project tasks
---            weigh the project task's @size; @dur / @est win)
---   done     minutes of the day's tasks already checked
---   busy     minutes of timed entries that aren't work on a project or task
---            (a lecture, a meeting) within the window still ahead; one
---            without an end counts ui.planner.capacity.event_minutes
---   free     the window (ui.planner.capacity.day, from now when `date` is
---            today) minus busy
---   over     planned - free (negative: time to spare)
---   tasks, unsized   how many open tasks, and how many without a size
---@param opts { now?: string, today?: string }?  "HH:MM" and "YYYY-MM-DD" (tests)
function M.capacity(date, opts)
	opts = opts or {}
	local conf = cfg().capacity or {}
	local window = conf.day or { "08:00", "22:00" }
	local w_from, w_to = clock_minutes(window[1]) or 480, clock_minutes(window[2]) or 1320
	local today_str = opts.today or os.date("%Y-%m-%d")
	if date == today_str then
		local now = clock_minutes(opts.now or os.date("%H:%M"))
		if now and now > w_from then
			w_from = math.min(now, w_to)
		end
	elseif date < today_str then
		w_from = w_to -- nothing left of a past day
	end
	local event_default = conf.event_minutes or 30

	local project_ids = require("zortex.services.mirrors").project_ids()
	local out = { planned = 0, done = 0, busy = 0, tasks = 0, unsized = 0, from = w_from, to = w_to }
	for _, item in ipairs(require("zortex.services.agenda").day(date)) do
		local entry = item.entry
		if entry and not item.moved then
			local task_attrs, linked
			if entry.type == "task" then
				task_attrs = entry.attributes
				local id = entry.attributes.id
				linked = id and project_ids[id] and project_ids[id].task
			elseif item.ref then
				task_attrs = item.ref.task.attributes
			end
			if task_attrs then
				local mins, unsized = task_minutes(task_attrs, linked)
				if item.done then
					out.done = out.done + mins
				else
					out.planned = out.planned + mins
					out.tasks = out.tasks + 1
					if unsized then
						out.unsized = out.unsized + 1
					end
				end
			elseif entry.type == "event" and not item.project then
				-- a commitment: the part of it inside what is left of the window
				local s = clock_minutes(entry.timing and entry.timing.start)
				if s then
					local len = entry:get_duration() or event_default
					local e = s + len
					local overlap = math.min(e, w_to) - math.max(s, w_from)
					if overlap > 0 then
						out.busy = out.busy + overlap
					end
				end
			end
		end
	end
	out.free = math.max(0, (w_to - w_from) - out.busy)
	out.over = out.planned - out.free
	return out
end

local function hm(minutes)
	minutes = math.floor((minutes or 0) + 0.5)
	if minutes <= 0 then
		return "0h"
	end
	return require("zortex.utils.attributes").format_duration(minutes)
end
M.format_minutes = hm

local function clock(minutes)
	return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

--- One line for the planner: "Capacity: 5h30m planned (4 tasks) · 4h free
--- (13:20-22:00, 1h busy) · 1h30m over".
function M.capacity_line(c)
	local parts = {}
	local planned = hm(c.planned) .. " planned"
	if c.tasks > 0 then
		planned = planned .. string.format(" (%d task%s%s)", c.tasks, c.tasks == 1 and "" or "s", c.unsized > 0 and string.format(", %d unsized", c.unsized) or "")
	end
	parts[#parts + 1] = planned
	local free = hm(c.free) .. " free"
	if c.to > c.from then
		free = free .. " (" .. clock(c.from) .. "-" .. clock(c.to) .. (c.busy > 0 and (", " .. hm(c.busy) .. " busy") or "") .. ")"
	end
	parts[#parts + 1] = free
	if c.over > 0 then
		parts[#parts + 1] = hm(c.over) .. " over"
	else
		parts[#parts + 1] = hm(-c.over) .. " to spare"
	end
	if c.done > 0 then
		parts[#parts + 1] = hm(c.done) .. " done"
	end
	return "Capacity: " .. table.concat(parts, " · ")
end

-- =============================================================================
-- Templates and putting text
-- =============================================================================

local WEEKDAYS = { "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" }

--- Template lines for a new day: ui.planner.templates[<weekday name>], else
--- .saturday / .sunday, else .weekday.
function M.template(date)
	local d = type(date) == "string" and datetime.parse_date(date) or date
	local wday = os.date("*t", os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })).wday
	local name = WEEKDAYS[wday]
	local templates = cfg().templates or {}
	local lines = templates[name]
	if not lines and name ~= "saturday" and name ~= "sunday" then
		lines = templates.weekday
	end
	return vim.deepcopy(lines or {})
end

--- Put `text` into `line` at the cursor (0-based byte `col`), the way `p`
--- would, with single spaces around it. Text never lands inside a list or
--- time marker ("09:00" + text -> "09:00 text"); on a blank line the text
--- becomes an entry ("- text"). Returns the new line and the 0-based column
--- of the end of the inserted text.
function M.put(line, col, text)
	text = vim.trim(text)
	if not line:find("%S") then
		local indent = line:match("^%s*")
		local new = indent .. "- " .. text
		return new, #new - 1
	end
	local at = math.min(col + 1, #line) -- after the cursor character
	local it = require("zortex.core.syntax").item(line)
	local slot = line:match("^%s*%d%d?:%d%d%s*%-%s*%d%d?:%d%d") or line:match("^%s*%d%d?:%d%d")
	local min = math.max((it and it.content_col) or 0, slot and #slot or 0)
	if at < min then
		at = min
	end
	local left, right = line:sub(1, at), line:sub(at + 1)
	if left ~= "" and not left:match("%s$") then
		left = left .. " "
	end
	if right ~= "" and not right:match("^%s") then
		text = text .. " "
	end
	local new = left .. text .. right
	return new, #left + #vim.trim(text) - 1
end

-- =============================================================================
-- Copies on the calendar (services/mirrors)
-- =============================================================================

local function link_mod()
	return require("zortex.core.link")
end

local function indent_of(line)
	return #line:match("^[ \t]*")
end

local function calendar_target()
	return require("zortex.utils.filesystem").get_calendar_file()
end

--- The line in the day's block (block from stores/calendar.date_block) that
--- heads `project_key`: not a task, its first link points at the project
--- itself (its heading, or its note). Returns its line number and the last
--- line of what's nested under it.
function M.find_block(lines, block, project_key)
	local projects = require("zortex.services.projects")
	local syntax = require("zortex.core.syntax")
	local want = projects.get(project_key)
	for l = block.heading_lnum + 1, block.last_lnum do
		local line = lines[l]
		local first = want and line:find("[", 1, true) and link_mod().links_on(line)[1]
		local it = first and syntax.item(line)
		if first and not (it and it.mark) then
			local def = link_mod().absolute(first.definition, lines, l)
			local ok, r = pcall(link_mod().resolve_first, def and ("[" .. def .. "]") or "")
			local p = ok and r and projects.at(r.file, r.lnum)
			if p and p.key == project_key and (r.lnum == p.lnum or r.whole) then
				local last = l
				for k = l + 1, block.last_lnum do
					if lines[k]:match("%S") then
						if indent_of(lines[k]) <= indent_of(line) then
							break
						end
						last = k
					end
				end
				return l, last
			end
		end
	end
	return nil
end

local function day_has_id(lines, block, id)
	local needle = "@id(" .. id .. ")"
	for l = block.heading_lnum + 1, block.last_lnum do
		if lines[l]:find(needle, 1, true) then
			return l
		end
	end
	return nil
end

-- The day's block (created from the template when missing) and the lines.
local function day_block(date)
	local calendar = require("zortex.stores.calendar")
	local workspace = require("zortex.core.workspace")
	local target = calendar_target()
	local block = calendar.date_block(date, workspace.get_lines(target))
	if not block then
		calendar.ensure_date(date, M.template(date))
		block = calendar.date_block(date, workspace.get_lines(target))
	end
	return block, workspace.get_lines(target)
end

--- The copy of a project task candidate (file, lnum, link, component):
--- "[ ] <link> @id(x)", the task getting its @id first when it has none.
--- opts.relative: "[ ] [./-Item] @id(x)", for under the project's block.
function M.copy_text(c, opts)
	local id, err = require("zortex.services.mirrors").ensure_id(c.file, c.lnum)
	if not id then
		return nil, err
	end
	local link = (opts and opts.relative and c.component) and ("[./" .. c.component .. "]") or c.link
	return "[ ] " .. link .. " @id(" .. id .. ")", id
end

--- Put a project task (a candidate with file, lnum, link, component,
--- project_key) on `date`: under the day's block for its project
--- ("09:00 [P/#1.4 - zortex]") as "  - [ ] [./-Item] @id(x)", else at the end
--- of the day with its full link. Nothing is added when the day already has
--- a line with its @id. Returns that calendar line and whether it is new.
function M.add_task(date, c)
	if not (c.file and c.lnum and c.link) then
		return nil, false
	end
	local workspace = require("zortex.core.workspace")
	local block, lines = day_block(date)
	if not block then
		return nil, false
	end
	local id = require("zortex.services.mirrors").ensure_id(c.file, c.lnum)
	if not id then
		return nil, false
	end
	local existing = day_has_id(lines, block, id)
	if existing then
		return existing, false
	end
	local head, last
	if c.project_key then
		head, last = M.find_block(lines, block, c.project_key)
	end
	local line, at
	if head then
		line = string.rep(" ", indent_of(lines[head]) + 2) .. "- " .. M.copy_text(c, { relative = true })
		at = last + 1
	else
		line = "- " .. M.copy_text(c)
		at = block.last_lnum + 1
	end
	workspace.insert_lines(calendar_target(), at, { line })
	return at, true
end

--- Put a project on `date`: a block "- [P/...]" (unless the day has one)
--- with its next open tasks copied under it: the first `opts.count` open
--- tasks of its own, in note order (ui.planner.project_tasks, default 3;
--- tasks already on the day count toward them). c: a candidate with
--- project_key. Returns the block's line and how many tasks were added.
---@param opts { count?: integer }?
function M.add_project(date, c, opts)
	local projects = require("zortex.services.projects")
	local p = c.project_key and projects.get(c.project_key)
	if not p then
		return nil, 0
	end
	local count = (opts and opts.count) or cfg().project_tasks or 3
	local workspace = require("zortex.core.workspace")
	local block, lines = day_block(date)
	if not block then
		return nil, 0
	end
	local head = M.find_block(lines, block, p.key)
	if not head then
		head = block.last_lnum + 1
		workspace.insert_lines(calendar_target(), head, { "- " .. p.link })
	end
	local added, taken = 0, 0
	for _, t in ipairs(p:tasks()) do
		if taken >= count then
			break
		end
		-- a group goes as one task; its tasks stay in the note
		if not t.completed and not t.parent_task and (t.leaf ~= false or (t.open_leaves or 0) > 0) then
			taken = taken + 1
			local _, ok = M.add_task(date, {
				file = t.file,
				lnum = t.lnum,
				link = M.item_link(p.link, t.raw_text),
				component = link_mod().item_component(t.raw_text),
				project_key = p.key,
			})
			if ok then
				added = added + 1
			end
		end
	end
	return head, added
end

-- =============================================================================
-- Carrying open tasks forward
-- =============================================================================

local DATE_LINE = "^(%d%d%d%d)%-(%d%d)%-(%d%d):%s*$"

local function day_number(date_str)
	local y, m, d = date_str:match("^(%d+)%-(%d+)%-(%d+)$")
	return math.floor(os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) / 86400)
end

local function is_fence(line)
	local t = vim.trim(line)
	return t:sub(1, 3) == "```" or t:sub(1, 3) == "~~~"
end

-- line:sub(from + 1) of line `lnum`, with its parent-relative links
-- ([./-Item]) written out in full where they resolve
local function absolute_text(lines, lnum, from)
	local line = lines[lnum]
	local out, pos = {}, from + 1
	for _, span in ipairs(link_mod().links_on(line)) do
		if span.s >= from and link_mod().is_parent_relative(span.definition) then
			local abs = link_mod().absolute(span.definition, lines, lnum)
			if abs then
				out[#out + 1] = line:sub(pos, span.s)
				out[#out + 1] = "[" .. abs .. "]"
				pos = span.e + 1
			end
		end
	end
	out[#out + 1] = line:sub(pos)
	return table.concat(out)
end

--- What carrying the open tasks of the days in [opts.from, today) to
--- `today` changes in the calendar's `lines` (pure; app/edit Carry is the
--- same, checked against tests/fixtures/carry.json):
---   edits  { { lnum, line } }: each carried task marked [>] (moved), with an
---          @id (opts.new_id() when it had none)
---   inserts { { at, lines } }, ascending: insert `lines` before line `at`:
---          the copies, with the same @id, at the end of today's block (or a
---          new "YYYY-MM-DD:" block for them placed by date); copies whose
---          block today already has (a line whose first link is the same)
---          go at the end of that block instead
--- A task nested under a linked line that isn't a task ("09:00
--- [P/#1.4 - zortex]") is copied under a copy of that line ("- [P/#1.4 -
--- zortex]", the time dropped; same lines merge), its [./-Item] links kept
--- when that line is their parent; other tasks become "- [ ] ..." with
--- their [./-Item] links written out. Repeating entries (@repeat) stay
--- where they are; a task whose @id is already on today is only marked.
---@param opts { from?: string, new_id: fun(): string }
function M.carry(lines, today, opts)
	local syntax = require("zortex.core.syntax")
	local attributes = require("zortex.utils.attributes")
	local moved = require("zortex.services.mirrors").MOVED
	local blocks, fence = {}, false
	for i, l in ipairs(lines) do
		if is_fence(l) then
			fence = not fence
		elseif not fence then
			local y, m, d = l:match(DATE_LINE)
			if y then
				blocks[#blocks + 1] = { date = y .. "-" .. m .. "-" .. d, heading = i }
			end
		end
	end
	for i, b in ipairs(blocks) do
		local stop = blocks[i + 1] and (blocks[i + 1].heading - 1) or #lines
		b.last = b.heading
		for l = b.heading + 1, stop do
			if lines[l]:match("%S") then
				b.last = l
			end
		end
	end
	local today_block
	for _, b in ipairs(blocks) do
		if b.date == today and not today_block then
			today_block = b
		end
	end
	local on_today = {}
	if today_block then
		for l = today_block.heading + 1, today_block.last do
			local id = lines[l]:match("@id%(([^)%s]+)%)")
			if id then
				on_today[id] = true
			end
		end
	end

	local edits, groups, order, carried, head_def = {}, {}, {}, {}, {}
	-- a linked line's first link, written out (how blocks are matched)
	local function first_def(lnum)
		local first = link_mod().links_on(lines[lnum])[1]
		local def = first and link_mod().absolute(first.definition, lines, lnum)
		return def and vim.trim(def):lower() or nil
	end
	for _, b in ipairs(blocks) do
		if b.date >= (opts.from or "") and b.date < today then
			local in_fence = false
			for l = b.heading + 1, b.last do
				local line = lines[l]
				local it = not in_fence and not is_fence(line) and syntax.item(line)
				if is_fence(line) then
					in_fence = not in_fence
				elseif it and it.mark == " " and not line:find("@repeat(", 1, true) then
					-- the nearest linked line above it that isn't a task (head),
					-- and the nearest linked one (its ./ links' parent)
					local head, parent
					local want = indent_of(line)
					for k = l - 1, b.heading + 1, -1 do
						local up = lines[k]
						if up:match("%S") and indent_of(up) < want then
							local up_it = syntax.item(up)
							if #link_mod().links_on(up) > 0 then
								parent = parent or k
								if not (up_it and up_it.mark) then
									head = k
									break
								end
							end
							want = indent_of(up)
							if want == 0 then
								break
							end
						end
					end
					local id = line:match("@id%(([^)%s]+)%)")
					local marked = line:sub(1, it.mark_col + 1) .. moved .. line:sub(it.mark_col + 3)
					if not id then
						id = opts.new_id()
						marked = attributes.add_attribute(marked, "id", id)
					end
					edits[#edits + 1] = { lnum = l, line = marked }
					if not on_today[id] and not carried[id] then
						carried[id] = true
						local copy, key
						if head then
							-- [./-Item] links stay relative when the copy keeps their parent
							copy = "  - "
								.. (parent == head and line:sub(it.mark_col + 1) or absolute_text(lines, l, it.mark_col))
							local hit = syntax.item(lines[head])
							key = "- " .. absolute_text(lines, head, hit and hit.content_col or indent_of(lines[head]))
							head_def[key] = head_def[key] or first_def(head)
						else
							copy = "- " .. absolute_text(lines, l, it.mark_col)
							key = ""
						end
						copy = attributes.add_attribute(copy, "id", id)
						if not groups[key] then
							groups[key] = {}
							order[#order + 1] = key
						end
						table.insert(groups[key], copy)
					end
				end
			end
		end
	end

	-- today's blocks by their first link: carried copies join them
	local today_heads = {}
	if today_block then
		for l = today_block.heading + 1, today_block.last do
			local up_it = syntax.item(lines[l])
			if not (up_it and up_it.mark) and #link_mod().links_on(lines[l]) > 0 then
				local def = first_def(l)
				if def and not today_heads[def] then
					local last = l
					for k = l + 1, today_block.last do
						if lines[k]:match("%S") then
							if indent_of(lines[k]) <= indent_of(lines[l]) then
								break
							end
							last = k
						end
					end
					today_heads[def] = { lnum = l, last = last }
				end
			end
		end
	end

	local inserts, out = {}, {}
	for _, key in ipairs(order) do
		local match = key ~= "" and head_def[key] and today_heads[head_def[key]]
		if match then
			local pad = string.rep(" ", indent_of(lines[match.lnum]) + 2)
			local children = {}
			for _, copy in ipairs(groups[key]) do
				children[#children + 1] = pad .. copy:sub(3)
			end
			inserts[#inserts + 1] = { at = match.last + 1, lines = children }
		else
			if key ~= "" then
				out[#out + 1] = key
			end
			vim.list_extend(out, groups[key])
		end
	end
	local function finish()
		-- ascending, inserts at the same line kept in order
		local merged = {}
		for _, ins in ipairs(inserts) do
			local same
			for _, m in ipairs(merged) do
				if m.at == ins.at then
					same = m
				end
			end
			if same then
				vim.list_extend(same.lines, ins.lines)
			else
				merged[#merged + 1] = { at = ins.at, lines = vim.list_slice(ins.lines) }
			end
		end
		table.sort(merged, function(a, b)
			return a.at < b.at
		end)
		return { edits = edits, inserts = merged }
	end
	if #out == 0 then
		return finish()
	end
	if today_block then
		inserts[#inserts + 1] = { at = today_block.last + 1, lines = out }
		return finish()
	end
	-- a new day, next to its nearest neighbour in time (as stores/calendar)
	local target = day_number(today)
	local before_i, before_n, after_i, after_n
	for i, b in ipairs(blocks) do
		local n = day_number(b.date)
		if n < target and (not before_n or n >= before_n) then
			before_i, before_n = i, n
		elseif n > target and (not after_n or n < after_n) then
			after_i, after_n = i, n
		end
	end
	local at = #lines + 1
	if after_i then
		if before_i and (target - before_n) <= (after_n - target) then
			at = blocks[before_i + 1] and blocks[before_i + 1].heading or (#lines + 1)
		else
			at = blocks[after_i].heading
		end
	end
	local new = { today .. ":" }
	vim.list_extend(new, out)
	new[#new + 1] = ""
	if at > #lines then
		at = #lines + 1
		if #lines > 0 and lines[#lines]:match("%S") then
			table.insert(new, 1, "")
		end
		table.remove(new)
	elseif at > 1 and lines[at - 1]:match("%S") then
		table.insert(new, 1, "")
	end
	inserts[#inserts + 1] = { at = at, lines = new }
	return finish()
end

--- Carry the open tasks of the last `days` days (default 14) to `date`
--- (default today) in the calendar. Returns how many tasks were carried
--- (marked [>]) and how many copies were added.
---@param opts { days?: integer }?
function M.carry_forward(date, opts)
	opts = opts or {}
	date = date or os.date("%Y-%m-%d")
	local workspace = require("zortex.core.workspace")
	local target = calendar_target()
	local lines = workspace.get_lines(target)
	local from = datetime.format_datetime(datetime.add_days(datetime.parse_date(date), -(opts.days or 14)), "YYYY-MM-DD")
	local plan = M.carry(lines, date, { from = from, new_id = require("zortex.services.tasks").new_id })
	for _, e in ipairs(plan.edits) do
		workspace.set_line(target, e.lnum, e.line)
	end
	local added = 0
	for i = #plan.inserts, 1, -1 do -- bottom up: earlier line numbers stay valid
		local ins = plan.inserts[i]
		workspace.insert_lines(target, ins.at, ins.lines)
		for _, l in ipairs(ins.lines) do
			if l:find("@id(", 1, true) then
				added = added + 1
			end
		end
	end
	return #plan.edits, added
end

return M
