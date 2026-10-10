-- services/projects/init.lua - Projects as first-class objects
--
-- Sources: the Projects article (constants.FILES.PROJECTS) and every note
-- whose header carries the @P tag. Each source contributes one root project
-- (its article); headings below it form the project tree.
--
--   local P = require("zortex.services.projects")
--   P.roots()                                  -- root projects (one per source)
--   P.all({ leaf = true, include_done = false })
--   P.get("Projects/1 Programming/1.4 - zortex")
--   P.resolve("[P/#1.4 - zortex]")             -- same rules as following the link
--   P.at(bufnr_or_path_or_doc, lnum)           -- enclosing project
--   P.current()                                -- project at the cursor
--   P.query({ filter = fn, sort = "score" })
--
-- Everything is derived from cached core/document snapshots, so repeated calls
-- are cheap and always reflect the current file (or modified buffer) contents.
local M = {}

local constants = require("zortex.constants")
local Document = require("zortex.core.document")
local notes = require("zortex.core.notes")
local section = require("zortex.core.section")
local fs = require("zortex.utils.filesystem")
local link_resolver = require("zortex.utils.link_resolver")
local ProjectModule = require("zortex.services.projects.project")

M.Project = ProjectModule.Project

-- =============================================================================
-- Sources
-- =============================================================================

local function normalize(path)
	return vim.fn.fnamemodify(path, ":p")
end

