-- services/search.lua - Search service with improved hierarchical matching
local M = {}

local Section = require("zortex.core.section")
local Events = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local constants = require("zortex.constants")
local parser = require("zortex.utils.parser")
local fs = require("zortex.utils.filesystem")

-- =============================================================================
-- Search Configuration
-- =============================================================================

local cfg = {} -- Config.ui.search

-- =============================================================================
-- File Modification Cache
-- =============================================================================

local FileCache = {
	cache = {}, -- filepath -> { mtime, document }
	max_files = 100,
}

function FileCache:get(filepath)
	local stat = vim.loop.fs_stat(filepath)
	if not stat then
		return nil
	end

	local cached = self.cache[filepath]
	if cached and cached.mtime == stat.mtime.sec then
		return cached.document
	end

	-- File modified or not cached, need to reload
	return nil
end

function FileCache:set(filepath, document)
	local stat = vim.loop.fs_stat(filepath)
	if not stat then
		return
	end

	self.cache[filepath] = {
		mtime = stat.mtime.sec,
		document = document,
	}

	-- Limit cache size
	local count = vim.tbl_count(self.cache)
	if count > self.max_files then
		-- Remove oldest entries
		local entries = {}
		for fp, data in pairs(self.cache) do
			table.insert(entries, { filepath = fp, mtime = data.mtime })
		end
		table.sort(entries, function(a, b)
			return a.mtime < b.mtime
		end)

		for i = 1, count - self.max_files do
			self.cache[entries[i].filepath] = nil
		end
	end
end

function FileCache:clear()
	self.cache = {}
end

-- =============================================================================
-- Document Cache for Search
-- =============================================================================

local SearchDocumentCache = {
	file_cache = FileCache,
	buffer_cache = {}, -- bufnr -> document
}

