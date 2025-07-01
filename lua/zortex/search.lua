-- search.lua – incremental exact‑substring note search with smart sorting & enhanced caching
--   • Space separates tokens (logical AND across the entire file)
--   • Use underscore "_" instead of spaces for phrase search (hello_world ↔ "hello world")
--   • Smart sorting based on: recency (30-day half-life), tags, length, word count, and more
--   • Access tracking for intelligent ranking
--   • Enhanced preview with better highlighting
--
-- 2025‑06‑30 — Major refactor with smart sorting & access tracking

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

--------------------------------------------------
-- Cache Management
--------------------------------------------------
local CacheManager = {}

function CacheManager.load(filepath)
	local f = io.open(filepath, "r")
	if not f then
		return {}
	end

	local content = f:read("*a")
	f:close()

	local ok, decoded = pcall(vim.fn.json_decode, content)
	return (ok and type(decoded) == "table") and decoded or {}
end

function CacheManager.save(filepath, data)
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
local AccessTracker = {}
AccessTracker.data = CacheManager.load(ACCESS_FILE)

function AccessTracker.record(path)
	if not AccessTracker.data[path] then
		AccessTracker.data[path] = {
			count = 0,
			times = {},
		}
	end

	local entry = AccessTracker.data[path]
	entry.count = entry.count + 1

	-- Keep only last 100 access times to prevent unbounded growth
	table.insert(entry.times, os.time())
	if #entry.times > 100 then
		table.remove(entry.times, 1)
	end

	-- Save immediately to ensure persistence
	CacheManager.save(ACCESS_FILE, AccessTracker.data)

	-- Debug log (uncomment to verify tracking)
	-- print(string.format("Accessed: %s (count: %d)", vim.fn.fnamemodify(path, ":t"), entry.count))
end

function AccessTracker.get_score(path, current_time)
	local entry = AccessTracker.data[path]
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
local FileAnalyzer = {}

function FileAnalyzer.extract_metadata(lines)
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
	}

	local total_length = 0
	local tag_set, alias_set = {}, {}

	for i, line in ipairs(lines) do
		-- Character and word counting
		metadata.char_count = metadata.char_count + #line
		metadata.word_count = metadata.word_count + select(2, line:gsub("%S+", ""))
		total_length = total_length + #line

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
		if line:match("^@@alias") then
			local alias = line:match("^@@alias%s+(.+)")
			if alias then
				alias_set[alias] = true
			end
		end

		-- Extract tags
		for tag in line:gmatch("@(%w+)") do
			if tag ~= "alias" then -- Don't count @alias as a tag
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
local IndexManager = {}
IndexManager.cache = CacheManager.load(CACHE_FILE)

function IndexManager.stat_mtime(path)
	local stat = uv.fs_stat(path)
	return stat and stat.mtime and stat.mtime.sec or 0
end

function IndexManager.read_file_lines(path)
	local lines = {}
	local ok, iter = pcall(io.lines, path)
	if ok then
		for line in iter do
			lines[#lines + 1] = line
		end
	end
	return lines
end

function IndexManager.build_index()
	if not vim.g.zortex_notes_dir or not vim.g.zortex_extension then
		vim.notify("Zortex: Missing configuration", vim.log.levels.ERROR)
		return IndexManager.cache
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
		return IndexManager.cache
	end

	while true do
		local name, type = uv.fs_scandir_next(handle)
		if not name then
			break
		end

		if type == "file" and name:sub(-#ext) == ext then
			local path = dir .. name
			seen[path] = true
			local mtime = IndexManager.stat_mtime(path)

			local cached = IndexManager.cache[path]
			if cached and cached.mtime == mtime then
				-- Reuse cached entry
				new_index[path] = cached
			else
				-- Read and analyze file
				local lines = IndexManager.read_file_lines(path)
				local metadata = FileAnalyzer.extract_metadata(lines)

				new_index[path] = {
					mtime = mtime,
					lines = lines,
					metadata = metadata,
				}
			end
		end
	end

	-- Clean up deleted files
	for path in pairs(IndexManager.cache) do
		if not seen[path] then
			new_index[path] = nil
		end
	end

	return new_index
end

function IndexManager.update_sync()
	IndexManager.cache = IndexManager.build_index()
end

function IndexManager.update_async()
	-- Simple deferred update - avoids libuv worker complexity
	-- The sync update is already fast due to mtime checking
	vim.defer_fn(function()
		IndexManager.update_sync()
		CacheManager.save(CACHE_FILE, IndexManager.cache)
	end, 100)
end

-- Alternative: True async using Neovim jobs (more reliable than libuv workers)
function IndexManager.update_async_job()
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
						local cached = IndexManager.cache[path]

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
					IndexManager.update_sync()
					CacheManager.save(CACHE_FILE, IndexManager.cache)
				end)
			end
		end,
	})
