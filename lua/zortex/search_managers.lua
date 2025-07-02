local M = {}

--------------------------------------------------
-- Dependencies
--------------------------------------------------
local uv = vim.loop
local std_cache = vim.fn.stdpath("cache")
local CACHE_FILE = std_cache .. "/zortex_index.json"
local ACCESS_FILE = std_cache .. "/zortex_access.json"

--------------------------------------------------
-- Constants
--------------------------------------------------
local HALF_LIFE_DAYS = 30
local HALF_LIFE_SECONDS = HALF_LIFE_DAYS * 86400
local IGNORED_FILES = { "storage.zortex" } -- Files to ignore in search

--------------------------------------------------
-- Cache Management
--------------------------------------------------
M.CacheManager = {}

function M.CacheManager.load(filepath)
	local f = io.open(filepath, "r")
	if not f then
		return {}
	end

	local content = f:read("*a")
	f:close()

	local ok, decoded = pcall(vim.fn.json_decode, content)
	return (ok and type(decoded) == "table") and decoded or {}
end

function M.CacheManager.save(filepath, data)
	local ok, encoded = pcall(vim.fn.json_encode, data)
	if not ok then
		return false
	end

	local f = io.open(filepath, "w")
	if not f then
		return false
	end

	f:write(encoded)
	f:close()
	return true
end

--------------------------------------------------
-- Access Tracking
--------------------------------------------------
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

	-- Keep only last 100 access times to prevent unbounded growth
	table.insert(entry.times, os.time())
	if #entry.times > 100 then
		table.remove(entry.times, 1)
	end

	-- Save immediately to ensure persistence
	M.CacheManager.save(ACCESS_FILE, M.AccessTracker.data)

	-- Debug log (uncomment to verify tracking)
	-- print(string.format("Accessed: %s (count: %d)", vim.fn.fnamemodify(path, ":t"), entry.count))
end

function M.AccessTracker.get_score(path, current_time)
	local entry = M.AccessTracker.data[path]
	if not entry or not entry.times or #entry.times == 0 then
		return 0
	end

	-- Calculate recency score with exponential decay (half-life)
	local score = 0
	for _, access_time in ipairs(entry.times) do
		local age = current_time - access_time
		if age >= 0 then -- Sanity check for time
			local decay = math.exp(-0.693 * age / HALF_LIFE_SECONDS) -- ln(2) ≈ 0.693
			score = score + decay
		end
	end

	return score
end