-- Extract all article names from the beginning of the document
local function extract_all_article_names(lines)
	local names = {}
	local code_tracker = parser.CodeBlockTracker:new()

	for i = 1, math.min(10, #lines) do
		local in_code_block = code_tracker:update(lines[i])
		if not in_code_block then
			local name = parser.extract_article_name(lines[i])
			if name then
				table.insert(names, name)
			else
				-- Stop when we hit a non-article line
				break
			end
		end
	end
	return names
end

-- Create a lightweight document structure for search
local function create_search_document(filepath, lines, bufnr)
	local doc = {
		filepath = filepath,
		source = bufnr and "buffer" or "search_cache",
		bufnr = bufnr,
		sections = nil,
		article_names = {}, -- Changed to array
		stats = {
			sections = 0,
			tasks = 0,
		},
		lines = lines, -- Keep lines for searching
	}

	-- Extract all article names
	doc.article_names = extract_all_article_names(lines)

	-- Build section tree (similar to Document:parse_full but lighter)
	local builder = Section.SectionTreeBuilder:new()
	local code_tracker = parser.CodeBlockTracker:new()

	for line_num, line in ipairs(lines) do
		builder:update_current_end(line_num)

		local in_code_block = code_tracker:update(line)
		if not in_code_block then
			local section = Section.create_from_line(line, line_num, in_code_block)
			if section then
				builder:add_section(section)
			end

			-- Parse tasks
			local is_task = parser.is_task_line(line)
			if is_task then
				local current = builder.stack[#builder.stack] or builder.root
				table.insert(current.tasks, {
					line = line_num,
					text = parser.get_task_text(line),
				})
			end
		end
	end

	doc.sections = builder:get_tree()
	doc.sections.end_line = #lines

	if doc.sections then
		for _, child in ipairs(doc.sections.children) do
			doc.stats.sections = doc.stats.sections + 1
			doc.stats.tasks = doc.stats.tasks + #child.tasks
		end
	end

	return doc
end

-- Check if buffer is a Zortex file
local function is_zortex_buffer(bufnr)
	local filename = vim.api.nvim_buf_get_name(bufnr)
	if filename == "" then
		return false
	end

	local Config = require("zortex.config")
	return filename:match("%" .. Config.extension .. "$") ~= nil
end

-- Get document from buffer
local function get_buffer_document(bufnr)
	-- Check cache first
	local cached = SearchDocumentCache.buffer_cache[bufnr]
	if cached then
		return cached
	end

	-- Create new document from buffer
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		return nil
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local doc = create_search_document(filepath, lines, bufnr)

	-- Cache it
	SearchDocumentCache.buffer_cache[bufnr] = doc

	return doc
end

-- Load or get cached document for search
function SearchDocumentCache:get_document(filepath)
	-- Check if file is open in any buffer
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
			local buf_name = vim.api.nvim_buf_get_name(bufnr)
			if buf_name == filepath then
				return get_buffer_document(bufnr)
			end
		end
	end

	-- Check file cache
	local cached_doc = self.file_cache:get(filepath)
	if cached_doc then
		return cached_doc
	end

	-- Load from file
	local lines = fs.read_lines(filepath)
	if not lines then
		return nil
	end

	local doc = create_search_document(filepath, lines)
	self.file_cache:set(filepath, doc)
	return doc
end

-- Get all searchable documents
function SearchDocumentCache:get_all_documents()
	local docs = {}
	local seen = {} -- Use the canonical path to track seen files

	-- First, add all open buffer documents
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) and is_zortex_buffer(bufnr) then
			local filepath = vim.api.nvim_buf_get_name(bufnr)
			if filepath ~= "" then
				-- Resolve the path to its canonical form
				local canonical_path = vim.fn.resolve(filepath)
				if not seen[canonical_path] then
					local doc = get_buffer_document(bufnr)
					if doc then
						doc.filepath = canonical_path -- IMPORTANT: Update the doc's filepath
						table.insert(docs, doc)
						seen[canonical_path] = true
					end
				end
			end
		end
	end

	-- Then, find all note files and load them if not in buffers
	local note_files = fs.get_all_note_files()
	for _, filepath in ipairs(note_files) do
		-- Resolve the path to its canonical form
		local canonical_path = vim.fn.resolve(filepath)
		if not seen[canonical_path] then
			local doc = self:get_document(filepath)
			if doc then
				doc.filepath = canonical_path -- IMPORTANT: Update the doc's filepath
				table.insert(docs, doc)
				seen[canonical_path] = true -- Mark the canonical path as seen
			end
		end
	end

	return docs
end

-- Clear cache (for refresh)
function SearchDocumentCache:clear()
	self.file_cache:clear()
	self.buffer_cache = {}
end

-- Clear buffer cache entry when buffer changes
function SearchDocumentCache:invalidate_buffer(bufnr)
	self.buffer_cache[bufnr] = nil
end

-- =============================================================================
-- Access Tracking (for scoring)
-- =============================================================================

local AccessTracker = {
	data = {}, -- filepath -> { last_access, access_count }
	cache_file = vim.fn.stdpath("cache") .. "/zortex_access.json",
}

function AccessTracker.load()
	local data = fs.read_json(AccessTracker.cache_file)
	if data then
		AccessTracker.data = data
	end
end

function AccessTracker.save()
	fs.write_json(AccessTracker.cache_file, AccessTracker.data)
end

function AccessTracker.record(filepath)
	if not AccessTracker.data[filepath] then
		AccessTracker.data[filepath] = {
			last_access = 0,
			access_count = 0,
		}
	end

	AccessTracker.data[filepath].last_access = os.time()
	AccessTracker.data[filepath].access_count = AccessTracker.data[filepath].access_count + 1

	-- Save asynchronously
	vim.defer_fn(function()
		AccessTracker.save()
	end, 100)
end

function AccessTracker.get_score(filepath, current_time)
	local data = AccessTracker.data[filepath]
	if not data then
		return 0
	end

	-- Exponential decay with 30-day half-life
	local half_life_seconds = 30 * 86400
	local age = current_time - data.last_access
	local recency_score = math.exp(-0.693 * age / half_life_seconds)
	local frequency_score = math.log(data.access_count + 1)

	return recency_score * frequency_score
end

-- =============================================================================
-- Search History
-- =============================================================================

local SearchHistory = {
	entries = {},
	max_entries = 50,
}

function SearchHistory.add(entry)
	table.insert(SearchHistory.entries, 1, {
		timestamp = os.time(),
		tokens = entry.tokens,
		selected_file = entry.selected_file,
		selected_section = entry.selected_section,
		section_path = entry.section_path,
		score_contribution = {},
	})

	-- Limit history size
	while #SearchHistory.entries > SearchHistory.max_entries do
		table.remove(SearchHistory.entries)
	end

	-- Propagate score to parent sections
	SearchHistory.propagate_scores(SearchHistory.entries[1])
end

function SearchHistory.propagate_scores(entry)
	if not entry.section_path or not entry.selected_file then
		return
	end

	-- Base score that diminishes as we go up the hierarchy
	local base_score = 1.0
	local decay_factor = 0.8

	-- Update scores for each level in the section path
	for i = #entry.section_path, 1, -1 do
		local section = entry.section_path[i]
		local start_line = section.start_line or section.line_num or 0
		local score_key = entry.selected_file .. ":" .. start_line

		if not entry.score_contribution[score_key] then
			entry.score_contribution[score_key] = 0
		end

		entry.score_contribution[score_key] = entry.score_contribution[score_key] + base_score
		base_score = base_score * decay_factor
	end
end

function SearchHistory.get_score(filepath, line_num, section_path)
	local historical_score = 0

	for _, hist_entry in ipairs(SearchHistory.entries) do
		if hist_entry.selected_file == filepath and hist_entry.score_contribution then
			-- Check scores for this specific line
			local score_key = filepath .. ":" .. line_num
			historical_score = historical_score + (hist_entry.score_contribution[score_key] or 0)

			-- Also check parent sections
			if section_path then
				for _, section in ipairs(section_path) do
					local start_line = section.start_line or section.line_num or 0
					local parent_key = filepath .. ":" .. start_line
					historical_score = historical_score + (hist_entry.score_contribution[parent_key] or 0) * 0.5
				end
			end

			-- Apply time decay
			local days_ago = (os.time() - hist_entry.timestamp) / 86400
			historical_score = historical_score * math.exp(-0.1 * days_ago)
		end
	end

	return historical_score
end

-- =============================================================================
-- Token Parsing and Matching
-- =============================================================================

local function parse_tokens(prompt)
	local tokens = {}
	for token in (prompt or ""):gmatch("%S+") do
		-- Convert underscores to spaces and lowercase
		tokens[#tokens + 1] = token:gsub("_", " "):lower()
	end
	return tokens
end

local function token_matches_text(text, token, section_type)
	if not text then
		return 0
	end

	local text_lower = text:lower()
	local token_lower = token:lower()

	-- Strict matching for articles with @@
	if token_lower:sub(1, 2) == "@@" then
		if section_type == constants.SECTION_TYPE.ARTICLE then
			token_lower = token_lower:sub(3)
			if token_lower == "" then
				return 1
			end -- '@@' alone matches any article
		else
			return 0 -- Failed prefix enforcement
		end
	end

	-- Strict matching for headings with #
	if token_lower:sub(1, 1) == "#" and #token_lower > 1 then
		if section_type == constants.SECTION_TYPE.HEADING then
			token_lower = token_lower:match("^#+(.*)") or token_lower
		else
			return 0 -- Failed prefix enforcement
		end
	end

	if text_lower == token_lower then
		return 3 -- Exact Match
	elseif text_lower:sub(1, #token_lower) == token_lower then
		return 2 -- Prefix Match
	elseif text_lower:find(token_lower, 1, true) ~= nil then
		return 1 -- Substring Match
	end

	return 0
end

-- =============================================================================
-- Section Filtering Based on Token Count
-- =============================================================================

local function should_include_section_type(section_type, level, total_tokens, is_root_level)
	-- Special handling for root-level sections (before first heading)
	if
		is_root_level
		and (section_type == constants.SECTION_TYPE.BOLD_HEADING or section_type == constants.SECTION_TYPE.LABEL)
	then
		-- Treat root-level bold headings and labels like level-1 headings
		return should_include_section_type(constants.SECTION_TYPE.HEADING, 1, total_tokens, false)
	end

	local filters = cfg.token_filters or {}
	local filter = filters[total_tokens] or filters[4] or "all"

	-- Handle "all" case
	if filter == "all" then
		return section_type ~= constants.SECTION_TYPE.TAG
	end

	-- Check each allowed type
	for _, allowed in ipairs(filter) do
		if type(allowed) == "string" then
			if section_type == allowed then
				return true
			end
		elseif type(allowed) == "table" then
			-- Handle heading with max_level
			if allowed[1] == constants.SECTION_TYPE.HEADING and section_type == constants.SECTION_TYPE.HEADING then
				if not allowed.max_level or (level and level <= allowed.max_level) then
					return true
				end
			elseif section_type == allowed[1] then
				return true
			end
		end
	end

	return false
end

local function section_matches_mode(section, mode)
	if not section then
		return false
	end

	if mode == constants.SEARCH_MODES.ALL then
		return true
	end
	if mode == constants.SEARCH_MODES.ARTICLE then
		return section.type == constants.SECTION_TYPE.ARTICLE
	end
	if mode == constants.SEARCH_MODES.SECTION then
		return section.type == constants.SECTION_TYPE.ARTICLE
			or section.type == constants.SECTION_TYPE.HEADING
			or section.type == constants.SECTION_TYPE.BOLD_HEADING
			or section.type == constants.SECTION_TYPE.LABEL
	end
	if mode == constants.SEARCH_MODES.TASK then
		local tasks = section.tasks or {}
		return #tasks > 0
	end
	return false
end

-- =============================================================================
-- Hierarchical Search Implementation
-- =============================================================================

-- Build a flat list of all sections with their hierarchical context
local function build_section_index(lines)
	local sections = {}
	local code_tracker = parser.CodeBlockTracker:new()
	local current_path = {}
	local first_heading_seen = false

	for i = 1, #lines do
		local in_code_block = code_tracker:update(lines[i])
		local section_type = parser.detect_section_type(lines[i], in_code_block)

		local level = nil
		local text = nil
		local priority = nil

		if section_type ~= constants.SECTION_TYPE.TEXT and section_type ~= constants.SECTION_TYPE.TAG then
			-- Extract structural section details
			if section_type == constants.SECTION_TYPE.ARTICLE then
				text = parser.extract_article_name(lines[i])
				priority = constants.SECTION_HIERARCHY.get_priority(section_type)
			elseif section_type == constants.SECTION_TYPE.HEADING then
				local heading = parser.parse_heading(lines[i])
				if heading then
					text = heading.text
					level = heading.level
					priority = constants.SECTION_HIERARCHY.get_priority(section_type, level)
					first_heading_seen = true
				end
			elseif section_type == constants.SECTION_TYPE.BOLD_HEADING then
				local bold = parser.parse_bold_heading(lines[i])
				if bold then
					text = bold.text
					priority = constants.SECTION_HIERARCHY.get_priority(section_type)
				end
			elseif section_type == constants.SECTION_TYPE.LABEL then
				local label = parser.parse_label(lines[i])
				if label then
					text = label.text
					priority = constants.SECTION_HIERARCHY.get_priority(section_type)
				end
			end

			if text then
				-- Find section end
				local section_end = parser.find_section_end(lines, i, section_type, level)

				-- Update current path based on hierarchy
				while #current_path > 0 and current_path[#current_path].priority >= priority do
					table.remove(current_path)
				end

				local section_info = {
					start_line = i,
					type = section_type,
					text = text,
					level = level,
					end_line = section_end,
					priority = priority,
					is_root_level = not first_heading_seen,
					path = vim.deepcopy(current_path),
				}

				table.insert(sections, section_info)
				table.insert(current_path, section_info)
			end
		else
			-- Included for mixed/text search
			text = parser.trim(lines[i])
			if text ~= "" then
				priority = 100 -- Leaf node priority
				local section_info = {
					start_line = i,
					type = section_type,
					text = text,
					level = nil,
					end_line = i,
					priority = priority,
					is_root_level = not first_heading_seen,
					path = vim.deepcopy(current_path),
				}
				table.insert(sections, section_info)
			end
		end
	end

	return sections
end

local function check_path_match(full_path, tokens)
	if #tokens == 0 then
		return true, 0
	end
	local total_tokens = #tokens

	-- We try to match tokens sequentially through any valid sub-path
	for start_idx = 1, #full_path do
		local token_idx = 1
		local match_score = 0

		for path_idx = start_idx, #full_path do
			local path_section = full_path[path_idx]

			-- Multiple consecutive tokens can match against the same section text
			while token_idx <= total_tokens do
				local score = token_matches_text(path_section.text, tokens[token_idx], path_section.type)
				if score > 0 then
					match_score = match_score + score
					token_idx = token_idx + 1
				else
					break
				end
			end

			if token_idx > total_tokens then
				return true, match_score
			end
		end
	end

	return false, 0
end

-- Perform hierarchical search
local function search_document_hierarchically(doc, tokens, search_mode)
	local results = {}
	local lines = doc.lines
	if not lines then
		return results
	end

	local total_tokens = #tokens
	local section_index = build_section_index(lines)

	-- For empty search, return appropriate top-level sections
	if total_tokens == 0 then
		for _, section in ipairs(section_index) do
			if
				#section.path == 0
				and should_include_section_type(section.type, section.level, 1, section.is_root_level)
			then
				local result = Section.Section:new({
					type = section.type,
					text = section.text,
					start_line = section.start_line,
					end_line = section.end_line,
					level = section.level,
				})
				result._matched_path = { section }
				result._match_score = 0

				if section_matches_mode(result, search_mode) then
					table.insert(results, result)
				end
			end
		end
		return results
	end

	for _, section in ipairs(section_index) do
		-- Filter out results based on desired UI scope
		if should_include_section_type(section.type, section.level, total_tokens, section.is_root_level) then
			local full_path = vim.deepcopy(section.path)
			table.insert(full_path, section)

			-- Check token matches
			local matched, match_score = check_path_match(full_path, tokens)

			if matched then
				local result = Section.Section:new({
					type = section.type,
					text = section.text,
					start_line = section.start_line,
					end_line = section.end_line,
					level = section.level,
				})
				result._matched_path = full_path
				result._match_score = match_score

				if section_matches_mode(result, search_mode) then
					table.insert(results, result)
				end
			end
		end
	end

	return results
end

-- =============================================================================
-- Scoring Functions
-- =============================================================================

local function score_match(section_path, token_match_score)
	local score = (token_match_score or 0) * 100

	-- Bonus points based on the primary section matched
	local target_section = section_path[#section_path]
	if target_section then
		if target_section.type == constants.SECTION_TYPE.ARTICLE then
			score = score + 2000
		elseif target_section.type == constants.SECTION_TYPE.HEADING then
			score = score + 1000 - ((target_section.level or 1) * 50)
		elseif target_section.type == constants.SECTION_TYPE.BOLD_HEADING then
			score = score + 400
		elseif target_section.type == constants.SECTION_TYPE.LABEL then
			score = score + 300
		end
	end

	return score
end

-- =============================================================================
-- Breadcrumb Generation
-- =============================================================================

local function build_breadcrumb(section_path, exclude_last)
	if not section_path or #section_path == 0 then
		return "", {}
	end

	local parts = {}
	local sections = {}

	-- Determine how many sections to include
	local count = exclude_last and (#section_path - 1) or #section_path

	for i = 1, count do
		local section = section_path[i]
		if section.text and section.text ~= "Document Root" then
			local text = section.text
			-- Truncate long text strings for breadcrumbs
			if section.type == constants.SECTION_TYPE.TEXT and #text > 40 then
				text = text:sub(1, 37) .. "..."
			end
			table.insert(parts, text)
			table.insert(sections, section)
		end
	end

	return table.concat(parts, " › "), sections
end

-- =============================================================================
-- Main Search Function
-- =============================================================================

function M.search(query, opts)
	opts = opts or {}
	local search_mode = opts.search_mode or constants.SEARCH_MODES.SECTION
	local tokens = parse_tokens(query)
	local current_time = os.time()

	Logger.debug("search_service", "Searching", {
		query = query,
		tokens = tokens,
		search_mode = search_mode,
	})

	local all_docs = SearchDocumentCache:get_all_documents()
	local all_results = {}
	local seen_results = {}

	for _, doc in ipairs(all_docs) do
		local doc_sections = search_document_hierarchically(doc, tokens, search_mode)
		local doc_max_score = 0
		local doc_results = {}

		for _, section in ipairs(doc_sections) do
			local result_key = doc.filepath .. ":" .. section.start_line
			if not seen_results[result_key] then
				local section_path = section._matched_path
					or {
						{
							type = section.type,
							text = section.text,
							start_line = section.start_line,
							level = section.level,
						},
					}

				-- Build breadcrumb
				local breadcrumb, breadcrumb_sections = build_breadcrumb(section_path, false)
				local base_score = score_match(section_path, section._match_score)
				local access_score = AccessTracker.get_score(doc.filepath, current_time) * 50
				local history_score = SearchHistory.get_score(doc.filepath, section.start_line, section_path) * 30

				local total_score = base_score + access_score + history_score

				-- Track highest match scored within document for structural sorting
				if total_score > doc_max_score then
					doc_max_score = total_score
				end

				local bufnr = nil
				if doc.source == "buffer" and doc.bufnr then
					bufnr = doc.bufnr
				end

				local display_text = breadcrumb
				if #tokens <= 1 and doc.article_names and #doc.article_names > 0 then
					display_text = doc.article_names[1]
				end

				table.insert(doc_results, {
					section = section,
					score = total_score,
					breadcrumb = breadcrumb,
					breadcrumb_sections = section_path,
					display_text = display_text,
					filepath = doc.filepath,
					bufnr = bufnr,
					source = doc.source,
					section_path = section_path,
					article_names = doc.article_names or {},
				})

				seen_results[result_key] = true
			end
		end

		-- Imbue file results with their parent document's priority score
		if #doc_results > 0 then
			for _, res in ipairs(doc_results) do
				res.file_score = doc_max_score
				table.insert(all_results, res)
			end
		end
	end

	-- Sort structurally: best matching file groups together, then strict chronological/hierarchy completion ordering
	table.sort(all_results, function(a, b)
		-- 1. Sort by grouping file relevancy
		if math.abs(a.file_score - b.file_score) > 0.1 then
			return a.file_score > b.file_score
		end
		-- 2. Tie breaker groups by unique file
		if a.filepath ~= b.filepath then
			return a.filepath < b.filepath
		end
		-- 3. In same file, order as they appear natively (parents intrinsically precede their children)
		if a.section.start_line ~= b.section.start_line then
			return a.section.start_line < b.section.start_line
		end

		return a.score > b.score
	end)

	Events.emit("search:completed", {
		query = query,
		result_count = #all_results,
	})

	return all_results
end

-- =============================================================================
-- Result Opening
-- =============================================================================

function M.open_result(result, cmd)
	cmd = cmd or "edit"
	if not result or not result.filepath then
		return
	end

	-- Track access
	AccessTracker.record(result.filepath)

	-- Open file
	if result.bufnr and vim.api.nvim_buf_is_valid(result.bufnr) then
		-- Switch to existing buffer
		local wins = vim.fn.win_findbuf(result.bufnr)
		if #wins > 0 then
			vim.api.nvim_set_current_win(wins[1])
		else
			vim.cmd(cmd .. " #" .. result.bufnr)
		end
	else
		-- Open file
		vim.cmd(string.format("%s %s", cmd, vim.fn.fnameescape(result.filepath)))
	end

	-- Jump to section
	if result.section and result.section.start_line then
		vim.api.nvim_win_set_cursor(0, { result.section.start_line, 0 })
		vim.cmd("normal! zz")
	end

	Events.emit("search:result_opened", {
		filepath = result.filepath,
		section = result.section,
	})
end

-- =============================================================================
-- Search Statistics & Management
-- =============================================================================

function M.get_stats()
	local docs = SearchDocumentCache:get_all_documents()
	local total_sections = 0

	for _, doc in ipairs(docs) do
		if doc.stats then
			total_sections = total_sections + doc.stats.sections
		end
	end

	return {
		documents_loaded = #docs,
		total_sections = total_sections,
		access_history_count = vim.tbl_count(AccessTracker.data),
		search_history_count = #SearchHistory.entries,
		cache_documents = vim.tbl_count(SearchDocumentCache.file_cache.cache),
	}
end

function M.refresh_all()
	local stop_timer = Logger.start_timer("search_service.refresh_all")

	-- Clear search cache
	SearchDocumentCache:clear()

	Events.emit("search:cache_refreshed")
	stop_timer()
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup(opts)
	cfg = opts or {}

	-- Load access tracking data
	AccessTracker.load()

	-- Set up auto-save for access data
	local group = vim.api.nvim_create_augroup("ZortexSearchService", { clear = true })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			AccessTracker.save()
		end,
	})

	-- Invalidate buffer cache on changes
	local Config = require("zortex.config")
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		pattern = "*" .. Config.extension,
		callback = function(args)
			SearchDocumentCache:invalidate_buffer(args.buf)
		end,
	})
end

-- Configure token filters
function M.configure_token_filters(filters)
	cfg.token_filters = filters
end

-- Export history for UI
M.SearchHistory = SearchHistory

return M
