-- core/entity.lua - Domain objects derived from the section tree
--
-- Projects and areas are both "entities": objects that live at a section of a
-- note (an article, heading or label), form a tree of their own, and are
-- identified by their tree path. This module holds everything they share:
--
--   Entity      base class: path/key/link, tree navigation, own content range
--   registry()  builds a lookup API (roots/all/get/at/resolve/lookup) for one
--               kind of entity from a small spec
--
-- A kind specializes it with a spec:
--   kind       "project" | "area" | ...
--   namespace  first link component ("P" -> [P/#1 Programming/#1.4 - zortex])
--   keep(node) which sections become entities
--   class      metatable inheriting from Entity (adds domain methods)
--   init(e)    optional per-entity setup (attributes, ...)
--   sources()  note paths that contribute root entities
--   is_source(doc)
local M = {}

local Document = require("zortex.core.document")
local section = require("zortex.core.section")
local link_mod = require("zortex.core.link")

-- =============================================================================
-- Entity base class
-- =============================================================================

local Entity = {}
Entity.__index = Entity
M.Entity = Entity

-- Create a subclass: local Project = Entity:extend()
function Entity:extend()
	local cls = setmetatable({}, { __index = self })
	cls.__index = cls
	return cls
end

-- Link components for an entity's section, using `namespace` as the first
-- component when the note declares it as an alias (replacing the article
-- name) or carries it as a tag (prefixing the article name):
--   projects.zortex (@@P):  [P/#1 Programming/#1.4 - zortex]
--   flipping.zortex (@P):   [P/Flipping/#Subaru outback]
function M.link_components(doc, node, namespace)
	local parts = link_mod.node_components(doc, node)
	if namespace and #parts > 0 then
		if doc:has_name(namespace) then
			parts[1] = namespace
		elseif doc:has_tag(namespace) then
			table.insert(parts, 1, namespace)
		end
	end
	return parts
end

function M.new(cls, spec, doc, node, parent)
	local is_article = node.type == "article"
	local e = setmetatable({
		doc = doc,
		node = node,
		parent = parent,
		children = {},

		name = is_article and (doc:name() or node.text) or node.text,
		kind = node.type, -- "article" | "heading" | "label" | ...
		file = doc.filepath,
		lnum = node.start_line,
		start_line = node.start_line,
		end_line = node.end_line,
		depth = parent and (parent.depth + 1) or 0,
	}, cls)

	e.path = parent and vim.list_extend(vim.list_slice(parent.path), { e.name }) or { e.name }
	e.key = table.concat(e.path, "/")
	local parts = M.link_components(doc, node, spec.namespace)
	e.link = #parts > 0 and link_mod.build_link(parts) or nil

	if spec.init then
		spec.init(e)
	end
	return e
end

function Entity:is_root()
	return self.parent == nil
end

function Entity:is_leaf()
	return #self.children == 0
end

function Entity:contains_line(lnum)
	return lnum >= self.start_line and lnum <= self.end_line
end

-- Line range of the entity's own content: up to its first child entity.
function Entity:own_range()
	local own_end = self.children[1] and (self.children[1].start_line - 1) or self.end_line
	return self.start_line, own_end
end

-- Own lines, header line excluded
function Entity:lines()
	local s, e = self:own_range()
	return self.doc:get_lines(s + 1, e)
end

-- Pre-order walk; return false from fn to skip an entity's children.
function Entity:walk(fn)
	if fn(self) == false then
		return
	end
	for _, child in ipairs(self.children) do
		child:walk(fn)
	end
end

function Entity:descendants()
	local out = {}
	for _, child in ipairs(self.children) do
		child:walk(function(x)
			out[#out + 1] = x
		end)
	end
	return out
end

-- Ancestors nearest-first
function Entity:ancestors()
	local out, current = {}, self.parent
	while current do
		out[#out + 1] = current
		current = current.parent
	end
	return out
end

function Entity:root()
	local current = self
	while current.parent do
		current = current.parent
	end
	return current
end

-- Is `other` this entity or one of its descendants?
function Entity:contains(other)
	local current = other
	while current do
		if current == self or current.key == self.key then
			return true
		end
		current = current.parent
	end
	return false
end

-- Post-order aggregation: fn(entity, child_results)
function Entity:fold(fn)
	local results = {}
	for i, child in ipairs(self.children) do
		results[i] = child:fold(fn)
	end
	return fn(self, results)
end

function Entity:breadcrumb(sep)
	return table.concat(self.path, sep or " › ")
end

-- Links (from any note) pointing into this entity's own content, or with
-- opts.descendants anywhere in its subtree. See core/link_index.
function Entity:backlinks(opts)
	return require("zortex.core.link_index").backlinks(self, opts)
end

-- =============================================================================
-- Registry
-- =============================================================================

local function normalize(path)
	return vim.fn.fnamemodify(path, ":p")
end

---Build the lookup API for one kind of entity.
---@return table api { roots, all, get, at, current, resolve, lookup, for_document, sources, is_source, signature }
function M.registry(spec)
	local api = {}
	local cache_key = "_entities_" .. spec.kind

	api.sources = function()
		local out, seen = {}, {}
		for _, path in ipairs(spec.sources()) do
			path = normalize(path)
			if not seen[path] and vim.loop.fs_stat(path) then
				seen[path] = true
				out[#out + 1] = path
			end
		end
		return out
	end

	api.is_source = function(doc)
		return doc ~= nil and doc.filepath ~= nil and spec.is_source(doc)
	end

	-- Changes whenever any source changes; lets consumers cache derived data.
	api.signature = function()
		local parts = {}
		for _, path in ipairs(api.sources()) do
			local doc = Document.get(path)
			parts[#parts + 1] = path .. ":" .. tostring(doc and (doc.mtime or doc.changedtick))
		end
		return table.concat(parts, "|")
	end

	-- Root entities of one document (cached on the immutable snapshot).
	api.for_document = function(target)
		local doc = Document.resolve(target)
		if not doc then
			return {}
		end
		if not doc[cache_key] then
			local roots = section.derive(doc.tree, function(node)
				return node.type == "article" or spec.keep(node)
			end, function(node, parent)
				return M.new(spec.class, spec, doc, node, parent)
			end)
			-- Only notes with an article (@@Name) are valid sources
			if roots[1] and roots[1].kind ~= "article" then
				roots = {}
			end
			doc[cache_key] = roots
		end
		return doc[cache_key]
	end

	api.roots = function()
		local roots = {}
		for _, path in ipairs(api.sources()) do
			vim.list_extend(roots, api.for_document(path))
		end
		return roots
	end

	local function matches(x, opts)
		if opts.leaf and not x:is_leaf() then
			return false
		end
		if opts.include_roots == false and x:is_root() then
			return false
		end
		if opts.filter and not opts.filter(x) then
			return false
		end
		if spec.matches and not spec.matches(x, opts) then
			return false
		end
		return true
	end

	-- Flat, pre-ordered list. opts: { leaf, include_roots, filter, ...kind-specific }
	api.all = function(opts)
		opts = opts or {}
		local out = {}
		for _, root in ipairs(api.roots()) do
			root:walk(function(x)
				if matches(x, opts) then
					out[#out + 1] = x
				end
			end)
		end
		return out
	end

	-- By key, case-insensitive
	api.get = function(key)
		if not key then
			return nil
		end
		local wanted, found = key:lower(), nil
		for _, root in ipairs(api.roots()) do
			root:walk(function(x)
				if found then
					return false
				end
				if x.key:lower() == wanted then
					found = x
					return false
				end
			end)
			if found then
				break
			end
		end
		return found
	end

	-- Innermost entity containing lnum in a Document / path / bufnr
	api.at = function(target, lnum)
		local doc = Document.resolve(target)
		if not doc or not api.is_source(doc) then
			return nil
		end
		local found
		for _, root in ipairs(api.for_document(doc)) do
			root:walk(function(x)
				if x:contains_line(lnum) then
					found = x
					return true
				end
				return false
			end)
		end
		return found
	end

	api.current = function()
		return api.at(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
	end

	-- Entity containing a link's canonical target (same rules as following it)
	api.resolve = function(link, opts)
		local result, err = link_mod.resolve_first(link, opts)
		if not result then
			return nil, err
		end
		local x = api.at(result.doc, result.lnum)
		if not x then
			return nil, string.format("Link does not point into a %s", spec.kind)
		end
		return x, result
	end

	-- Entity, key, or link
	api.lookup = function(ref)
		if type(ref) == "table" then
			return ref
		elseif type(ref) == "string" then
			if not ref:match("^%[") then
				local x = api.get(ref)
				if x then
					return x
				end
			end
			return (api.resolve(ref))
		end
		return nil
	end

	-- Open an entity in the current window (or with `cmd`, e.g. "split")
	api.jump = function(ref, cmd)
		local x = api.lookup(ref)
		if not x then
			return false
		end
		vim.cmd((cmd or "edit") .. " " .. vim.fn.fnameescape(x.file))
		vim.api.nvim_win_set_cursor(0, { x.lnum, 0 })
		vim.cmd("normal! zz")
		return true
	end

	return api
end

return M