-- Paths of every project source: the Projects file first, then @P notes.
function M.sources()
	local out, seen = {}, {}
	local function add(path)
		path = normalize(path)
		if not seen[path] and vim.loop.fs_stat(path) then
			seen[path] = true
			out[#out + 1] = path
		end
	end
	add(fs.get_projects_file())
	for _, path in ipairs(notes.find_by_tag(constants.PROJECT_TAG)) do
		add(path)
	end
	return out
end

-- Changes whenever any project source changes (file mtime or buffer edits).
-- Lets consumers cache data derived from projects (OKR links, schedule).
function M.signature()
	local parts = {}
	for _, path in ipairs(M.sources()) do
		local doc = Document.get(path)
		parts[#parts + 1] = path .. ":" .. tostring(doc and (doc.mtime or doc.changedtick))
	end
	return table.concat(parts, "|")
end

function M.is_source(doc)
	if not doc or not doc.filepath then
		return false
	end
	return doc.filepath == normalize(fs.get_projects_file()) or doc:has_tag(constants.PROJECT_TAG)
end

-- =============================================================================
-- Building
-- =============================================================================

local function is_project_node(node)
	return node.type == "article" or node.type == "heading"
end

-- Root projects of one document (cached on the immutable snapshot).
function M.for_document(target)
	local doc = Document.resolve(target)
	if not doc then
		return {}
	end
	if not doc._projects then
		doc._projects = section.derive(doc.tree, is_project_node, function(node, parent)
			return ProjectModule.new(doc, node, parent)
		end)
		-- A file without @@ names has headings but no article: wrap nothing,
		-- such files are not valid project sources.
		if doc._projects[1] and doc._projects[1].kind ~= "article" then
			doc._projects = {}
		end
	end
	return doc._projects
end

-- Root projects across all sources, in source order.
function M.roots()
	local roots = {}
	for _, path in ipairs(M.sources()) do
		vim.list_extend(roots, M.for_document(path))
	end
	return roots
end

-- =============================================================================
-- Lookup
-- =============================================================================

local function matches(p, opts)
	if opts.leaf and not p:is_leaf() then
		return false
	end
	if opts.include_roots == false and p:is_root() then
		return false
	end
	if opts.include_done == false and p:is_done() then
		return false
	end
	if opts.filter and not opts.filter(p) then
		return false
	end
	return true
end

-- Flat, pre-ordered list of projects.
---@param opts { leaf?: boolean, include_roots?: boolean, include_done?: boolean, filter?: fun(p): boolean }?
function M.all(opts)
	opts = opts or {}
	local out = {}
	for _, root in ipairs(M.roots()) do
		root:walk(function(p)
			if matches(p, opts) then
				out[#out + 1] = p
			end
		end)
	end
	return out
end

-- Project by key ("Projects/1 Programming/1.4 - zortex"), case-insensitive.
function M.get(key)
	if not key then
		return nil
	end
	local wanted = key:lower()
	local found
	for _, root in ipairs(M.roots()) do
		root:walk(function(p)
			if found then
				return false
			end
			if p.key:lower() == wanted then
				found = p
				return false
			end
		end)
		if found then
			break
		end
	end
	return found
end

-- Innermost project containing `lnum` in a document (Document, path or bufnr).
-- Returns nil when the document is not a project source.
function M.at(target, lnum)
	local doc = Document.resolve(target)
	if not doc or not M.is_source(doc) then
		return nil
	end
	local found
	for _, root in ipairs(M.for_document(doc)) do
		root:walk(function(p)
			if p:contains_line(lnum) then
				found = p
				return true
			end
			return false
		end)
	end
	return found
end

-- Project at the cursor in the current buffer.
function M.current()
	return M.at(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
end

-- Resolve a link to the project that contains its canonical target, using the
-- exact same rules as following the link. Returns project, result.
function M.resolve(link, opts)
	local result, err = link_resolver.resolve_first(link, opts)
	if not result then
		return nil, err
	end
	local project = M.at(result.doc, result.lnum)
	if not project then
		return nil, "Link does not point into a project: " .. tostring(type(link) == "string" and link or "")
	end
	return project, result
end

-- Accepts a Project, a key or a link.
function M.lookup(ref)
	if type(ref) == "table" then
		return ref
	elseif type(ref) == "string" then
		if ref:match("^%[") or ref:find("#", 1, true) or ref:match("^@") then
			return (M.resolve(ref))
		end
		return M.get(ref) or (M.resolve(ref))
	end
	return nil
end

-- =============================================================================
-- Queries
-- =============================================================================

-- Filter + sort. `sort` is a comparator name from services/projects/score
-- ("score", "priority", "importance", "due", "size", "remaining",
-- "completion", "name", "path") or a function(a, b).
---@param opts { sort?: string|function, reverse?: boolean, limit?: integer, leaf?: boolean, include_roots?: boolean, include_done?: boolean, filter?: function }?
function M.query(opts)
	opts = opts or {}
	local list = M.all(opts)
	if opts.sort then
		require("zortex.services.projects.score").sort(list, opts.sort, opts.reverse)
	end
	if opts.limit and #list > opts.limit then
		list = vim.list_slice(list, 1, opts.limit)
	end
	return list
end

-- Every task across all projects (each task carries `.project`).
---@param opts { include_done?: boolean, filter?: function }?
function M.tasks(opts)
	opts = opts or {}
	local out = {}
	for _, p in ipairs(M.all()) do
		for _, task in ipairs(p:tasks()) do
			if (opts.include_done ~= false or not task.completed) and (not opts.filter or opts.filter(task)) then
				out[#out + 1] = task
			end
		end
	end
	return out
end

-- =============================================================================
-- Actions
-- =============================================================================

-- Open a project in the current (or given) window.
function M.jump(project, cmd)
	project = M.lookup(project)
	if not project then
		return false
	end
	vim.cmd((cmd or "edit") .. " " .. vim.fn.fnameescape(project.file))
	vim.api.nvim_win_set_cursor(0, { project.lnum, 0 })
	vim.cmd("normal! zz")
	return true
end

-- Write @progress(done/total) (sub-projects included) on every heading
-- project of a buffer. Returns the number of headings updated.
function M.update_progress(bufnr)
	bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
	local attributes = require("zortex.utils.attributes")
	local doc = Document.from_buffer(bufnr)
	if not M.is_source(doc) then
		return 0
	end
	local updated = 0
	for _, root in ipairs(M.for_document(doc)) do
		root:walk(function(p)
			if p.kind == "heading" then
				local r = p:rollup()
				local line = doc.lines[p.lnum]
				local new_line = attributes.update_progress_attribute(line, r.done, r.total)
				if new_line ~= line then
					vim.api.nvim_buf_set_lines(bufnr, p.lnum - 1, p.lnum, false, { new_line })
					updated = updated + 1
				end
			end
		end)
	end
	return updated
end

return M