--------------------------------------------------
-- File Analysis
--------------------------------------------------
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
		headers = {}, -- Store headers with their levels
	}

	local total_length = 0
	local tag_set, alias_set = {}, {}

	for i, line in ipairs(lines) do
		-- Character and word counting
		metadata.char_count = metadata.char_count + #line
		metadata.word_count = metadata.word_count + select(2, line:gsub("%S+", ""))
		total_length = total_length + #line

		-- Extract headers
		local header_match = line:match("^(#+)%s+(.+)")
		if header_match then
			local level = #line:match("^#+")
			table.insert(metadata.headers, {
				line_num = i,
				level = level,
				text = line:match("^#+%s+(.+)"),
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

		-- Extract aliases
		if line:match("^@@.") then
			local alias = line:match("^@@(.+)")
			if alias then
				alias_set[alias] = true
			end
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

	-- Simple complexity score based on various factors
	metadata.complexity_score = (
		(metadata.has_code and 2 or 0)
		+ (metadata.has_lists and 1 or 0)
		+ (metadata.has_links and 1 or 0)
		+ (#metadata.tags > 5 and 2 or 0)
		+ (metadata.word_count > 1000 and 1 or 0)
	)

	return metadata
end

--------------------------------------------------
-- Index Management (Refactored)
--------------------------------------------------
M.IndexManager = {}
M.IndexManager.cache = M.CacheManager.load(CACHE_FILE)

function M.IndexManager.stat_mtime(path)
	local stat = uv.fs_stat(path)
	return stat and stat.mtime and stat.mtime.sec or 0
end

function M.IndexManager.read_file_lines(path)
	local lines = {}
	local ok, iter = pcall(io.lines, path)
	if ok then
		for line in iter do
			lines[#lines + 1] = line
		end
	end
	return lines
end

function M.IndexManager.should_ignore_file(name)
	for _, ignored in ipairs(IGNORED_FILES) do
		if name == ignored then
			return true
		end
	end
	return false
end

function M.IndexManager.build_index()
	if not vim.g.zortex_notes_dir or not vim.g.zortex_extension then
		vim.notify("Zortex: Missing configuration", vim.log.levels.ERROR)
		return M.IndexManager.cache
	end

	local dir = vim.g.zortex_notes_dir
	if not dir:match("/$") then
		dir = dir .. "/"
		vim.g.zortex_notes_dir = dir
	end

	local ext = vim.g.zortex_extension
	local new_index = {}
	local seen = {}

	local handle = uv.fs_scandir(dir)
	if not handle then
		vim.notify("Zortex: Cannot scan directory " .. dir, vim.log.levels.ERROR)
		return M.IndexManager.cache
	end

	while true do
		local name, type = uv.fs_scandir_next(handle)
		if not name then
			break
		end

		-- Skip ignored files
		if type == "file" and name:sub(-#ext) == ext and not M.IndexManager.should_ignore_file(name) then
			local path = dir .. name
			seen[path] = true
			local mtime = M.IndexManager.stat_mtime(path)

			local cached = M.IndexManager.cache[path]
			if cached and cached.mtime == mtime then
				-- Reuse cached entry
				new_index[path] = cached
			else
				-- Read and analyze file
				local lines = M.IndexManager.read_file_lines(path)
				local metadata = M.FileAnalyzer.extract_metadata(lines)

				new_index[path] = {
					mtime = mtime,
					lines = lines,
					metadata = metadata,
				}
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
	-- Simple deferred update - avoids libuv worker complexity
	-- The sync update is already fast due to mtime checking
	vim.defer_fn(function()
		M.IndexManager.update_sync()
		M.CacheManager.save(CACHE_FILE, M.IndexManager.cache)
	end, 100)
end

-- Alternative: True async using Neovim jobs (more reliable than libuv workers)
function M.IndexManager.update_async_job()
	if not vim.g.zortex_notes_dir or not vim.g.zortex_extension then
		return
	end

	local dir = vim.g.zortex_notes_dir
	if not dir:match("/$") then
		dir = dir .. "/"
	end

	-- Create a Lua script to run in a separate process
	local script = string.format(
		[[
        local dir = %q
        local ext = %q
        local output = {}
        
        -- Scan directory
        local handle = io.popen('find "' .. dir .. '" -name "*' .. ext .. '" -type f')
        if handle then
            for path in handle:lines() do
                local stat_handle = io.popen('stat -c %%Y "' .. path .. '" 2>/dev/null || stat -f %%m "' .. path .. '" 2>/dev/null')
                local mtime = stat_handle and stat_handle:read("*a"):match("%%d+") or "0"
                if stat_handle then stat_handle:close() end
                
                table.insert(output, path .. "|" .. mtime)
            end
            handle:close()
        end
        
        print(table.concat(output, "\n"))
    ]],
		dir,
		vim.g.zortex_extension
	)

	-- Run job
	local output_lines = {}
	vim.fn.jobstart({ "lua", "-e", script }, {
		on_stdout = function(_, data)
			vim.list_extend(output_lines, data)
		end,
		on_exit = function()
			-- Process results in main thread
			local updates_needed = false
			for _, line in ipairs(output_lines) do
				if line ~= "" then
					local path, mtime_str = line:match("^(.+)|(%d+)$")
					if path and mtime_str then
						local mtime = tonumber(mtime_str) or 0
						local cached = M.IndexManager.cache[path]

						if not cached or cached.mtime ~= mtime then
							updates_needed = true
							break
						end
					end
				end
			end

			-- If updates needed, do a sync update
			if updates_needed then
				vim.schedule(function()
					M.IndexManager.update_sync()
					M.CacheManager.save(CACHE_FILE, M.IndexManager.cache)
				end)
			end
		end,
	})
end

-- Initialize async update on startup
vim.defer_fn(M.IndexManager.update_async, 100)

--------------------------------------------------
-- Debug
--------------------------------------------------
M.Debug = {}

-- Debug function to check access tracking
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
					os.date("%Y-%m-%d %H:%M:%M", recent)
				)
			)
		end
	end
	print(string.format("Total tracked files: %d", count))
	print(string.format("Access file: %s", ACCESS_FILE))
end

-- Debug function to show scoring for current results
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

-- Manual access tracking (useful for testing or external integrations)
function M.Debug.track_access(filepath)
	if filepath then
		M.AccessTracker.record(filepath)
	else
		-- Track current buffer if no filepath provided
		local current = vim.api.nvim_buf_get_name(0)
		if current and current ~= "" then
			M.AccessTracker.record(current)
		end
	end
end

-- Clear access history (for testing or privacy)
function M.Debug.clear_access_history()
	M.AccessTracker.data = {}
	M.CacheManager.save(ACCESS_FILE, M.AccessTracker.data)
	print("Access history cleared")
end

return M
