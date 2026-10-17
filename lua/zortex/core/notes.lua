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
local snapshots = {} -- include_archived -> { time, files, headers }
local SNAPSHOT_TTL_MS = 1000

-- Read just the header block of a file (stops at the first body line).
-- `modified`: utils/buffer.modified_map(), when reading many.
local function read_header(path, modified)
	local bufnr = require("zortex.utils.buffer").modified_buf(path, modified)
	if bufnr then
		return syntax.parse_header(vim.api.nvim_buf_get_lines(bufnr, 0, 50, false))
	end

	local stat = vim.uv.fs_stat(path)
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
	local depths = {}
	local function depth(p)
		local n = depths[p]
		if not n then
			n = select(2, p:gsub("/", ""))
			depths[p] = n
		end
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

--- The folder a note's links resolve in, when it isn't notes_dir: for a
--- note outside notes_dir (a repository's doc/Roadmap.zortex), the nearest
--- folder above it with a .z/, else its own folder. nil for a note in
--- notes_dir (or no note): links there resolve in notes_dir.
function M.root_of(path)
	if not path or path == "" then
		return nil
	end
	path = vim.fn.fnamemodify(path, ":p")
	local real = vim.uv.fs_realpath(path) or path
	local dir = (require("zortex.config").notes_dir or ""):gsub("/$", "")
	local real_dir = vim.uv.fs_realpath(dir) or dir
	for _, p in ipairs({ path, real }) do
		for _, d in ipairs({ dir, real_dir }) do
			if d ~= "" and p:sub(1, #d + 1) == d .. "/" then
				return nil
			end
		end
	end
	local own = vim.fn.fnamemodify(path, ":h")
	local d = own
	while true do
		if vim.fn.isdirectory(d .. "/.z") == 1 then
			return d
		end
		local parent = vim.fn.fnamemodify(d, ":h")
		if parent == d then
			break
		end
		d = parent
	end
	return own
end

-- Snapshot of every note and its header (opts.root: the notes of another
-- folder, M.root_of).
---@param opts { include_archived?: boolean, fresh?: boolean, root?: string }?
---@return { files: string[], headers: table<string, table> }
function M.index(opts)
	opts = opts or {}
	local include_archived = opts.include_archived or false
	local key = (opts.root or "") .. "\n" .. tostring(include_archived)
	local now = vim.uv.now()
	local snapshot = snapshots[key]
	if not opts.fresh and snapshot and now - snapshot.time < SNAPSHOT_TTL_MS then
		return snapshot
	end

	local files, headers = {}, {}
	local modified = require("zortex.utils.buffer").modified_map()
	for _, path in ipairs(fs.find_all_notes(nil, { dir = opts.root })) do
		local header = read_header(path, modified)
		if header and (include_archived or not M.is_archived(path, header)) then
			files[#files + 1] = path
			headers[path] = header
		end
	end
	sort_paths(files)

	snapshot = { time = now, include_archived = include_archived, root = opts.root, files = files, headers = headers }
	snapshots[key] = snapshot
	return snapshot
end

function M.files(opts)
	return M.index(opts).files
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
	snapshots = {}
	header_cache = {}
end

return M
