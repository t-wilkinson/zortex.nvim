-- modules/search_managers.lua - Search index and access tracking
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")

-- =============================================================================
-- Constants
-- =============================================================================

local HALF_LIFE_DAYS = 30
local HALF_LIFE_SECONDS = HALF_LIFE_DAYS * 86400
local IGNORED_FILES = { "storage.zortex" }

-- Cache paths
local std_cache = vim.fn.stdpath("cache")
local CACHE_FILE = std_cache .. "/zortex_index.json"
local ACCESS_FILE = std_cache .. "/zortex_access.json"

-- =============================================================================
-- Cache Management
-- =============================================================================

M.CacheManager = {}

function M.CacheManager.load(filepath)
	local data = fs.read_json(filepath)
	return data or {}
end

function M.CacheManager.save(filepath, data)
	return fs.write_json(filepath, data)
end

-- =============================================================================
-- Access Tracking
-- =============================================================================

M.AccessTracker = {}
M.AccessTracker.data = M.CacheManager.load(ACCESS_FILE)

function M.AccessTracker.record(path)
	if not M.AccessTracker.data[path] then
		M.AccessTracker.data[path] = {
			count = 0,
			times = {},
		}
	end

	local entry = M.AccessTracker.data[path]
	entry.count = entry.count + 1

	-- Keep only last 100 access times
	table.insert(entry.times, os.time())
	if #entry.times > 100 then
		table.remove(entry.times, 1)
	end

	-- Save immediately
	M.CacheManager.save(ACCESS_FILE, M.AccessTracker.data)
end

function M.AccessTracker.get_score(path, current_time)
	local entry = M.AccessTracker.data[path]
	if not entry or not entry.times or #entry.times == 0 then
		return 0
	end

	-- Calculate recency score with exponential decay
	local score = 0
	for _, access_time in ipairs(entry.times) do
		local age = current_time - access_time
		if age >= 0 then
			local decay = math.exp(-0.693 * age / HALF_LIFE_SECONDS)
			score = score + decay
		end
	end

	return score
end

-- =============================================================================
-- File Analysis
-- =============================================================================

M.FileAnalyzer = {}

