-- services/task_groups.lua - Tasks nested under a task: a task group
--
--   - [ ] Security audit @md            <- the group: its @size is the budget
--       - [./z/notes.md]                   (other lines don't count)
--       - [ ] Cloudflare tunnel @xs        <- children share the budget in
--       - [ ] Wi-Fi password                  proportion to their sizes
--                                             (unsized = md)
--
-- A task's children are the tasks nested under it (by indentation, through
-- other lines: a label or a note between them doesn't break the nesting;
-- a heading does). Rules:
--
--   hours     a task without children: its @size in hours (unsized = md),
--             unless a group above gives it a share. A group with an @size:
--             that size, split over its children in proportion to their
--             own hours (a sized child its size, an unsized one md, a
--             sub-group its own total), so the parent's size wins. A group
--             without one: the sum of its children. A group adds nothing of
--             its own: progress and XP count the leaves.
--   done      a leaf is done when it is checked, or when a group above it is
--             (then dated by that group's @done when it has none itself).
--   cascade   checking a group checks its open tasks; checking the last open
--             child checks the group; reopening a child reopens the groups
--             above it. Reopening a group leaves its children as they are.
--
-- Shared with zortex serve (app/edit groups.go), checked against
-- tests/fixtures/groups.json (tests/gen_groups.lua).
local M = {}

local MOVED = ">"

local function indent_of(line)
	local lead = (line or ""):match("^%s*")
	local w = 0
	for c in lead:gmatch(".") do
		w = w + (c == "\t" and 4 or 1)
	end
	return w
end

local BREAKS = { heading = true, bold_heading = true, article = true, tag = true }

--- For every task line of `doc` in first..last: the line of the task it is
--- nested under, or false. Carried tasks ([>]) are not tasks here.
---@return table<integer, integer|false>
function M.parents(doc, first, last)
	first, last = first or 1, math.min(last or #doc.lines, #doc.lines)
	local stack, out = {}, {}
	for l = first, last do
		local d = doc.syntax.lines[l]
		local kind = d and d.kind or "blank"
		if kind == "blank" or doc:in_code(l) then -- luacheck: ignore
		elseif BREAKS[kind] then
			stack = {}
		else
			local w = indent_of(doc.lines[l])
			while #stack > 0 and stack[#stack].indent >= w do
				stack[#stack] = nil
			end
			local is_task = d.item and d.item.mark and d.item.mark ~= MOVED
			if is_task then
				local parent = false
				for i = #stack, 1, -1 do
					if stack[i].task then
						parent = stack[i].lnum
						break
					end
				end
				out[l] = parent
			end
			stack[#stack + 1] = { indent = w, lnum = l, task = is_task and true or false }
		end
	end
	return out
end

--- Annotate `tasks` (Items with lnum, from one note) with their groups:
---   parent_task, children_tasks, leaf    the tree
---   hours                                effective hours (see the rules)
---   done_effective, done_date            a leaf's state, a group's own
---   open_hours, open_leaves              a group's (or leaf's) open work
---   xp_attrs                             p / i, inherited from the groups above
---@param opts { doc: table, hours: fun(size: string?): number?, default: number }
function M.annotate(tasks, opts)
	if #tasks == 0 then
		return tasks
	end
	local first, last = math.huge, 0
	local by_lnum = {}
	for _, t in ipairs(tasks) do
		first, last = math.min(first, t.lnum), math.max(last, t.lnum)
		by_lnum[t.lnum] = t
		t.children_tasks, t.parent_task = {}, nil
	end
	local parents = M.parents(opts.doc, first, last)
	local roots = {}
	for _, t in ipairs(tasks) do
		local p = parents[t.lnum] and by_lnum[parents[t.lnum]]
		if p then
			t.parent_task = p
			table.insert(p.children_tasks, t)
		else
			roots[#roots + 1] = t
		end
	end

	local function own(t)
		return opts.hours(t.attributes and t.attributes.size)
	end
	local natural_cache = {}
	local function natural(t)
		if natural_cache[t] then
			return natural_cache[t]
		end
		local h
		if #t.children_tasks == 0 then
			h = own(t) or opts.default
		else
			h = own(t)
			if not h then
				h = 0
				for _, c in ipairs(t.children_tasks) do
					h = h + natural(c)
				end
			end
		end
		natural_cache[t] = h
		return h
	end
	local function assign(t, budget, done_above, attrs_above)
		local a = t.attributes or {}
		t.xp_attrs = { p = a.p or attrs_above.p, i = a.i or attrs_above.i }
		t.leaf = #t.children_tasks == 0
		t.hours = budget
		local done = done_above or (t.completed and { date = a.done } or nil)
		if t.leaf then
			t.done_effective = t.completed or done_above ~= nil
			t.done_date = a.done or (done_above and done_above.date)
			t.open_hours = t.done_effective and 0 or budget
			t.open_leaves = t.done_effective and 0 or 1
			return
		end
		t.done_effective = nil
		t.done_date = a.done
		local total = 0
		for _, c in ipairs(t.children_tasks) do
			total = total + natural(c)
		end
		t.open_hours, t.open_leaves = 0, 0
		for _, c in ipairs(t.children_tasks) do
			local share = total > 0 and budget * natural(c) / total or budget / #t.children_tasks
			assign(c, share, done and { date = (done_above and done_above.date) or a.done } or nil, t.xp_attrs)
			t.open_hours = t.open_hours + c.open_hours
			t.open_leaves = t.open_leaves + c.open_leaves
		end
	end
	for _, t in ipairs(roots) do
		assign(t, natural(t), nil, {})
	end
	return tasks
end

--- The leaves of annotated tasks.
function M.leaves(tasks)
	return vim.tbl_filter(function(t)
		return t.leaf ~= false
	end, tasks)
end

-- =============================================================================
-- Cascade
-- =============================================================================

--- The edits that follow line `lnum` of `lines` having been checked or
--- reopened (its new state is on the line): { { lnum, line }, ... }.
---@param set_done fun(line: string, done: boolean, date: string?): string
function M.cascade(lines, lnum, today, set_done)
	local doc = require("zortex.core.document").from_lines(lines)
	local parents = M.parents(doc)
	if parents[lnum] == nil then
		return {}
	end
	local children = {}
	for l, p in pairs(parents) do
		if p then
			children[p] = children[p] or {}
			table.insert(children[p], l)
		end
	end
	local Item = require("zortex.core.item")
	local current = {}
	local function line(l)
		return current[l] or lines[l]
	end
	local function done(l)
		local t = Item.task(line(l))
		return t and t.completed
	end
	local edits = {}
	local function set(l, state)
		current[l] = set_done(line(l), state, today)
		edits[#edits + 1] = { lnum = l, line = current[l] }
	end

	if done(lnum) then
		-- down: every open task under it
		local function down(l)
			for _, c in ipairs(children[l] or {}) do
				if not done(c) then
					set(c, true)
				end
				down(c)
			end
		end
		down(lnum)
		-- up: a group whose children are now all done
		local p = parents[lnum]
		while p do
			local all = true
			for _, c in ipairs(children[p]) do
				all = all and done(c)
			end
			if not all or done(p) then
				break
			end
			set(p, true)
			p = parents[p]
		end
	else
		-- up: the groups above it are no longer done
		local p = parents[lnum]
		while p do
			if done(p) then
				set(p, false)
			end
			p = parents[p]
		end
	end
	table.sort(edits, function(a, b)
		return a.lnum < b.lnum
	end)
	return edits
end

return M
