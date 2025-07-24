-- services/search.lua
-- Search service built on DocumentManager
local M = {}

local DocumentManager = require("zortex.core.document_manager")
local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local fs = require("zortex.utils.filesystem")
local constants = require("zortex.constants")

-- =============================================================================
-- Search Configuration
-- =============================================================================

local config = {
	index_extensions = { ".zortex", ".md", ".txt" },
	max_results = 500,
	min_score = 0.1,
	access_decay_rate = 0.1, -- per day
}

-- =============================================================================
-- Access Tracking
-- =============================================================================

local AccessTracker = {
	data = {}, -- filepath -> { last_access, access_count }
}

function AccessTracker.record(filepath)
	if not AccessTracker.data[filepath] then
		AccessTracker.data[filepath] = {
			last_access = 0,
			access_count = 0,
		}
	end

	AccessTracker.data[filepath].last_access = os.time()
	AccessTracker.data[filepath].access_count = AccessTracker.data[filepath].access_count + 1
end

function AccessTracker.get_score(filepath, current_time)
	local data = AccessTracker.data[filepath]
	if not data then
		return 0
	end

	local days_since = (current_time - data.last_access) / 86400
	local recency_score = math.exp(-config.access_decay_rate * days_since)
	local frequency_score = math.log(data.access_count + 1)

	return recency_score * frequency_score
end

-- =============================================================================
-- Search Functions
-- =============================================================================