function M.FileAnalyzer.extract_metadata(lines)
	local metadata = {
		header = lines[1] or "",
		word_count = 0,
		char_count = 0,
		tags = {},
		aliases = {},
		has_code = false,
		has_lists = false,
		has_links = false,
		avg_line_length = 0,
		complexity_score = 0,
		headers = {},
	}

	local total_length = 0
	local tag_set, alias_set = {}, {}

	for i, line in ipairs(lines) do
		-- Character and word counting
		metadata.char_count = metadata.char_count + #line
		metadata.word_count = metadata.word_count + select(2, line:gsub("%S+", ""))
		total_length = total_length + #line

		-- Extract headers using parser
		local heading = parser.parse_heading(line)
		if heading then
			table.insert(metadata.headers, {
				line_num = i,
				level = heading.level,
				text = heading.text,
				full_line = line,
			})
		end

		-- Detect code blocks
		if line:match("^```") or line:match("^%s*```") then
			metadata.has_code = true
		end

		-- Detect lists
		if line:match("^%s*[-*+]%s") or line:match("^%s*%d+%.%s") then
			metadata.has_lists = true
		end

		-- Detect links
		if line:match("%[.-%]%(.-%)") or line:match("https?://") then
			metadata.has_links = true
		end

		-- Extract article name
		local article = parser.extract_article_name(line)
		if article then
			alias_set[article] = true
		end

		-- Extract tags
		if line:match("^@[^@]") then
			local tag = line:match("^@([^@]+)")
			if tag then
				tag_set[tag] = true
			end
		end
	end

	-- Convert sets to arrays
	for tag in pairs(tag_set) do
		table.insert(metadata.tags, tag)
	end
	for alias in pairs(alias_set) do
		table.insert(metadata.aliases, alias)
	end

	-- Calculate averages and complexity
	metadata.avg_line_length = #lines > 0 and (total_length / #lines) or 0

	-- Simple complexity score
	metadata.complexity_score = (
		(metadata.has_code and 2 or 0)
		+ (metadata.has_lists and 1 or 0)
		+ (metadata.has_links and 1 or 0)
		+ (#metadata.tags > 5 and 2 or 0)
		+ (metadata.word_count > 1000 and 1 or 0)
	)

	return metadata
end

-- =============================================================================
-- Index Management
-- =============================================================================

M.IndexManager = {}
M.IndexManager.cache = M.CacheManager.load(CACHE_FILE)

function M.IndexManager.should_ignore_file(name)
	for _, ignored in ipairs(IGNORED_FILES) do
		if name == ignored then
			return true
		end
	end
	return false
end

function M.IndexManager.build_index()
	local notes_dir = fs.get_notes_dir()
	if not notes_dir then
		vim.notify("Zortex: g:zortex_notes_dir not set", vim.log.levels.ERROR)
		return M.IndexManager.cache
	end

	local ext = vim.g.zortex_extension
	if not ext then
		vim.notify("Zortex: g:zortex_extension not set", vim.log.levels.ERROR)
		return M.IndexManager.cache
	end

	local new_index = {}
	local seen = {}

	-- Get all note files
	local files = fs.find_files(notes_dir, "%" .. ext .. "$")

	for _, filepath in ipairs(files) do
		local filename = vim.fn.fnamemodify(filepath, ":t")

		if not M.IndexManager.should_ignore_file(filename) then
			seen[filepath] = true
			local stat = vim.loop.fs_stat(filepath)
			local mtime = stat and stat.mtime and stat.mtime.sec or 0

			local cached = M.IndexManager.cache[filepath]
			if cached and cached.mtime == mtime then
				-- Reuse cached entry
				new_index[filepath] = cached
			else
				-- Read and analyze file
				local lines = fs.read_lines(filepath)
				if lines then
					local metadata = M.FileAnalyzer.extract_metadata(lines)

					new_index[filepath] = {
						mtime = mtime,
						lines = lines,
						metadata = metadata,
					}
				end
			end
		end
	end

	-- Clean up deleted files
	for path in pairs(M.IndexManager.cache) do
		if not seen[path] then
			new_index[path] = nil
		end
	end

	return new_index
end

function M.IndexManager.update_sync()
	M.IndexManager.cache = M.IndexManager.build_index()
end

function M.IndexManager.update_async()
	vim.defer_fn(function()
		M.IndexManager.update_sync()
		M.CacheManager.save(CACHE_FILE, M.IndexManager.cache)
	end, 100)
end

-- Initialize async update on startup
vim.defer_fn(M.IndexManager.update_async, 100)

-- =============================================================================
-- Utilities (exposed for search.lua)
-- =============================================================================

M.Utils = {}

function M.Utils.extract_date_from_filename(fname)
	local basename = vim.fn.fnamemodify(fname, ":t")
	local stem = vim.fn.fnamemodify(basename, ":r")

	-- New format: YYYY-MM-DD.NNN.zortex
	local year, month, day = stem:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%.%d+$")
	if year and month and day then
		return string.format("%s-%s-%s", year, month, day)
	end

	-- Old format: YYYYWWDHHMMSS.zortex
	if stem:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
		local year = tonumber(stem:sub(1, 4))
		local week = tonumber(stem:sub(5, 6))
		local day = tonumber(stem:sub(7, 7))
		local doy = (week - 1) * 7 + day
		local jan1 = os.time({ year = year, month = 1, day = 1 })
		return os.date("%Y-%m-%d", jan1 + (doy - 1) * 86400)
	end

	return nil
end

-- =============================================================================
-- Debug Functions
-- =============================================================================

M.Debug = {}

function M.Debug.debug_access()
	print("=== Access Tracking Debug ===")
	local count = 0
	for path, data in pairs(M.AccessTracker.data) do
		count = count + 1
		local recent = data.times[#data.times]
		if recent then
			print(
				string.format(
					"%s: %d accesses, last: %s",
					vim.fn.fnamemodify(path, ":t"),
					data.count,
					os.date("%Y-%m-%d %H:%M:%S", recent)
				)
			)
		end
	end
	print(string.format("Total tracked files: %d", count))
	print(string.format("Access file: %s", ACCESS_FILE))
end

function M.Debug.debug_scoring()
	print("=== Scoring Debug ===")
	local current_time = os.time()
	for path, data in pairs(M.IndexManager.cache) do
		local score = M.AccessTracker.get_score(path, current_time)
		if score > 0 then
			print(string.format("%s: recency score = %.3f", vim.fn.fnamemodify(path, ":t"), score))
		end
	end
end

function M.Debug.track_access(filepath)
	if filepath then
		M.AccessTracker.record(filepath)
	else
		-- Track current buffer
		local current = vim.api.nvim_buf_get_name(0)
		if current and current ~= "" then
			M.AccessTracker.record(current)
		end
	end
end

function M.Debug.clear_access_history()
	M.AccessTracker.data = {}
	M.CacheManager.save(ACCESS_FILE, M.AccessTracker.data)
	print("Access history cleared")
end

return M
