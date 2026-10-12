-- core/notes.lua - Note enumeration and header index (article names + tags)
--
-- Answers "which files are notes?", "which file is article X?" and "which files
-- carry tag @T?" without parsing whole files. Only header blocks are read, and
-- results are cached by mtime. A short-lived snapshot (M.index) keeps bulk work
-- such as resolving many links from re-stat'ing every file per link.
local M = {}

local syntax = require("zortex.core.syntax")
local constants = require("zortex.constants")
local fs = require("zortex.utils.filesystem")

local header_cache = {} -- path -> { mtime, nsec, header }
local snapshot = nil -- { time, include_archived, files, headers }
local SNAPSHOT_TTL_MS = 1000

-- Read just the header block of a file (stops at the first body line).
local function read_header(path)
	local bufnr = vim.fn.bufnr(path)
	if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
		return syntax.parse_header(vim.api.nvim_buf_get_lines(bufnr, 0, 50, false))
	end

	local stat = vim.loop.fs_stat(path)
	if not stat then
		return nil
	end
	local cached = header_cache[path]
	if cached and cached.mtime == stat.mtime.sec and cached.nsec == stat.mtime.nsec then
		return cached.header
	end

	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local lines = {}
	for line in f:lines() do
		lines[#lines + 1] = line
		-- The header ends at the first non-blank line that is not @-prefixed
		if line:match("%S") and not line:match("^@") then
			break
		end
		if #lines >= 50 then
			break
		end
	end
	f:close()

	local header = syntax.parse_header(lines)
	header_cache[path] = { mtime = stat.mtime.sec, nsec = stat.mtime.nsec, header = header }
	return header
end

M.header = read_header

-- Archived notes (z/archive.*.zortex or tagged @Archive) are excluded from
-- link resolution and project lists unless explicitly asked for.
function M.is_archived(path, header)
	if vim.fn.fnamemodify(path, ":t"):match("^archive%.") then
		return true
	end
	header = header or read_header(path)
	return header ~= nil and syntax.list_has(header.tags, constants.ARCHIVE_TAG)
end

-- Deterministic order: top-level notes first, then deeper ones, alphabetical.
local function sort_paths(paths)
	local function depth(p)
		local _, n = p:gsub("/", "")
		return n
	end
	table.sort(paths, function(a, b)
		local da, db = depth(a), depth(b)
		if da ~= db then
			return da < db
		end
		return a < b
	end)
	return paths
end

-- Snapshot of every note and its header.
---@param opts { include_archived?: boolean, fresh?: boolean }?
---@return { files: string[], headers: table<string, table> }
function M.index(opts)
	opts = opts or {}
	local include_archived = opts.include_archived or false
	local now = vim.loop.now()
	if
		not opts.fresh
		and snapshot
		and snapshot.include_archived == include_archived
		and now - snapshot.time < SNAPSHOT_TTL_MS
	then
		return snapshot
	end

	local files, headers = {}, {}
	for _, path in ipairs(fs.find_all_notes()) do
		local header = read_header(path)
		if header and (include_archived or not M.is_archived(path, header)) then
			files[#files + 1] = path
			headers[path] = header
		end
	end
	sort_paths(files)

	snapshot = { time = now, include_archived = include_archived, files = files, headers = headers }
	return snapshot
end

function M.files(opts)
	return M.index(opts).files
end

-- Files whose header declares article name `name` (case-insensitive).
-- `within` optionally restricts the search to a list of paths.
function M.find_by_name(name, within, opts)
	local idx = M.index(opts)
	local out = {}
	for _, path in ipairs(within or idx.files) do
		local header = idx.headers[path] or read_header(path)
		if header and syntax.list_has(header.names, name) then
			out[#out + 1] = path
		end
	end
	return out
end

-- Files whose header carries tag `tag` (case-insensitive).
function M.find_by_tag(tag, within, opts)
	local idx = M.index(opts)
	local out = {}
	for _, path in ipairs(within or idx.files) do
		local header = idx.headers[path] or read_header(path)
		if header and syntax.list_has(header.tags, tag) then
			out[#out + 1] = path
		end
	end
	return out
end

function M.invalidate()
	snapshot = nil
	header_cache = {}
end

return M