-- Parse search tokens
local function parse_tokens(prompt)
	local tokens = {}
	for token in (prompt or ""):gmatch("%S+") do
		-- Convert underscores to spaces
		tokens[#tokens + 1] = token:gsub("_", " "):lower()
	end
	return tokens
end

-- Check if token matches section text
local function token_matches_section(section, token)
	if not section.text then
		return false
	end

	local section_lower = section.text:lower()
	return section_lower:find(token, 1, true) ~= nil
end

-- Check if token matches at start of section
local function token_matches_section_start(section, token)
	if not section.text then
		return false
	end

	local section_lower = section.text:lower()
	return section_lower:sub(1, #token) == token
end

-- Score a section match
local function score_section_match(section, tokens, is_start_match)
	local score = 0

	-- Base score by section type
	if section.type == constants.SECTION_TYPE.ARTICLE then
		score = 200
	elseif section.type == constants.SECTION_TYPE.HEADING then
		score = 100 / (section.level or 1)
	elseif section.type == constants.SECTION_TYPE.BOLD_HEADING then
		score = 50
	elseif section.type == constants.SECTION_TYPE.LABEL then
		score = 25
	else
		score = 10
	end

	-- Bonus for start matches
	if is_start_match then
		score = score * 1.5
	end

	-- Bonus for matching multiple tokens
	local matched_tokens = 0
	for _, token in ipairs(tokens) do
		if token_matches_section(section, token) then
			matched_tokens = matched_tokens + 1
		end
	end
	score = score * (1 + matched_tokens * 0.5)

	-- Penalty for depth
	local depth = #section:get_path()
	score = score / (1 + depth * 0.1)

	return score
end

-- Search in a single document
local function search_document(doc, tokens, search_type)
	local results = {}

	if not doc.sections then
		return results
	end

	-- For empty search, return document root
	if #tokens == 0 then
		local article_name = doc.article_name or "Untitled"
		table.insert(results, {
			section = doc.sections,
			score = AccessTracker.get_score(doc.filepath, os.time()),
			matched_tokens = {},
			breadcrumb = article_name,
		})
		return results
	end

	-- Search all sections
	local function search_section(section)
		-- Check token count restrictions
		if search_type == "section" then
			if #tokens == 1 and section.type ~= constants.SECTION_TYPE.ARTICLE then
				return
			elseif #tokens == 2 then
				if
					section.type ~= constants.SECTION_TYPE.ARTICLE
					and not (section.type == constants.SECTION_TYPE.HEADING and section.level <= 3)
				then
					return
				end
			end
		end

		-- Check if all tokens match
		local all_match = true
		local matched_tokens = {}
		local is_start_match = false

		for _, token in ipairs(tokens) do
			if token_matches_section(section, token) then
				table.insert(matched_tokens, token)
				if token_matches_section_start(section, token) then
					is_start_match = true
				end
			else
				all_match = false
				break
			end
		end

		if all_match and #matched_tokens > 0 then
			local score = score_section_match(section, matched_tokens, is_start_match)

			table.insert(results, {
				section = section,
				score = score,
				matched_tokens = matched_tokens,
				breadcrumb = section:get_breadcrumb(),
			})
		end

		-- Search children
		for _, child in ipairs(section.children) do
			search_section(child)
		end
	end

	-- Start search from root children (skip root itself)
	for _, child in ipairs(doc.sections.children) do
		search_section(child)
	end

	return results
end

-- =============================================================================
-- Main Search Function
-- =============================================================================

function M.search(query, opts)
	opts = opts or {}
	local search_type = opts.search_type or "section"
	local max_results = opts.max_results or config.max_results

	local stop_timer = Logger.start_timer("search_service.search")

	-- Parse tokens
	local tokens = parse_tokens(query)

	Logger.debug("search_service", "Searching", {
		query = query,
		tokens = tokens,
		search_type = search_type,
	})

	-- Get all files to search
	local files_to_search = {}
	local notes_dir = fs.get_notes_dir()

	if notes_dir then
		-- Scan directory for files
		local function scan_dir(dir)
			local handle = vim.loop.fs_scandir(dir)
			if handle then
				while true do
					local name, type = vim.loop.fs_scandir_next(handle)
					if not name then
						break
					end

					local path = dir .. "/" .. name

					if type == "directory" and not name:match("^%.") then
						scan_dir(path)
					elseif type == "file" then
						for _, ext in ipairs(config.index_extensions) do
							if name:match(ext .. "$") then
								table.insert(files_to_search, path)
								break
							end
						end
					end
				end
			end
		end

		scan_dir(notes_dir)
	end

	-- Search in all documents
	local all_results = {}

	-- Search in loaded buffers first
	for bufnr, doc in pairs(DocumentManager._instance.buffers) do
		if doc.filepath then
			local results = search_document(doc, tokens, search_type)
			for _, result in ipairs(results) do
				result.filepath = doc.filepath
				result.bufnr = bufnr
				result.source = "buffer"
				table.insert(all_results, result)
			end

			-- Remove from files to search
			for i, path in ipairs(files_to_search) do
				if path == doc.filepath then
					table.remove(files_to_search, i)
					break
				end
			end
		end
	end

	-- Search in unloaded files
	for _, filepath in ipairs(files_to_search) do
		local doc = DocumentManager.get_file(filepath)
		if doc then
			local results = search_document(doc, tokens, search_type)
			for _, result in ipairs(results) do
				result.filepath = filepath
				result.source = "file"
				table.insert(all_results, result)
			end
		end
	end

	-- Add access tracking scores
	local current_time = os.time()
	for _, result in ipairs(all_results) do
		local access_score = AccessTracker.get_score(result.filepath, current_time)
		result.score = result.score + access_score * 10
	end

	-- Sort by score
	table.sort(all_results, function(a, b)
		return a.score > b.score
	end)

	-- Limit results
	if #all_results > max_results then
		for i = max_results + 1, #all_results do
			all_results[i] = nil
		end
	end

	stop_timer({
		result_count = #all_results,
		file_count = #files_to_search,
	})

	-- Emit search completed event
	EventBus.emit("search:completed", {
		query = query,
		tokens = tokens,
		result_count = #all_results,
		search_type = search_type,
	})

	return all_results
end

-- =============================================================================
-- Telescope Integration
-- =============================================================================

function M.create_telescope_finder(opts)
	local finders = require("telescope.finders")
	local entry_display = require("telescope.pickers.entry_display")

	return finders.new_dynamic({
		fn = function(prompt)
			local results = M.search(prompt, opts)

			-- Convert to telescope entries
			local entries = {}
			for _, result in ipairs(results) do
				local entry = {
					value = result,
					ordinal = result.breadcrumb .. " " .. result.filepath,
					display = result.breadcrumb,
					filename = result.filepath,
					lnum = result.section.start_line,
					col = 1,
				}
				table.insert(entries, entry)
			end

			return entries
		end,
	})
end

-- =============================================================================
-- Quick Access
-- =============================================================================

-- Open file at section
function M.open_result(result, cmd)
	cmd = cmd or "edit"

	if not result or not result.filepath then
		return
	end

	-- Track access
	AccessTracker.record(result.filepath)

	-- Open file
	if result.bufnr and vim.api.nvim_buf_is_valid(result.bufnr) then
		vim.api.nvim_set_current_buf(result.bufnr)
	else
		vim.cmd(string.format("%s %s", cmd, result.filepath))
	end

	-- Jump to section
	if result.section and result.section.start_line then
		vim.api.nvim_win_set_cursor(0, { result.section.start_line, 0 })
		vim.cmd("normal! zz")
	end

	-- Emit event
	EventBus.emit("search:result_opened", {
		filepath = result.filepath,
		section = result.section,
		query_tokens = result.matched_tokens,
	})
end

-- =============================================================================
-- Cache Management
-- =============================================================================

-- Force refresh all documents
function M.refresh_all()
	local stop_timer = Logger.start_timer("search_service.refresh_all")

	-- Clear file cache
	DocumentManager._instance.files = {}
	DocumentManager._instance.lru = DocumentManager._instance.lru:new({ max_items = 20 })

	-- Reload all buffers
	for bufnr, _ in pairs(DocumentManager._instance.buffers) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			DocumentManager:reparse_buffer(bufnr)
		end
	end

	stop_timer()

	EventBus.emit("search:cache_refreshed", {
		timestamp = os.time(),
	})
end

-- Get search statistics
function M.get_stats()
	local buffer_count = vim.tbl_count(DocumentManager._instance.buffers)
	local file_count = vim.tbl_count(DocumentManager._instance.files)

	local total_sections = 0
	local total_tasks = 0

	for _, doc in pairs(DocumentManager._instance.buffers) do
		if doc.stats then
			total_sections = total_sections + doc.stats.sections
			total_tasks = total_tasks + doc.stats.tasks
		end
	end

	return {
		buffer_count = buffer_count,
		file_count = file_count,
		total_documents = buffer_count + file_count,
		total_sections = total_sections,
		total_tasks = total_tasks,
		access_history_count = vim.tbl_count(AccessTracker.data),
	}
end

return M

