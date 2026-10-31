-- core/document.lua - Read-only snapshot of a note: lines, syntax, tree, header
--
-- Every consumer that needs to look at a note (link resolution, projects, OKR,
-- search, highlighting, folding, ...) goes through here, so they all see the
-- same structure. The syntax (core/syntax) is parsed once per snapshot; inline
-- spans are parsed lazily per line.
-- Snapshots are cached: by mtime for files on disk, by changedtick for
-- modified buffers. M.get(path) prefers a modified, loaded buffer over the file
-- so live edits are visible before they are saved.
local M = {}

local syntax = require("zortex.core.syntax")
local section = require("zortex.core.section")
local fs = require("zortex.utils.filesystem")

local Document = {}
Document.__index = Document

-- =============================================================================
-- Construction
-- =============================================================================

function M.from_lines(lines, filepath, meta)
	local given
	local e = filepath and (filepath:match("%.(%a+)$") or ""):lower()
	if e == "md" or e == "markdown" then
		-- a Markdown document (core/documents): read as a note, same lines
		local documents = require("zortex.core.documents")
		if documents.kind(filepath) == "markdown" then
			lines, given = documents.markdown(lines, filepath)
		end
	end
	local ast = syntax.parse(lines, given and { header = given } or nil)
	local header = ast.header
	local doc = setmetatable({
		filepath = filepath,
		lines = lines,
		syntax = ast, -- core/syntax output: per-line descriptors, blocks, sections
		names = header.names, -- every @@ alias, primary first
		tags = header.tags, -- every @Tag in the header
		header = header,
		tree = section.build_tree(lines, ast),
		mtime = meta and meta.mtime,
		changedtick = meta and meta.changedtick,
		_by_start = nil,
	}, Document)
	return doc
end

local function normalize(path)
	return vim.fn.fnamemodify(path, ":p")
end

local file_cache = {} -- path -> { mtime, size, doc }
local buffer_cache = {} -- bufnr -> { changedtick, doc }

function M.from_file(path)
	path = normalize(path)
	local stat = vim.uv.fs_stat(path)
	if not stat then
		return nil
	end
	local cached = file_cache[path]
	if cached and cached.mtime == stat.mtime.sec and cached.nsec == stat.mtime.nsec and cached.size == stat.size then
		return cached.doc
	end
	local lines = fs.read_lines(path)
	if not lines then
		return nil
	end
	local doc = M.from_lines(lines, path, { mtime = stat.mtime.sec })
	file_cache[path] = { mtime = stat.mtime.sec, nsec = stat.mtime.nsec, size = stat.size, doc = doc }
	return doc
end

function M.from_buffer(bufnr)
	bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = buffer_cache[bufnr]
	if cached and cached.changedtick == tick then
		return cached.doc
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local doc = M.from_lines(lines, name ~= "" and normalize(name) or nil, { changedtick = tick })
	doc.bufnr = bufnr
	buffer_cache[bufnr] = { changedtick = tick, doc = doc }
	return doc
end

-- Snapshot for a path: a loaded, modified buffer wins over the file on disk.
function M.get(path)
	if not path then
		return nil
	end
	local bufnr = vim.fn.bufnr(normalize(path))
	if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
		return M.from_buffer(bufnr)
	end
	return M.from_file(path)
end

-- Accepts a Document, a path, or a buffer number.
function M.resolve(target)
	if type(target) == "table" then
		return target
	elseif type(target) == "number" then
		return M.from_buffer(target)
	elseif type(target) == "string" then
		return M.get(target)
	end
	return nil
end

--- The snapshot last read for `path` (file) or `bufnr` (buffer), without
--- looking at the disk or the buffer again: what a caller computed its line
--- numbers from (core/workspace compares it with the note before writing).
function M.cached(target)
	if type(target) == "number" then
		local c = buffer_cache[target]
		return c and c.doc, c and c.changedtick
	end
	local c = target and file_cache[normalize(target)]
	return c and c.doc
end

function M.invalidate(path)
	if path then
		file_cache[normalize(path)] = nil
	else
		file_cache, buffer_cache = {}, {}
	end
end

-- =============================================================================
-- Document methods
-- =============================================================================

-- Primary article name (first @@ alias), or nil
function Document:name()
	return self.names[1]
end

function Document:has_name(name)
	return syntax.list_has(self.names, name)
end

function Document:has_tag(tag)
	return syntax.list_has(self.tags, tag)
end

-- The article node (root's article child), or nil for files without @@ names
function Document:article()
	for _, child in ipairs(self.tree.children) do
		if child.type == "article" then
			return child
		end
	end
	return nil
end

function Document:line(lnum)
	return self.lines[lnum]
end

function Document:get_lines(start_line, end_line)
	local out = {}
	for i = start_line or 1, math.min(end_line or #self.lines, #self.lines) do
		out[#out + 1] = self.lines[i]
	end
	return out
end

-- Deepest section containing lnum (the root if none)
function Document:node_at(lnum)
	return self.tree:find_child_at_line(lnum) or self.tree
end

-- Section whose header line is exactly lnum, or nil
function Document:node_starting_at(lnum)
	if not self._by_start then
		self._by_start = {}
		self.tree:walk(function(n)
			if not n:is_root() then
				self._by_start[n.start_line] = n
			end
		end)
	end
	return self._by_start[lnum]
end

-- =============================================================================
-- Syntax access
-- =============================================================================

-- Syntax descriptor of a line (see core/syntax)
function Document:info(lnum)
	return self.syntax.lines[lnum]
end

-- Inline spans of a line (parsed on first use)
function Document:inline(lnum)
	local d = self.syntax.lines[lnum]
	if not d then
		return {}
	end
	if not d.inline then
		d.inline = d.content_col and syntax.inline(self.lines[lnum], d.content_col, d.content_end) or {}
	end
	return d.inline
end

local CODE_KINDS = { code = true, fence = true, math = true, math_fence = true }

-- True inside fenced code or math blocks (fence lines included)
function Document:in_code(lnum)
	local d = self.syntax.lines[lnum]
	return d ~= nil and CODE_KINDS[d.kind] == true
end

--- List items (core/item) on lines s..e (default: whole note).
---@param opts { tasks?: boolean, schema?: table|string, context?: table }?
function Document:items(s, e, opts)
	opts = opts or {}
	local Item = require("zortex.core.item")
	local out = {}
	for lnum = s or 1, math.min(e or #self.lines, #self.lines) do
		local d = self.syntax.lines[lnum]
		if d.item and (not opts.tasks or d.item.mark) then
			out[#out + 1] = Item.from_line(self.lines[lnum], {
				lnum = lnum,
				file = self.filepath,
				info = d,
				schema = opts.schema,
				context = opts.context,
			})
		end
	end
	return out
end

M.Document = Document

return M