end

-- Initialize async update on startup
vim.defer_fn(IndexManager.update_async, 100)

--------------------------------------------------
-- Utilities
--------------------------------------------------
local Utils = {}

function Utils.parse_tokens(prompt)
	local tokens = {}
	for token in (prompt or ""):gmatch("%S+") do
		tokens[#tokens + 1] = token:gsub("_", " ")
	end
	return tokens
end

function Utils.format_timestamp(ts)
	return os.date("%Y-%m-%d", ts)
end

function Utils.extract_header_name(title)
	if title:match("^@@") then
		return title:sub(3):gsub("^%s+", ""):gsub("%s+$", "")
	end
	return title
end

function Utils.extract_date_from_filename(fname)
	local basename = fname:match("([^/]+)$")
	local stem = basename:match("^(.+)%.[^.]+$") or basename

	if stem:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
		local year = tonumber(stem:sub(1, 4))
		local week = tonumber(stem:sub(5, 6))
		local day = tonumber(stem:sub(7, 7))
		local doy = (week - 1) * 7 + day
		local jan1 = os.time({ year = year, month = 1, day = 1 })
		return Utils.format_timestamp(jan1 + (doy - 1) * 86400)
	end

	return nil
end

function Utils.extract_aliases_and_tags(lines)
	local out, seen = {}, {}

	for i = 2, math.min(15, #lines) do
		local line = lines[i]
		if not seen[line] and line:match("^@+%w+") then -- @@alias or @tag
			out[#out + 1] = line
			seen[line] = true
		end
	end

	table.sort(out)
	return table.concat(out, " ")
end

--------------------------------------------------
-- Smart Sorter with Scoring
--------------------------------------------------
local function calculate_entry_score(entry, tokens, current_time)
	-- Defensive checks
	if type(entry) ~= "table" then
		return 0
	end

	local scores = {
		recency = 0,
		relevance = 0,
		richness = 0,
		structure = 0,
	}

	-- Recency score with 30-day half-life
	if entry.filename then
		scores.recency = AccessTracker.get_score(entry.filename, current_time)
		-- Store for debugging
		entry.recency_score = scores.recency
	end

	-- Base score for all entries (ensures recently accessed files rank high even with no query)
	if #tokens == 0 then
		-- When no search terms, heavily weight recency
		return scores.recency * 10 + 1
	end

	-- Relevance score based on token matches
	local relevance_multiplier = 1
	local has_any_match = false

	for _, token in ipairs(tokens) do
		local tok_lower = token:lower()

		-- Header match (highest priority)
		if entry.header_name and entry.header_name:lower():find(tok_lower, 1, true) then
			relevance_multiplier = relevance_multiplier * 5
			has_any_match = true
		end

		-- Tag/alias match (high priority)
		if entry.aliases_tags and entry.aliases_tags:lower():find(tok_lower, 1, true) then
			relevance_multiplier = relevance_multiplier * 3
			has_any_match = true
		end

		-- Content match (standard priority)
		if entry.matched_line and entry.matched_line:lower():find(tok_lower, 1, true) then
			relevance_multiplier = relevance_multiplier * 1.5
			has_any_match = true
		end
	end

	-- If no matches found, return very low score
	if not has_any_match and #tokens > 0 then
		return 0.001
	end

	scores.relevance = math.log(relevance_multiplier + 1) -- Logarithmic scaling

	-- Content richness score
	local meta = entry.metadata
	if meta then
		scores.richness = (
			math.min(#(meta.tags or {}), 5) * 0.4 -- Tag count (capped)
			+ math.log(math.max(1, (meta.word_count or 0) / 100)) * 0.3 -- Word count (log scale)
			+ (entry.line_count and math.log(entry.line_count + 1) * 0.2 or 0) -- Line count
			+ ((meta.has_code or meta.has_links) and 0.5 or 0) -- Special content
		)
	end

	-- Structure quality score
	if meta then
		scores.structure = (
			((meta.avg_line_length or 0) > 20 and (meta.avg_line_length or 0) < 80 and 1 or 0)
			+ (meta.has_lists and 0.5 or 0)
			+ ((meta.complexity_score or 0) > 2 and 0.5 or 0)
		)
	end

	-- Calculate weighted total
	local weights = {
		recency = 6.0, -- Increased weight for recency
		relevance = 4.0, -- Still important for search matches
		richness = 1.5,
		structure = 0.5,
	}

	local total = 0
	for key, weight in pairs(weights) do
		total = total + (scores[key] * weight)
	end

	-- Ensure minimum score
	return math.max(total, 0.001)
end

local function create_smart_sorter()
	local ts_sorters = require("telescope.sorters")

	-- Store a mapping from ordinal to entry for lookup
	local ordinal_to_entry = {}

	return ts_sorters.Sorter:new({
		-- Store entries when they're created
		start = function(self, prompt)
			ordinal_to_entry = {}
		end,

		scoring_function = function(self, prompt, line, entry)
			-- Handle both cases: when we get just ordinal or full entry
			local actual_entry = entry

			if type(line) == "string" and not entry then
				-- We got just the ordinal, need to look up the entry
				actual_entry = ordinal_to_entry[line]
				if not actual_entry then
					return 999999
				end
			elseif type(entry) == "table" and entry.ordinal then
				-- We have the full entry, store it for later lookup
				ordinal_to_entry[entry.ordinal] = entry
				actual_entry = entry
			else
				return 999999
			end

			if not actual_entry.score_calculated then
				local tokens = Utils.parse_tokens(prompt)
				local current_time = os.time()

				actual_entry.total_score = calculate_entry_score(actual_entry, tokens, current_time)
				actual_entry.score_calculated = true
			end

			-- In Telescope, LOWER scores rank HIGHER
			local score = 1000 / (actual_entry.total_score + 1)

			return score
		end,

		highlighter = function(_, prompt, display)
			-- ... (same as before)
		end,
	})
end

local function norm(x, max) -- 0 ≤ x ≤ max ⇒ 0 … 1
	if max == 0 then
		return 1
	end
	return x / max
end

-- compute a vault‑wide “oldest possible age” once at startup so every score
-- lands nicely in the 0…1 bracket.  (This is fast: just stats every file.)
local NOW = uv.now() / 1000 -- libuv gives ms; scale to seconds
local NOTES_DIR = vim.g.zortex_notes_dir or (vim.fn.expand("~") .. "/.zortex/")
local function max_file_age()
	local max = 0
	for _, path in ipairs(vim.fn.globpath(NOTES_DIR, "*", false, true)) do
		local stat = uv.fs_stat(path)
		if stat and stat.mtime.sec > 0 then
			local age = NOW - stat.mtime.sec
			if age > max then
				max = age
			end
		end
	end
	return max
end

--------------------------------------------------
-- Note Creation
--------------------------------------------------
local function create_new_note(prompt_bufnr)
	local actions = require("telescope.actions")
	actions.close(prompt_bufnr)

	local name = os.date("%Y%W%u%H%M%S") .. vim.g.zortex_extension
	local path = vim.g.zortex_notes_dir .. name

	vim.cmd("edit " .. path)
	vim.defer_fn(function()
		vim.api.nvim_buf_set_lines(0, 0, 0, false, { "@@" })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd("startinsert")
	end, 100)
end

--------------------------------------------------
-- Entry Opening with Access Tracking
--------------------------------------------------
local function open_location(entry, cmd)
	cmd = cmd or "edit"
	if entry and entry.filename and entry.lnum then
		-- Track access
		AccessTracker.record(entry.filename)

		-- Open file
		vim.cmd(string.format("%s %s", cmd, entry.filename))
		vim.fn.cursor(entry.lnum, 1)
	end
end

--------------------------------------------------
-- Main Search Function
--------------------------------------------------
function M.search(opts)
	opts = opts or {}

	if not vim.g.zortex_notes_dir or not vim.g.zortex_extension then
		vim.notify("Zortex Search: set vim.g.zortex_notes_dir & vim.g.zortex_extension", vim.log.levels.ERROR)
		return
	end

	local telescope = require("telescope")
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local conf = require("telescope.config").values
	local previewers = require("telescope.previewers")

	-- Update index
	IndexManager.update_sync()

	-- Entry gathering function
	local function gather(prompt)
		prompt = prompt or ""
		local tokens = Utils.parse_tokens(prompt)
		local results = {}
		local empty = #tokens == 0

		for path, data in pairs(IndexManager.cache) do
			local title = data.lines[1] or ""
			local header_name = Utils.extract_header_name(title)
			local date_str = Utils.extract_date_from_filename(path) or Utils.format_timestamp(data.mtime)
			local tags = Utils.extract_aliases_and_tags(data.lines)

			-- Token matching
			local seen_tok = {}
			local first_line, first_idx = nil, nil

			for idx, line in ipairs(data.lines) do
				for _, tok in ipairs(tokens) do
					if not seen_tok[tok] and line:lower():find(tok:lower(), 1, true) then
						seen_tok[tok] = { idx, line }
						if not first_line then
							first_idx, first_line = idx, line
						end
					end
				end
			end

			-- Check if all tokens match
			local qualifies = empty
			if not empty then
				qualifies = true
				for _, tok in ipairs(tokens) do
					if not seen_tok[tok] then
						qualifies = false
						break
					end
				end
			end

			if qualifies then
				-- Build display with recency indicator
				local recency_indicator = ""
				if AccessTracker.data[path] and #AccessTracker.data[path].times > 0 then
					local last_access = AccessTracker.data[path].times[#AccessTracker.data[path].times]
					local age_days = (os.time() - last_access) / 86400
					if age_days < 1 then
						recency_indicator = "● " -- Today
					elseif age_days < 3 then
						recency_indicator = "◐ " -- This week
					elseif age_days < 7 then
						recency_indicator = "○ " -- This month
					end
				end

				-- Build display
				local extra = {}
				if not empty then
					for _, v in pairs(seen_tok) do
						if v[2] ~= first_line then
							extra[#extra + 1] = v[2]
						end
					end
				end

				local parts = {
					date_str,
					recency_indicator .. header_name .. (tags ~= "" and (" " .. tags) or ""),
				}

				-- Show the matching query, removing leading whitespace
				local has_extra = #extra > 0
				local first_diff = first_line and first_line ~= title
				if first_diff or has_extra then
					local preview = first_diff and first_line or ""
					if has_extra then
						local extra_str = table.concat(extra, " ∥ ")
						preview = preview ~= "" and (preview .. " ∥ " .. extra_str) or extra_str
					end
					parts[#parts + 1] = string.gsub(preview, "^%s+", "")
				end

				local display = table.concat(parts, " | ")
				local ordinal = table.concat({ header_name, date_str, tags, first_line or "" }, " ")

				results[#results + 1] = {
					value = path .. ":" .. (first_idx or 1),
					ordinal = ordinal,
					display = display,
					filename = path,
					lnum = first_idx or 1,
					header_name = header_name,
					tags = tags,
					matched_line = first_line,
					mtime = data.mtime,
					metadata = data.metadata,
					line_count = #data.lines,
					score_calculated = false,
				}
			end
		end

		return results
	end

	-- Create finder and sorter
	local finder = finders.new_dynamic({
		fn = gather,
		entry_maker = function(e)
			return e
		end,
	})

	local sorter = create_smart_sorter()

	-- Create previewer
	local previewer = (vim.fn.executable("bat") == 1)
			and previewers.new_termopen_previewer({
				get_command = function(entry)
					local cmd = {
						"bat",
						"--style=numbers,changes",
						"--color=always",
						"--language=markdown", -- Using markdown for better highlighting
						entry.filename,
					}
					if entry.lnum then
						table.insert(cmd, 5, "--highlight-line")
						table.insert(cmd, 6, tostring(entry.lnum))
					end
					return cmd
				end,
			})
		or conf.grep_previewer(opts)

	-- Create picker
	pickers
		.new(opts, {
			prompt_title = "Zortex Smart Search",
			default_text = "",
			finder = finder,
			sorter = sorter,
			previewer = previewer,
			attach_mappings = function(bufnr, map)
				-- Default action: open and track access
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(bufnr)
					open_location(sel)
				end)

				-- Create new note
				map({ "i", "n" }, "<C-o>", function()
					create_new_note(bufnr)
				end)

				-- Open in split
				map({ "i", "n" }, "<C-x>", function()
					local sel = action_state.get_selected_entry()
					actions.close(bufnr)
					open_location(sel, "split")
				end)

				-- Open in vsplit
				map({ "i", "n" }, "<C-v>", function()
					local sel = action_state.get_selected_entry()
					actions.close(bufnr)
					open_location(sel, "vsplit")
				end)

				return true
			end,
		})
		:find()
end

-- Debug function to check access tracking
function M.debug_access()
	print("=== Access Tracking Debug ===")
	local count = 0
	for path, data in pairs(AccessTracker.data) do
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

-- Debug function to show scoring for current results
function M.debug_scoring()
	print("=== Scoring Debug ===")
	local current_time = os.time()
	for path, data in pairs(IndexManager.cache) do
		local score = AccessTracker.get_score(path, current_time)
		if score > 0 then
			print(string.format("%s: recency score = %.3f", vim.fn.fnamemodify(path, ":t"), score))
		end
	end
end

-- Manual access tracking (useful for testing or external integrations)
function M.track_access(filepath)
	if filepath then
		AccessTracker.record(filepath)
	else
		-- Track current buffer if no filepath provided
		local current = vim.api.nvim_buf_get_name(0)
		if current and current ~= "" then
			AccessTracker.record(current)
		end
	end
end

-- Clear access history (for testing or privacy)
function M.clear_access_history()
	AccessTracker.data = {}
	CacheManager.save(ACCESS_FILE, AccessTracker.data)
	print("Access history cleared")
end

-- Uncomment for testing:
-- M.search()

return M
