-- services/projects/project.lua - The Project object
--
-- A project is an article (the Projects article itself, or a standalone note
-- tagged @P) or a heading inside one. Headings below a project are its
-- sub-projects, so projects form a tree. A project's OWN content (tasks, notes)
-- is everything from its header line up to its first sub-project; container
-- projects therefore have their own tasks too.
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
	attrs.context = nil
	return attrs
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

-- Own tasks: core/item Items with a checkbox, plus `project`.
function Project:tasks()
	if not self._tasks then
		local s, e = self:own_range()
		self._tasks = self.doc:items(s + 1, e, { tasks = true })
		for _, task in ipairs(self._tasks) do
			task.project = self
		end
	end
	return self._tasks
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

-- Effort points: the task's size multiplier (xp.sources.task.sizes), md = 1
local function task_points(task)
	return require("zortex.services.xp.calculator").task_points(task.attributes and task.attributes.size)
end
M.task_points = task_points

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
	if not self._stats then
		local s = empty_stats()
		for _, task in ipairs(self:tasks()) do
			local pts = task_points(task)
			local size = task.attributes and task.attributes.size or "unsized"
			s.total = s.total + 1
			s.points = s.points + pts
			s.sizes[size] = (s.sizes[size] or 0) + 1
			if task.completed then
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
