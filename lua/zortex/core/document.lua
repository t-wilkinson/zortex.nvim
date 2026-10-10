-- core/document.lua - Read-only snapshot of a note: lines + structural tree + header
--
-- Every consumer that needs to look at a note (link resolution, projects, OKR,
-- search, ...) goes through here, so they all see the same structure.
-- Snapshots are cached: by mtime for files on disk, by changedtick for
-- modified buffers. M.get(path) prefers a modified, loaded buffer over the file
-- so live edits are visible before they are saved.
local M = {}

local parser = require("zortex.utils.parser")
local section = require("zortex.core.section")
local fs = require("zortex.utils.filesystem")

local Document = {}
Document.__index = Document

-- =============================================================================
-- Construction
-- =============================================================================

function M.from_lines(lines, filepath, meta)
	local header = parser.parse_header(lines)
	local doc = setmetatable({
		filepath = filepath,
		lines = lines,
		names = header.names, -- every @@ alias, primary first
		tags = header.tags, -- every @Tag in the header
		header = header,
		tree = section.build_tree(lines),
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
	local stat = vim.loop.fs_stat(path)
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
	return parser.list_has(self.names, name)
end

function Document:has_tag(tag)
	return parser.list_has(self.tags, tag)
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

M.Document = Document

return M
