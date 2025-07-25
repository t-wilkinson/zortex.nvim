-- services/search.lua - Search service with independent document loading
local M = {}

local DocumentManager = require("zortex.core.document_manager")
local Section = require("zortex.core.section")
local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local constants = require("zortex.constants")
local parser = require("zortex.utils.parser")
local fs = require("zortex.utils.filesystem")
local Config = require("zortex.config")

-- =============================================================================
-- Search Configuration
-- =============================================================================

local cfg = {} -- Config.ui.search

-- =============================================================================
-- Search Modes
-- =============================================================================

M.modes = {
	SECTION = "section",
	ARTICLE = "article",
	TASK = "task",
	ALL = "all",
}

-- =============================================================================
-- Document Cache for Search
-- =============================================================================

local SearchDocumentCache = {
	documents = {}, -- filepath -> parsed document
	last_refresh = 0,
	refresh_interval = 60, -- seconds
}

-- Create a lightweight document structure for search
local function create_search_document(filepath, lines)
	local doc = {
		filepath = filepath,
		source = "search_cache",
		sections = nil,
		article_name = "",
		stats = {
			sections = 0,
			tasks = 0,
		},
	}

	-- Build section tree (similar to Document:parse_full but lighter)
	local builder = Section.SectionTreeBuilder:new()

	for line_num, line in ipairs(lines) do
		builder:update_current_end(line_num)

		local section = Section.create_from_line(line, line_num)
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

		-- Extract article name
		if line_num <= 10 and doc.article_name == "" then
			local name = parser.extract_article_name(line)
			if name then
				doc.article_name = name
			end
		end
	end

	doc.sections = builder:get_tree()
	doc.sections.end_line = #lines

	-- Update stats
	local function count_sections(section)
		doc.stats.sections = doc.stats.sections + 1
		doc.stats.tasks = doc.stats.tasks + #section.tasks
	end

	if doc.sections then
		for _, child in ipairs(doc.sections.children) do
			count_sections(child)
		end
	end

	return doc
end

-- Load or get cached document for search
function SearchDocumentCache:get_document(filepath)
	-- Check if document is open in buffer - prefer DocumentManager version
	for bufnr, doc in pairs(DocumentManager._instance.buffers) do
		if doc.filepath == filepath then
			return doc
		end
	end

	-- Check our search cache
	if self.documents[filepath] then
		return self.documents[filepath]
	end

	-- Load from file
	local lines = fs.read_lines(filepath)
	if not lines then
		return nil
	end

	local doc = create_search_document(filepath, lines)
	self.documents[filepath] = doc
	return doc
end

-- Get all searchable documents
function SearchDocumentCache:get_all_documents()
	local docs = {}
	local seen = {}

	-- First, add all buffer documents (source of truth)
	for bufnr, doc in pairs(DocumentManager._instance.buffers) do
		if doc.filepath then
			table.insert(docs, doc)
			seen[doc.filepath] = true
		end
	end

	-- Then, find all note files and load them if not in buffers
	local note_files = fs.get_all_note_files()
	for _, filepath in ipairs(note_files) do
		if not seen[filepath] then
			local doc = self:get_document(filepath)
			if doc then
				table.insert(docs, doc)
			end
		end
	end

	return docs
end

-- Clear cache (for refresh)
function SearchDocumentCache:clear()
	self.documents = {}
	self.last_refresh = os.time()
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
		local score_key = entry.selected_file .. ":" .. section.start_line

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
					local parent_key = filepath .. ":" .. section.start_line
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

