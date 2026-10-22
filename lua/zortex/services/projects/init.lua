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
local entity = require("zortex.core.entity")
local fs = require("zortex.utils.filesystem")
local ProjectModule = require("zortex.services.projects.project")

M.Project = ProjectModule.Project

local function normalize(path)
	return vim.fn.fnamemodify(path, ":p")
end

-- Registry (core/entity): sources, roots, all, get, at, current, resolve,
-- lookup, jump, for_document, signature.
local registry = entity.registry({
	kind = "project",
	namespace = constants.PROJECT_TAG, -- links start with [P/...]
	class = ProjectModule.Project,
	init = ProjectModule.init,
	-- headings that are projects; organizational ones only name them
	keep = function(node, doc)
		return node.type == "heading" and ProjectModule.is_project_heading(node, doc)
	end,
	in_path = function(node)
		return node.type == "heading"
	end,
	-- linking a heading can make it a project: rebuild when links change
	cache_tag = function()
		local ok, gen = pcall(function()
			return require("zortex.core.link_index").generation()
		end)
		return ok and gen or 0
	end,
	-- The Projects file first, then every note tagged @P
	sources = function()
		local out = { fs.get_projects_file() }
		vim.list_extend(out, notes.find_by_tag(constants.PROJECT_TAG))
		return out
	end,
	is_source = function(doc)
		return doc.filepath == normalize(fs.get_projects_file()) or doc:has_tag(constants.PROJECT_TAG)
	end,
	-- Extra all() option: include_done = false hides finished projects
	matches = function(p, opts)
		return not (opts.include_done == false and p:is_done())
	end,
})

for name, fn in pairs(registry) do
	M[name] = fn
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

--- The projects a link's target stands for: the project its line is in;
--- none for an organizational heading (one that isn't a project even
--- though linked: nothing under it is a project). Key results and the
--- week's focus read their links with it.
---@return table[] projects
function M.for_target(target, lnum)
	local doc = Document.resolve(target)
	if not doc or not M.is_source(doc) then
		return {}
	end
	local node = doc:node_starting_at(lnum)
	if node and node.type == "heading" and not ProjectModule.is_project_heading(node, doc) then
		local out = {}
		for _, root in ipairs(M.for_document(doc)) do
			root:walk(function(x)
				if x.start_line > node.start_line and x.start_line <= node.end_line then
					out[#out + 1] = x
					return false
				end
			end)
		end
		return out
	end
	local p = M.at(doc, lnum)
	return p and { p } or {}
end

--- for_target for a link ("[P/#Car]"): its canonical target's projects.
function M.for_link(link, opts)
	local result = require("zortex.core.link").resolve_first(link, opts)
	if not result then
		return {}
	end
	return M.for_target(result.doc, result.lnum)
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

return M
