-- services/projects/project.lua - The Project object
--
-- A project is an article (the Projects article itself, or a standalone note
-- tagged @P) or a heading inside one. Headings below a project are its
-- sub-projects, so projects form a tree. A project's OWN content (tasks, notes)
-- is everything from its header line up to its first sub-heading; container
-- projects therefore have their own tasks too.
--
-- A heading with no task in its own content (done or not) and no project
-- attribute (@size, @p, @i, @due, @done, @xp, @dur, @a, @someday) is
-- an organizational heading, not a project: it only groups the projects
-- under it, which become sub-projects of the nearest project above. It still
-- names them (their key and link go through it). Linking it (from a key
-- result, the week's focus, any note) makes it a project again when it has
-- projects under it: a container, like a project note (M.is_project_heading).
--
-- Identity is the tree path of clean texts (no attributes); links always start
-- with the P namespace:
--   path = { "Projects", "1 Programming", "1.4 - zortex" }
--   key  = "Projects/1 Programming/1.4 - zortex"
--   link = "[P/#1 Programming/#1.4 - zortex]"     (resolves back to it)
--   link = "[P/Flipping/#Subaru outback]"          (standalone @P note)
--
-- Structure and navigation (walk, fold, ancestors, own_range, ...) come from
-- core/entity; this file adds tasks, stats and relations.
local M = {}

local attributes = require("zortex.utils.attributes")
local Entity = require("zortex.core.entity").Entity

local Project = Entity:extend()
M.Project = Project

-- Header-tag attributes for article projects ("@size(lg)" on its own line);
-- bare tags such as @P or @Cars are tags, not attributes.
local function article_attributes(doc)
	if #doc.header.tag_lines == 0 then
		return {}
	end
	local attrs = attributes.parse_project_attributes(table.concat(doc.header.tag_lines, " "))
	attrs.tags = nil
	return attrs
end

-- The line range of a heading's own content: up to its first sub-heading.
local function own_range_of(node)
	local e = node.end_line
	for _, c in ipairs(node.children or {}) do
		if c.type == "heading" then
			e = c.start_line - 1
			break
		end
	end
	return node.start_line, e
end
M.own_range_of = own_range_of

-- Per document (and link index generation): the lines links point at, and
-- the answers so far
local function context(doc)
	local ok, gen = pcall(function()
		return require("zortex.core.link_index").generation()
	end)
	gen = ok and gen or 0
	local ctx = doc._project_headings
	if not ctx or ctx.gen ~= gen then
		local okl, linked = pcall(function()
			return require("zortex.core.link_index").linked_lines(doc.filepath)
		end)
		ctx = { gen = gen, linked = okl and linked or {}, memo = {} }
		doc._project_headings = ctx
	end
	return ctx
end

-- Linked from outside its own section (a KR, the week's focus, a note)
local function linked(node, doc, ctx)
	local path = doc.filepath and vim.fn.fnamemodify(doc.filepath, ":p")
	for _, ref in ipairs(ctx.linked[node.start_line] or {}) do
		local inside = ref.file == path and ref.lnum >= node.start_line and ref.lnum <= node.end_line
		if not inside then
			return true
		end
	end
	return false
end

local is_project_heading

-- A heading under it (at any depth) is a project
local function has_sub_project(node, doc, ctx)
	for _, c in ipairs(node.children or {}) do
		if c.type == "heading" and is_project_heading(c, doc, ctx) then
			return true
		end
		if has_sub_project(c, doc, ctx) then
			return true
		end
	end
	return false
end

--- Whether a heading of a project note is a project: it has a task (done or
--- not) of its own, or a project attribute, or it is linked (from outside
--- it) and has projects under it. Bare tags (@rust, for @[...] tag links)
--- don't count.
---@param node table core/section heading
---@param doc table core/document
---@return boolean
function is_project_heading(node, doc, ctx)
	ctx = ctx or context(doc)
	local known = ctx.memo[node]
	if known ~= nil then
		return known
	end
	local yes = false
	local attrs = attributes.parse_project_attributes(doc.lines[node.start_line] or "")
	for key in pairs(attrs) do
		if key ~= "tags" then
			yes = true
		end
	end
	if not yes and vim.tbl_contains(attrs.tags or {}, "someday") then
		yes = true
	end
	if not yes then
		local s, e = own_range_of(node)
		for lnum = s + 1, math.min(e, #doc.lines) do
			local d = doc.syntax.lines[lnum]
			if d and d.item and d.item.mark then
				yes = true
				break
			end
		end
	end
	if not yes then
		yes = linked(node, doc, ctx) and has_sub_project(node, doc, ctx)
	end
	ctx.memo[node] = yes
	return yes
end
M.is_project_heading = is_project_heading

-- Own content: up to the first sub-heading, a project or not (an
-- organizational heading's lines aren't its parent's).
function Project:own_range()
	return own_range_of(self.node)
end

-- Per-project setup, called by core/entity when a project is created.
function M.init(p)
	if p.kind == "article" then
		p.tags = p.doc.tags
		p.aliases = p.doc.names
		p.attributes = article_attributes(p.doc)
	else
		p.tags = {}
		p.attributes = attributes.parse_project_attributes(p.doc.lines[p.lnum] or "")
	end
end

-- =============================================================================
-- Content
-- =============================================================================

-- Tasks, stats and rollups are cached on the project, and depend on the
-- calendar too (services/mirrors: a checked copy completes a task): drop
-- them when the calendar snapshot changed.
local function fresh(self)
	local cal = require("zortex.services.mirrors").calendar_doc() or false
	if self._calendar ~= cal then
		self._calendar = cal
		self._tasks, self._stats, self._rollup = nil, nil, nil
	end
end

-- Own tasks: core/item Items with a checkbox, plus `project`. A task with a
-- checked calendar copy (same @id) is completed (services/mirrors).
function Project:tasks()
	fresh(self)
	if not self._tasks then
		local s, e = self:own_range()
		self._tasks = self.doc:items(s + 1, e, { tasks = true })
		for _, task in ipairs(self._tasks) do
			task.project = self
		end
		require("zortex.services.mirrors").apply(self._tasks)
		-- tasks nested under a task: hours shared, leaves counted
		require("zortex.services.task_groups").annotate(self._tasks, M.group_opts(self.doc))
	end
	return self._tasks
end

--- The tasks progress and XP count: leaves (a task with tasks nested under
--- it is a group, services/task_groups).
function Project:leaf_tasks()
	return require("zortex.services.task_groups").leaves(self:tasks())
end

-- Own tasks plus the tasks of every sub-project.
function Project:all_tasks()
	local out = {}
	self:walk(function(p)
		vim.list_extend(out, p:tasks())
	end)
	return out
end

-- Own non-task, non-blank lines (context, links, sub-labels, ...).
function Project:notes()
	local out = {}
	local s, e = self:own_range()
	for lnum = s + 1, e do
		local d = self.doc:info(lnum)
		if d.kind ~= "blank" and not (d.item and d.item.mark) then
			out[#out + 1] = { lnum = lnum, text = self.doc.lines[lnum] }
		end
	end
	return out
end

-- =============================================================================
-- Stats
-- =============================================================================

-- Effort points: the task's estimated hours (xp.sizes.task; unsized = md),
-- or its share of a group's (services/task_groups)
local function task_points(task)
	return task.hours or require("zortex.services.xp.calculator").task_points(task.attributes and task.attributes.size)
end
M.task_points = task_points

--- Options for task_groups.annotate: sizes in hours, unsized = md.
function M.group_opts(doc)
	local calc = require("zortex.services.xp.calculator")
	return {
		doc = doc,
		hours = function(size)
			return size and calc.hours("task", size) or nil
		end,
		default = calc.task_points(nil),
	}
end

local function empty_stats()
	return { total = 0, done = 0, open = 0, points = 0, points_done = 0, points_open = 0, sizes = {} }
end

local function add_stats(into, from)
	for _, k in ipairs({ "total", "done", "open", "points", "points_done", "points_open" }) do
		into[k] = into[k] + from[k]
	end
	for size, n in pairs(from.sizes) do
		into.sizes[size] = (into.sizes[size] or 0) + n
	end
	return into
end

local function finish_stats(s)
	s.completion = s.total > 0 and (s.done / s.total) or 0
	return s
end

-- Stats over the project's OWN tasks:
-- { total, done, open, points, points_done, points_open, sizes = {xs=n,..}, completion }
function Project:stats()
	fresh(self)
	if not self._stats then
		local s = empty_stats()
		for _, task in ipairs(self:leaf_tasks()) do
			local pts = task_points(task)
			local size = task.attributes and task.attributes.size or "unsized"
			s.total = s.total + 1
			s.points = s.points + pts
			s.sizes[size] = (s.sizes[size] or 0) + 1
			if task.done_effective or (task.done_effective == nil and task.completed) then
				s.done = s.done + 1
				s.points_done = s.points_done + pts
			else
				s.open = s.open + 1
				s.points_open = s.points_open + pts
			end
		end
		self._stats = finish_stats(s)
	end
	return self._stats
end

-- Same shape as stats(), aggregated over the project and all sub-projects.
function Project:rollup()
	fresh(self)
	if not self._rollup then
		local s = add_stats(empty_stats(), self:stats())
		for _, child in ipairs(self.children) do
			add_stats(s, child:rollup())
		end
		self._rollup = finish_stats(s)
	end
	return self._rollup
end

-- Size of the project in points: an explicit @size(...) wins, otherwise the
-- sum of all task points in the subtree.
function Project:points()
	local explicit = require("zortex.services.xp.calculator").project_points(self.attributes.size)
	if explicit then
		return explicit
	end
	return self:rollup().points
end

-- Done when marked @done(...) or when it has tasks and none are open.
function Project:is_done()
	if self.attributes.done then
		return true
	end
	local r = self:rollup()
	return r.total > 0 and r.open == 0
end

-- =============================================================================
-- Relations (schedule, OKR, areas) - see services/projects/relations.lua
-- =============================================================================

-- Calendar entries that link to this project.
-- opts: { descendants = bool, from = "YYYY-MM-DD", to = "YYYY-MM-DD" }
function Project:schedule(opts)
	return require("zortex.services.projects.relations").schedule(self, opts)
end

-- Key results that link to this project. opts: { inherit = bool } also
-- returns KRs linked to ancestor projects.
function Project:key_results(opts)
	return require("zortex.services.projects.relations").key_results(self, opts)
end

-- Areas (services/areas Area objects) this project belongs to, from
-- @a(...)/@area(...). opts: { inherit = bool } falls back to the nearest
-- ancestor that declares areas.
function Project:areas(opts)
	return require("zortex.services.projects.relations").areas(self, opts)
end

-- The project's own @a(...) links with their resolution: { link, definition, area? }
function Project:area_links()
	return require("zortex.services.areas").resolve_links(self.attributes)
end

return M
