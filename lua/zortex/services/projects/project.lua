-- services/projects/project.lua - The Project object
--
-- A project is an article (the Projects article itself, or a standalone note
-- tagged @P) or a heading inside one. Headings below a project are its
-- sub-projects, so projects form a tree. A project's OWN content (tasks, notes)
-- is everything from its header line up to its first sub-project; container
-- projects therefore have their own tasks too.
--
-- Identity is the tree path of clean texts (no attributes):
--   path = { "Projects", "1 Programming", "1.4 - zortex" }
--   key  = "Projects/1 Programming/1.4 - zortex"
--   link = "[Projects/#1 Programming/#1.4 - zortex]"   (resolves back to it)
local M = {}

local parser = require("zortex.utils.parser")
local attributes = require("zortex.utils.attributes")
local constants = require("zortex.constants")
local link_resolver = require("zortex.utils.link_resolver")

local Project = {}
Project.__index = Project

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

---@param doc table core/document snapshot
---@param node table section node (article or heading)
---@param parent table? parent Project
function M.new(doc, node, parent)
	local is_article = node.type == "article"
	local p = setmetatable({
		doc = doc,
		node = node,
		parent = parent,
		children = {},

		name = is_article and (doc:name() or node.text) or node.text,
		file = doc.filepath,
		lnum = node.start_line,
		start_line = node.start_line,
		end_line = node.end_line,
		depth = parent and (parent.depth + 1) or 0,
		kind = is_article and "article" or "heading",

		tags = is_article and doc.tags or {},
		aliases = is_article and doc.names or nil,
	}, Project)

	p.path = parent and vim.list_extend(vim.list_slice(parent.path), { p.name }) or { p.name }
	p.key = table.concat(p.path, "/")

	if is_article then
		p.attributes = article_attributes(doc)
	else
		p.attributes = attributes.parse_project_attributes(doc.lines[node.start_line] or "")
	end

	p.link = link_resolver.link_for_node(doc, node)
	return p
end

-- =============================================================================
-- Structure
-- =============================================================================

function Project:is_root()
	return self.parent == nil
end

function Project:is_leaf()
	return #self.children == 0
end

-- Line range of the project's own content (before its first sub-project).
function Project:own_range()
	local own_end = self.children[1] and (self.children[1].start_line - 1) or self.end_line
	return self.start_line, own_end
end

function Project:contains_line(lnum)
	return lnum >= self.start_line and lnum <= self.end_line
end

-- Pre-order walk over this project and its sub-projects. Return false from
-- `fn` to skip a project's children.
function Project:walk(fn)
	if fn(self) == false then
		return
	end
	for _, child in ipairs(self.children) do
		child:walk(fn)
	end
end

function Project:descendants()
	local out = {}
	for _, child in ipairs(self.children) do
		child:walk(function(p)
			out[#out + 1] = p
		end)
	end
	return out
end

-- Ancestors nearest-first
function Project:ancestors()
	local out, current = {}, self.parent
	while current do
		out[#out + 1] = current
		current = current.parent
	end
	return out
end

function Project:root()
	local current = self
	while current.parent do
		current = current.parent
	end
	return current
end

-- Post-order aggregation over the project subtree: fn(project, child_results)
function Project:fold(fn)
	local results = {}
	for i, child in ipairs(self.children) do
		results[i] = child:fold(fn)
	end
	return fn(self, results)
end

-- Breadcrumb, e.g. "Projects › 1 Programming › 1.4 - zortex"
function Project:breadcrumb(sep)
	return table.concat(self.path, sep or " › ")
end

-- =============================================================================
-- Content
-- =============================================================================

-- The project's own lines (header line excluded).
function Project:lines()
	local s, e = self:own_range()
	return self.doc:get_lines(s + 1, e)
end

-- Own tasks, each { text, completed, attributes, indent, lnum, file, project }.
function Project:tasks()
	if not self._tasks then
		self._tasks = {}
		local s, e = self:own_range()
		local tracker = parser.CodeBlockTracker:new()
		for lnum = s + 1, e do
			local line = self.doc.lines[lnum]
			if not tracker:update(line) then
				local task = parser.parse_task(line)
				if task then
					task.lnum = lnum
					task.file = self.file
					task.project = self
					table.insert(self._tasks, task)
				end
			end
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
		local line = self.doc.lines[lnum]
		if line:match("%S") and not parser.is_task_line(line) then
			out[#out + 1] = { lnum = lnum, text = line }
		end
	end
	return out
end

-- =============================================================================
-- Stats
-- =============================================================================

local function task_points(task)
	local size = task.attributes and task.attributes.size or constants.DEFAULT_TASK_SIZE
	return constants.SIZE_POINTS[size] or constants.SIZE_POINTS[constants.DEFAULT_TASK_SIZE]
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
	local size = self.attributes.size
	if size and constants.SIZE_POINTS[size] then
		return constants.SIZE_POINTS[size]
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

-- Areas this project belongs to (from @a(...)/@area(...)). opts: { inherit =
-- bool } falls back to the nearest ancestor that declares areas.
function Project:areas(opts)
	return require("zortex.services.projects.relations").areas(self, opts)
end

M.Project = Project

return M