local function token_matches_section_start(section, token)
	if not section or not section.text then
		return false
	end
	local section_lower = section.text:lower()
	local token_lower = token:lower()
	-- Prefix match for hierarchical searching
	return section_lower:sub(1, #token_lower) == token_lower
end

local function token_matches_section_anywhere(section, token)
	if not section or not section.text then
		return false
	end
	-- Use plain find for substring matching
	return section.text:lower():find(token, 1, true) ~= nil
end

-- =============================================================================
-- Section Filtering
-- =============================================================================

local function should_include_section(section, token_count)
	if not section then
		return false
	end

	if token_count == 1 then
		-- Only articles or level 1 headings
		return section.type == constants.SECTION_TYPE.ARTICLE
			or (section.type == constants.SECTION_TYPE.HEADING and section.level and section.level <= 1)
	elseif token_count == 2 then
		-- Articles and level 1-3 headings
		return section.type == constants.SECTION_TYPE.ARTICLE
			or (section.type == constants.SECTION_TYPE.HEADING and section.level and section.level <= 3)
			or section.type == constants.SECTION_TYPE.BOLD_HEADING
	else
		-- All section types except tags
		return section.type ~= constants.SECTION_TYPE.TAG
	end
end

local function section_matches_mode(section, mode)
	if not section then
		return false
	end

	if mode == M.modes.ALL then
		return true
	end
	if mode == M.modes.ARTICLE then
		return section.type == constants.SECTION_TYPE.ARTICLE
	end
	if mode == M.modes.SECTION then
		return section.type == constants.SECTION_TYPE.ARTICLE
			or section.type == constants.SECTION_TYPE.HEADING
			or section.type == constants.SECTION_TYPE.BOLD_HEADING
			or section.type == constants.SECTION_TYPE.LABEL
	end
	if mode == M.modes.TASK then
		local tasks = section.tasks or {}
		return #tasks > 0
	end
	return false
end

-- =============================================================================
-- Scoring Functions
-- =============================================================================

local function score_match(section_path, tokens)
	local score = 100

	-- Higher score for deeper (more specific) matches
	score = score + #section_path * 50

	-- Bonus for matching higher-level section types
	for i, section in ipairs(section_path) do
		if section.type == constants.SECTION_TYPE.ARTICLE then
			score = score + 200
		elseif section.type == constants.SECTION_TYPE.HEADING then
			score = score + (100 / (section.level or 1))
		elseif section.type == constants.SECTION_TYPE.BOLD_HEADING then
			score = score + 80
		elseif section.type == constants.SECTION_TYPE.LABEL then
			score = score + 60
		end

		-- Bonus for tokens matching section text
		if section.text then
			for _, token in ipairs(tokens) do
				if token_matches_section_start(section, token) then
					score = score + 100
				elseif token_matches_section_anywhere(section, token) then
					score = score + 50
				end
			end
		end
	end

	return score
end

-- =============================================================================
-- Breadcrumb Generation
-- =============================================================================

local function build_breadcrumb(section)
	if not section then
		return ""
	end

	local parts = {}

	-- If section has get_path method, use it
	if section.get_path then
		local path = section:get_path()
		for _, ancestor in ipairs(path) do
			if ancestor.text and ancestor.text ~= "Document Root" then
				table.insert(parts, ancestor.text)
			end
		end
	end

	-- Add the section itself
	if section.text and section.text ~= "Document Root" then
		table.insert(parts, section.text)
	end

	return table.concat(parts, " › ")
end

-- =============================================================================
-- Hierarchical Search Implementation
-- =============================================================================

local function search_document_hierarchically(doc, tokens, search_mode)
	local results = {}
	if not doc.sections then
		return results
	end

	-- For empty search, return document root if it has an article name
	if #tokens == 0 then
		if doc.article_name and doc.article_name ~= "" then
			table.insert(results, doc.sections)
		end
		return results
	end

	-- Track which sections we've already added to results
	local seen = {}

	-- Helper to recursively search a section tree
	local function search_section(section, token_index, parent_matched)
		if not section then
			return
		end

		if token_index > #tokens then
			-- We've matched all tokens, check if this section matches our mode
			if section_matches_mode(section, search_mode) and not seen[section] then
				seen[section] = true
				table.insert(results, section)
			end
			return
		end

		local token = tokens[token_index]
		local token_count = #tokens

		-- Check if current section should be considered based on token count
		if not should_include_section(section, token_count) then
			-- Still search children even if parent doesn't qualify
			if section.children then
				for _, child in ipairs(section.children) do
					search_section(child, token_index, false)
				end
			end
			return
		end

		-- Check if current section matches the token
		local matches = token_matches_section_start(section, token)

		if matches then
			-- This section matches, search children for next token
			if token_index == #tokens then
				-- Last token, add this section if it matches mode
				if section_matches_mode(section, search_mode) and not seen[section] then
					seen[section] = true
					table.insert(results, section)
				end
			end

			-- Search children for next token
			if section.children then
				for _, child in ipairs(section.children) do
					search_section(child, token_index + 1, true)
				end
			end
		else
			-- This section doesn't match, but still search children with same token
			if section.children then
				for _, child in ipairs(section.children) do
					search_section(child, token_index, false)
				end
			end
		end
	end

	-- Start search - check if root section itself matches
	if should_include_section(doc.sections, #tokens) and token_matches_section_start(doc.sections, tokens[1]) then
		search_section(doc.sections, 1, false)
	end

	-- Always search root's children
	if doc.sections.children then
		for _, child in ipairs(doc.sections.children) do
			search_section(child, 1, false)
		end
	end

	return results
end

-- =============================================================================
-- Main Search Function
-- =============================================================================

function M.search(query, opts)
	opts = opts or {}
	local search_mode = opts.search_mode or M.modes.SECTION
	local stop_timer = Logger.start_timer("search_service.search")
	local tokens = parse_tokens(query)
	local current_time = os.time()

	Logger.debug("search_service", "Searching", {
		query = query,
		tokens = tokens,
		search_mode = search_mode,
	})

	-- Get all documents using our search cache
	local all_docs = SearchDocumentCache:get_all_documents()

	local all_results = {}

	for _, doc in ipairs(all_docs) do
		local doc_sections = search_document_hierarchically(doc, tokens, search_mode)

		for _, section in ipairs(doc_sections) do
			local breadcrumb = build_breadcrumb(section)

			-- Build section path for scoring
			local section_path = {}
			if section.get_path then
				section_path = section:get_path()
			end
			table.insert(section_path, section) -- Include self in path

			local base_score = score_match(section_path, tokens)
			local access_score = AccessTracker.get_score(doc.filepath, current_time) * 50
			local history_score = SearchHistory.get_score(doc.filepath, section.start_line, section_path) * 30

			-- Get bufnr if document is from buffer
			local bufnr = nil
			if doc.source == "buffer" and doc.bufnr then
				bufnr = doc.bufnr
			end

			table.insert(all_results, {
				section = section,
				score = base_score + access_score + history_score,
				breadcrumb = breadcrumb,
				filepath = doc.filepath,
				bufnr = bufnr,
				source = doc.source,
				section_path = section_path,
			})
		end
	end

	-- Sort by score (highest first)
	table.sort(all_results, function(a, b)
		return a.score > b.score
	end)

	stop_timer({
		result_count = #all_results,
		file_count = #all_docs,
	})

	EventBus.emit("search:completed", {
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

	EventBus.emit("search:result_opened", {
		filepath = result.filepath,
		section = result.section,
	})
end

-- =============================================================================
-- Diagnostic Functions
-- =============================================================================

function M.diagnose()
	local all_docs = SearchDocumentCache:get_all_documents()

	print("=== SEARCH DIAGNOSTIC ===")
	print(string.format("Total documents found: %d", #all_docs))

	for i, doc in ipairs(all_docs) do
		print(string.format("\n--- Document %d ---", i))
		print("Filepath:", doc.filepath or "nil")
		print("Source:", doc.source or "nil")
		print("Article name:", doc.article_name or "nil")
		print("Has sections:", doc.sections ~= nil)

		if doc.sections then
			print("Sections type:", type(doc.sections))
			print("Section text:", doc.sections.text or "nil")
			print("Section type:", doc.sections.type or "nil")
			print("Has children:", doc.sections.children ~= nil)

			if doc.sections.children then
				print("Number of root children:", #doc.sections.children)

				-- Print first few sections
				for j = 1, math.min(3, #doc.sections.children) do
					local child = doc.sections.children[j]
					print(string.format("  Child %d:", j))
					print("    Type:", child.type or "nil")
					print("    Text:", child.text or "nil")
					print("    Start line:", child.start_line or "nil")
					print("    Has children:", child.children and #child.children or 0)
				end
			end
		end
	end

	-- Test a simple search
	print("\n=== Testing Search ===")
	local results = M.search("", { search_mode = M.modes.SECTION })
	print("Empty search results:", #results)

	if #results > 0 then
		print("First result:")
		print("  Breadcrumb:", results[1].breadcrumb or "nil")
		print("  Filepath:", results[1].filepath or "nil")
		print("  Score:", results[1].score or "nil")
	end
end

function M.test_search(query)
	local results = M.search(query or "", { search_mode = M.modes.SECTION })
	print(string.format("\nSearch for '%s' returned %d results", query or "(empty)", #results))

	for i = 1, math.min(5, #results) do
		local r = results[i]
		print(string.format("%d. %s (score: %.2f)", i, r.breadcrumb or "(no breadcrumb)", r.score or 0))
	end
end

-- =============================================================================
-- Search Statistics & Management
-- =============================================================================

function M.get_stats()
	local docs = SearchDocumentCache:get_all_documents()
	local total_sections = 0
	local total_tasks = 0

	for _, doc in ipairs(docs) do
		if doc.stats then
			total_sections = total_sections + doc.stats.sections
			total_tasks = total_tasks + doc.stats.tasks
		end
	end

	return {
		documents_loaded = #docs,
		total_sections = total_sections,
		total_tasks = total_tasks,
		access_history_count = vim.tbl_count(AccessTracker.data),
		search_history_count = #SearchHistory.entries,
		cache_documents = vim.tbl_count(SearchDocumentCache.documents),
	}
end

function M.refresh_all()
	local stop_timer = Logger.start_timer("search_service.refresh_all")

	-- Clear search cache
	SearchDocumentCache:clear()

	-- Force reload all buffer documents in DocumentManager
	for bufnr, _ in pairs(DocumentManager._instance.buffers) do
		DocumentManager._instance:reparse_buffer(bufnr)
	end

	EventBus.emit("search:cache_refreshed")
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
end

-- Export history for UI
M.SearchHistory = SearchHistory

return M
