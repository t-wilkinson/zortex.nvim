-- modules/search.lua - Enhanced hierarchical search with unique breadcrumbs and improved matching
local M = {}

local constants = require("zortex.constants")
local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local search_managers = require("zortex.modules.search_managers")
local projects = require("zortex.modules.projects")
local datetime = require("zortex.core.datetime")

local BREADCRUMB_SEP = " ∙ "

-- =============================================================================
-- Search History Management
-- =============================================================================

M.SearchHistory = {}
M.SearchHistory.entries = {}
M.SearchHistory.max_entries = 50

function M.SearchHistory.add(entry)
	table.insert(M.SearchHistory.entries, 1, {
		timestamp = os.time(),
		tokens = entry.tokens,
		selected_file = entry.selected_file,
		selected_section = entry.selected_section,
		section_path = entry.section_path,
		score_contribution = {},
	})

	-- Limit history size
	while #M.SearchHistory.entries > M.SearchHistory.max_entries do
		table.remove(M.SearchHistory.entries)
	end

	-- Propagate score to parent sections
	M.SearchHistory.propagate_scores(M.SearchHistory.entries[1])
end

function M.SearchHistory.propagate_scores(entry)
	if not entry.section_path or not entry.selected_file then
		return
	end

	-- Base score that diminishes as we go up the hierarchy
	local base_score = 1.0
	local decay_factor = 0.8 -- Higher than before to give more weight to parents

	-- Update scores for each level in the section path
	for i = #entry.section_path, 1, -1 do
		local section = entry.section_path[i]
		local score_key = entry.selected_file .. ":" .. section.lnum

		if not entry.score_contribution[score_key] then
			entry.score_contribution[score_key] = 0
		end

		entry.score_contribution[score_key] = entry.score_contribution[score_key] + base_score
		base_score = base_score * decay_factor
	end
end

-- =============================================================================
-- Project Scoring (from telescope.lua)
-- =============================================================================

local function calculate_task_score(task)
	local score = 0
	-- Priority scoring
	if task.attributes and task.attributes.p then
		local priority_scores = { ["1"] = 100, ["2"] = 50, ["3"] = 25 }
		score = score + (priority_scores[task.attributes.p] or 0)
	end
	-- Due-date scoring
	if task.attributes and task.attributes.due then
		local due_dt = datetime.parse_date(task.attributes.due)
		if due_dt then
			local due_time = os.time(due_dt)
			local now = os.time()
			local days_until = (due_time - now) / 86400
			if days_until < 0 then
				score = score + 200 -- Overdue
			elseif days_until < 1 then
				score = score + 150 -- Due today
			elseif days_until < 3 then
				score = score + 75 -- Due soon
			elseif days_until < 7 then
				score = score + 30 -- Due this week
			end
		end
	end
	-- Completed tasks score lower
	if task.completed then
		score = score - 100
	end
	return score
end

local function calculate_project_score(project)
	local project_score = 0
	local stats = projects.get_project_stats(project)

	-- Analyze tasks
	for _, task in ipairs(project.tasks) do
		local task_score = calculate_task_score(task)
		project_score = project_score + task_score
	end

	-- Average task score
	if stats.total_tasks > 0 then
		project_score = project_score / stats.total_tasks
	end

	-- Penalty for mostly completed projects
	if stats.completion_rate > 0.8 then
		project_score = project_score * 0.5
	end

	return project_score
end

-- =============================================================================
-- Utility Functions
-- =============================================================================

local function is_projects_file(filepath)
	if not filepath then
		return false
	end

	-- Check by filename
	local filename = vim.fn.fnamemodify(filepath, ":t")
	if filename == "projects.zortex" then
		return true
	end

	-- Check by article name
	local lines = fs.read_lines(filepath)
	if lines and #lines > 0 then
		local article_name = parser.extract_article_name(lines[1])
		if article_name and (article_name:lower() == "projects" or article_name:lower() == "p") then
			return true
		end
	end

	return false
end

-- =============================================================================
-- Search Token Parsing
-- =============================================================================

local function parse_tokens(prompt)
	local tokens = {}
	for token in (prompt or ""):gmatch("%S+") do
		-- Convert underscores to spaces
		tokens[#tokens + 1] = token:gsub("_", " ")
	end
	return tokens
end

-- =============================================================================
-- Section Detection Helpers
-- =============================================================================

local function is_section_header(line)
	local section_type = parser.detect_section_type(line)
	return section_type == constants.SECTION_TYPE.ARTICLE
		or section_type == constants.SECTION_TYPE.HEADING
		or section_type == constants.SECTION_TYPE.BOLD_HEADING
		or section_type == constants.SECTION_TYPE.LABEL
end

-- Check if a section should be included based on token count
local function should_include_section(section_type, heading_level, token_count)
	if token_count == 1 then
		-- Only articles or level 1 headings
		return section_type == constants.SECTION_TYPE.ARTICLE
			or (section_type == constants.SECTION_TYPE.HEADING and heading_level and heading_level <= 1)
	elseif token_count == 2 then
		-- Articles and level 1-2 headings
		return section_type == constants.SECTION_TYPE.ARTICLE
			or (section_type == constants.SECTION_TYPE.HEADING and heading_level and heading_level <= 3)
	else
		-- All section types
		return true
	end
end

-- =============================================================================
-- Breadcrumb Generation
-- =============================================================================

local function format_breadcrumb(section_path)
	if not section_path or #section_path == 0 then
		return ""
	end

	local parts = {}
	for _, section in ipairs(section_path) do
		table.insert(parts, section.display or section.text)
	end

	return table.concat(parts, BREADCRUMB_SEP)
end

-- Format breadcrumb with highlights
local function format_breadcrumb_with_highlights(section_path)
	if not section_path or #section_path == 0 then
		return {}
	end

	local highlights = {}
	local text = ""

	for i, section in ipairs(section_path) do
		if i > 1 then
			-- Add separator
			table.insert(highlights, { BREADCRUMB_SEP, "Comment" })
			text = text .. BREADCRUMB_SEP
		end

		local section_text = section.display or section.text
		local hl_group = "Normal"

		-- Determine highlight group based on section type
		if section.type == constants.SECTION_TYPE.ARTICLE then
			hl_group = "ZortexArticle"
		elseif section.type == constants.SECTION_TYPE.HEADING then
			hl_group = "ZortexHeading" .. math.min(section.level or 1, 3)
		elseif section.type == constants.SECTION_TYPE.BOLD_HEADING then
			hl_group = "ZortexBoldHeading"
		elseif section.type == constants.SECTION_TYPE.LABEL then
			hl_group = "ZortexLabel"
		end

		table.insert(highlights, { section_text, hl_group })
		text = text .. section_text
	end

	return highlights, text
end

-- =============================================================================
-- Enhanced Hierarchical Search
-- =============================================================================

-- Check if token matches at start of section text
local function token_matches_section_start(section, token)
	if not section.text then
		return false
	end

	local section_lower = section.text:lower()
	local token_lower = token:lower()

	-- Check if token appears at the start of the section text
	return section_lower:sub(1, #token_lower) == token_lower
end

-- Find all occurrences of a token in a given range (only section headers)
local function find_all_token_matches(lines, token, start_idx, end_idx, num_tokens)
	local matches = {}

	for i = math.max(1, start_idx), math.min(#lines, end_idx) do
		local line = lines[i]
		local section_type = parser.detect_section_type(line)

		if section_type ~= constants.SECTION_TYPE.TEXT and section_type ~= constants.SECTION_TYPE.TAG then
			-- Parse section info
			local section_info = {
				lnum = i,
				line = line,
				section_type = section_type,
			}

			-- Extract section details
			if section_type == constants.SECTION_TYPE.ARTICLE then
				section_info.text = parser.extract_article_name(line)
			elseif section_type == constants.SECTION_TYPE.HEADING then
				local heading = parser.parse_heading(line)
				if heading then
					section_info.text = heading.text
					section_info.level = heading.level
				end
			elseif section_type == constants.SECTION_TYPE.BOLD_HEADING then
				local bold = parser.parse_bold_heading(line)
				if bold then
					section_info.text = bold.text
				end
			elseif section_type == constants.SECTION_TYPE.LABEL then
				local label = parser.parse_label(line)
				if label then
					section_info.text = label.text
				end
			end

			-- Check if this section should be included based on token count
			if should_include_section(section_type, section_info.level, num_tokens) then
				-- Check if token matches at start of section text
				if token_matches_section_start(section_info, token) then
					table.insert(matches, section_info)
				end
			end
		end
	end

	return matches
end

-- Find all possible hierarchical matches
local function find_all_hierarchical_matches(lines, tokens)
	if #tokens == 0 then
		return {}
	end

	local all_results = {}
	local seen_breadcrumbs = {} -- Track unique breadcrumbs

	-- For single token, only search article names
	if #tokens == 1 then
		local matches = find_all_token_matches(lines, tokens[1], 1, #lines, #tokens)
		for _, match in ipairs(matches) do
			local section_path = parser.build_section_path(lines, match.lnum)
			local breadcrumb = format_breadcrumb(section_path)

			-- Only add if we haven't seen this breadcrumb
			if not seen_breadcrumbs[breadcrumb] then
				seen_breadcrumbs[breadcrumb] = true
				table.insert(all_results, {
					lnum = match.lnum,
					line = match.line,
					path = { match },
				})
			end
		end
		return all_results
	end

	-- For multiple tokens, find all possible hierarchical paths
	-- First, find all matches for the first token
	local first_matches = find_all_token_matches(lines, tokens[1], 1, #lines, #tokens)

	for _, first_match in ipairs(first_matches) do
		-- Only consider matches that are section headers
		if is_section_header(first_match.line) then
			local paths = {}

			-- Determine search bounds
			local search_start = first_match.lnum
			local heading_level = first_match.level
			local search_end = parser.find_section_end(lines, search_start, first_match.section_type, heading_level)

			-- Recursively find matches for remaining tokens
			local function find_paths(current_start, current_end, token_idx, current_path)
				if token_idx > #tokens then
					-- Found a complete path
					table.insert(paths, vim.deepcopy(current_path))
					return
				end

				local token_matches =
					find_all_token_matches(lines, tokens[token_idx], current_start, current_end, #tokens)

				for _, match in ipairs(token_matches) do
					-- Add this match to the path
					table.insert(current_path, match)

					if token_idx == #tokens then
						-- This is the last token, add the complete path
						table.insert(paths, vim.deepcopy(current_path))
					else
						-- Continue searching for next tokens
						local next_start = match.lnum
						local next_end = current_end

						if is_section_header(match.line) then
							local heading_level = match.level
							next_end = parser.find_section_end(lines, next_start, match.section_type, heading_level)
						end

						find_paths(next_start, next_end, token_idx + 1, current_path)
					end

					-- Remove this match from the path (backtrack)
					table.remove(current_path)
				end
			end

			find_paths(search_start, search_end, 2, { first_match })

			-- Add all found paths to results, but only unique breadcrumbs
			for _, path in ipairs(paths) do
				if #path > 0 then
					local last_match = path[#path]
					local section_path = parser.build_section_path(lines, last_match.lnum)
					local breadcrumb = format_breadcrumb(section_path)

					if not seen_breadcrumbs[breadcrumb] then
						seen_breadcrumbs[breadcrumb] = true
						table.insert(all_results, {
							lnum = last_match.lnum,
							line = last_match.line,
							path = path,
						})
					end
				end
			end
		end
	end

	return all_results
end

-- =============================================================================
-- Entry Scoring
-- =============================================================================

local function calculate_entry_score(entry, tokens, current_time)
	if type(entry) ~= "table" then
		return 0
	end

	local scores = {
		recency = 0,
		section_type = 0,
		match_quality = 0,
		historical = 0,
		depth_penalty = 0,
		project_score = 0,
	}

	-- Check if this is a projects file
	local is_projects = entry.filename and is_projects_file(entry.filename)

	-- Recency score with 30-day half-life
	if entry.filename then
		scores.recency = search_managers.AccessTracker.get_score(entry.filename, current_time)
	end

	-- Historical score from search history
	scores.historical = entry.historical_score or 0

	-- Base score for empty search
	if #tokens == 0 then
		return scores.recency * 10 + scores.historical * 5 + 1
	end

	-- Section type score - prioritize higher-tier sections
	if entry.section_path and #entry.section_path > 0 then
		-- Check what types of sections are in the path
		local has_article = false
		local highest_heading_level = 999
		local has_bold_heading = false
		local has_label = false

		for _, section in ipairs(entry.section_path) do
			if section.type == constants.SECTION_TYPE.ARTICLE then
				has_article = true
			elseif section.type == constants.SECTION_TYPE.HEADING then
				highest_heading_level = math.min(highest_heading_level, section.level or 1)
			elseif section.type == constants.SECTION_TYPE.BOLD_HEADING then
				has_bold_heading = true
			elseif section.type == constants.SECTION_TYPE.LABEL then
				has_label = true
			end
		end

		-- Assign scores based on section types
		if has_article then
			scores.section_type = 200
		end
		if highest_heading_level < 999 then
			scores.section_type = scores.section_type + (50 / highest_heading_level)
		end
		if has_bold_heading then
			scores.section_type = scores.section_type + 20
		end
		if has_label then
			scores.section_type = scores.section_type + 10
		end
	else
		-- Plain text match - very low score
		scores.section_type = 1
	end

	-- Match quality score - check if tokens match section headers
	local matched_headers = 0
	if entry.section_path then
		for _, token in ipairs(tokens) do
			for _, section in ipairs(entry.section_path) do
				if token_matches_section_start(section, token) then
					matched_headers = matched_headers + 1
					break
				end
			end
		end
	end
	scores.match_quality = matched_headers * 50

	-- Depth penalty - prefer shallower matches
	scores.depth_penalty = -((#(entry.section_path or {}) - 1) * 5)

	-- Project-specific scoring
	if is_projects and entry.project_data then
		scores.project_score = entry.project_data.score or 0
	end

	-- Calculate weighted total
	local weights = {
		recency = 3.0,
		section_type = 5.0,
		match_quality = 4.0,
		historical = 2.0,
		depth_penalty = 1.0,
		project_score = is_projects and 10.0 or 0, -- High weight for project scores
	}

	local total = 0
	for key, weight in pairs(weights) do
		total = total + (scores[key] * weight)
	end

	return math.max(total, 0.001)
end

-- =============================================================================
-- Note Creation
-- =============================================================================

local function generate_unique_filename()
	local date = os.date("%Y-%m-%d")
	local ext = vim.g.zortex_extension or ".zortex"

	-- Generate random 3-digit number
	math.randomseed(os.time())
	for i = 1, 1000 do
		local num = string.format("%03d", math.random(0, 999))
		local filename = date .. "." .. num .. ext
		local filepath = fs.get_file_path(filename)

		if filepath and not fs.file_exists(filepath) then
			return filename
		end
	end

	-- Fallback
	return date .. "." .. os.time() .. ext
end

local function create_new_note(prompt_bufnr)
	local actions = require("telescope.actions")
	actions.close(prompt_bufnr)

	local filename = generate_unique_filename()
	local path = fs.get_file_path(filename)

	vim.cmd("edit " .. path)
	vim.defer_fn(function()
		vim.api.nvim_buf_set_lines(0, 0, 0, false, { "@@" })
		vim.api.nvim_win_set_cursor(0, { 1, 2 })
		vim.cmd("startinsert")
	end, 100)
end

-- =============================================================================
-- Entry Opening
-- =============================================================================

local function open_location(entry, cmd, tokens)
	cmd = cmd or "edit"
	if not (entry and entry.filename) then
		return
	end

	-- Track access
	search_managers.AccessTracker.record(entry.filename)

	-- Open file
	if cmd == "split" or cmd == "vsplit" then
		if #vim.api.nvim_list_wins() == 1 then
			vim.cmd(cmd)
		end
		vim.cmd(string.format("edit %s", entry.filename))
	else
		vim.cmd(string.format("%s %s", cmd, entry.filename))
	end

	-- Jump directly to the matched line
	if entry.lnum then
		vim.fn.cursor(entry.lnum, 1)
		vim.cmd("normal! zz")

		-- If we have a specific column (from token match), jump there too
		if entry.col then
			vim.fn.cursor(entry.lnum, entry.col)
		end
	end
end

-- =============================================================================
-- Entry Creation
-- =============================================================================

local function create_search_entry(path, data, tokens, match_info, search_type)
	-- Build section path if we have a match
	local section_path = {}
	local breadcrumb = ""
	local breadcrumb_highlights = {}

	if match_info.lnum and search_type == "section" then
		section_path = parser.build_section_path(data.lines, match_info.lnum)
		breadcrumb = format_breadcrumb(section_path)
		breadcrumb_highlights = format_breadcrumb_with_highlights(section_path)
	end

	-- Get historical score contribution
	local historical_score = 0
	for _, hist_entry in ipairs(M.SearchHistory.entries) do
		if hist_entry.selected_file == path and hist_entry.score_contribution then
			-- Check scores for this specific line and its parents
			local score_key = path .. ":" .. match_info.lnum
			historical_score = historical_score + (hist_entry.score_contribution[score_key] or 0)

			-- Also check parent sections
			for _, section in ipairs(section_path) do
				local parent_key = path .. ":" .. section.lnum
				historical_score = historical_score + (hist_entry.score_contribution[parent_key] or 0) * 0.5
			end

			-- Apply time decay
			historical_score = historical_score * math.exp(-0.1 * (os.time() - hist_entry.timestamp) / 86400)
		end
	end

	-- Extract project data if this is a projects file
	local project_data = nil
	if is_projects_file(path) and match_info.lnum then
		-- Load projects data
		projects.load()
		local project = projects.get_project_at_line(match_info.lnum)
		if project then
			project_data = {
				project = project,
				score = calculate_project_score(project),
			}
		end
	end

	-- Display is just the breadcrumb for section search
	local display = breadcrumb
	if search_type ~= "section" or breadcrumb == "" then
		-- Fallback for article search or no breadcrumb
		local article_name = parser.extract_article_name(data.lines[1] or "")
		display = article_name or "Untitled"
		local tags_line = table.concat(parser.extract_tags_from_lines(data.lines), " ")
		if tags_line ~= "" then
			display = display .. " " .. tags_line
		end
	end

	return {
		value = path .. ":" .. (match_info.lnum or 1),
		ordinal = breadcrumb .. " " .. (match_info.line or ""),
		display = display,
		display_highlights = breadcrumb_highlights,
		filename = path,
		lnum = match_info.lnum or 1,
		col = match_info.col,
		matched_line = match_info.line,
		section_path = section_path,
		breadcrumb = breadcrumb,
		mtime = data.mtime,
		metadata = data.metadata,
		line_count = #data.lines,
		historical_score = historical_score,
		project_data = project_data,
		score_calculated = false,
	}
end

-- =============================================================================
-- Telescope Integration
-- =============================================================================

local function create_smart_sorter()
	local ts_sorters = require("telescope.sorters")
	local ordinal_to_entry = {}

	return ts_sorters.Sorter:new({
		start = function(self, prompt)
			ordinal_to_entry = {}
		end,

		scoring_function = function(self, prompt, line, entry)
			local actual_entry = entry

			if type(line) == "string" and not entry then
				actual_entry = ordinal_to_entry[line]
				if not actual_entry then
					return 999999
				end
			elseif type(entry) == "table" and entry.ordinal then
				ordinal_to_entry[entry.ordinal] = entry
				actual_entry = entry
			else
				return 999999
			end

			if not actual_entry.score_calculated then
				local tokens = parse_tokens(prompt)
				local current_time = os.time()

				actual_entry.total_score = calculate_entry_score(actual_entry, tokens, current_time)
				actual_entry.score_calculated = true
			end

			-- Lower scores rank higher in Telescope
			return 1000 / (actual_entry.total_score + 1)
		end,

		-- Disable highlighting by returning empty highlights
		highlighter = function(_, prompt, display)
			return {}
		end,
	})
end

-- Custom previewer using highlights.lua with full file scrolling
local function create_zortex_previewer()
	local previewers = require("telescope.previewers")
	local highlights = require("zortex.core.highlights")

	return previewers.new_buffer_previewer({
		title = "Zortex Preview",

		define_preview = function(self, entry, status)
			if not entry or not entry.filename then
				return
			end

			-- Read the entire file
			local lines = fs.read_lines(entry.filename)
			if not lines then
				return
			end

			-- Set the entire buffer content
			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)

			-- Apply Zortex highlighting
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(self.state.bufnr) then
					highlights.highlight_buffer(self.state.bufnr)

					-- Highlight the target line if we have one
					if entry.lnum then
						local ns_id = vim.api.nvim_create_namespace("zortex_preview_highlight")
						vim.api.nvim_buf_add_highlight(self.state.bufnr, ns_id, "CursorLine", entry.lnum - 1, 0, -1)

						-- Scroll to the target line with some context
						vim.api.nvim_win_call(status.preview_win, function()
							vim.fn.cursor(entry.lnum, 1)
							vim.cmd("normal! zz")
						end)
					end
				end
			end)
		end,

		get_buffer_by_name = function(_, entry)
			return entry.filename
		end,
	})
end

-- =============================================================================
-- Main Search Function
-- =============================================================================

function M.search(opts)
	opts = opts or {}
	local search_type = opts.search_type or "section" -- Default to section search

	local notes_dir = fs.get_notes_dir()
	if not notes_dir then
		vim.notify("Zortex Search: g:zortex_notes_dir not set", vim.log.levels.ERROR)
		return
	end

	local telescope = require("telescope")
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local conf = require("telescope.config").values
	local previewers = require("telescope.previewers")
	local entry_display = require("telescope.pickers.entry_display")

	-- Update index
	search_managers.IndexManager.update_sync()

	-- Track current tokens
	local current_tokens = {}

	-- Entry gathering function
	local function gather(prompt)
		prompt = prompt or ""
		local tokens = parse_tokens(prompt)
		current_tokens = tokens

		local results = {}

		for path, data in pairs(search_managers.IndexManager.cache) do
			if #tokens == 0 then
				-- Empty search - return one entry per file
				local article_name = parser.extract_article_name(data.lines[1] or "")
				if article_name then
					local entry = create_search_entry(path, data, tokens, { lnum = 1 }, search_type)
					table.insert(results, entry)
				end
			else
				-- Find all hierarchical matches based on token count
				local matches = find_all_hierarchical_matches(data.lines, tokens)

				-- Create an entry for each unique match
				for _, match in ipairs(matches) do
					-- Find where the last token appears in the line
					local col = nil
					if #tokens > 0 then
						local last_token = tokens[#tokens]:lower()
						local match_text = match.text or ""
						if match_text:lower():sub(1, #last_token) == last_token then
							col = 1
						end
					end

					local entry = create_search_entry(path, data, tokens, {
						lnum = match.lnum,
						line = match.line,
						col = col,
					}, search_type)
					table.insert(results, entry)
				end
			end
		end

		return results
	end

	-- Create finder with custom entry maker
	local finder = finders.new_dynamic({
		fn = gather,
		entry_maker = function(e)
			if e.display_highlights and #e.display_highlights > 0 then
				-- Use entry_display to handle highlights
				local displayer = entry_display.create({
					separator = "",
					items = e.display_highlights,
				})

				e.display = function(entry)
					return displayer(e.display_highlights)
				end
			end
			return e
		end,
	})

	local sorter = create_smart_sorter()

	-- Create previewer
	local previewer = create_zortex_previewer()

	-- Determine prompt title
	local prompt_title = search_type == "section" and "Zortex Section Search" or "Zortex Article Search"

	-- Create picker
	pickers
		.new(opts, {
			prompt_title = prompt_title,
			default_text = "",
			layout_strategy = "flex",
			layout_config = {
				flex = { flip_columns = 120 },
				horizontal = { preview_width = 0.60 },
				vertical = { preview_height = 0.40 },
			},
			finder = finder,
			sorter = sorter,
			previewer = previewer,
			attach_mappings = function(bufnr, map)
				-- Default action
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(bufnr)

					-- Save to history if section search
					if search_type == "section" and sel and sel.filename and sel.section_path then
						M.SearchHistory.add({
							tokens = current_tokens,
							selected_file = sel.filename,
							selected_section = sel.lnum,
							section_path = sel.section_path,
						})
					end

					open_location(sel, nil, current_tokens)
				end)

				-- Create new note
				map({ "i", "n" }, "<C-o>", function()
					create_new_note(bufnr)
				end)

				-- Clear prompt
				map("i", "<C-u>", function()
					vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "" })
					vim.api.nvim_win_set_cursor(0, { 1, 0 })
				end)

				-- Open in split
				map({ "i", "n" }, "<C-x>", function()
					local sel = action_state.get_selected_entry()
					actions.close(bufnr)

					-- Save to history if section search
					if search_type == "section" and sel and sel.filename and sel.section_path then
						M.SearchHistory.add({
							tokens = current_tokens,
							selected_file = sel.filename,
							selected_section = sel.lnum,
							section_path = sel.section_path,
						})
					end

					open_location(sel, "split", current_tokens)
				end)

				-- Open in vsplit
				map({ "i", "n" }, "<C-v>", function()
					local sel = action_state.get_selected_entry()
					actions.close(bufnr)

					-- Save to history if section search
					if search_type == "section" and sel and sel.filename and sel.section_path then
						M.SearchHistory.add({
							tokens = current_tokens,
							selected_file = sel.filename,
							selected_section = sel.lnum,
							section_path = sel.section_path,
						})
					end

					open_location(sel, "vsplit", current_tokens)
				end)

				-- Scroll preview
				map({ "i", "n" }, "<C-f>", function()
					actions.preview_scrolling_down(bufnr)
				end)

				map({ "i", "n" }, "<C-b>", function()
					actions.preview_scrolling_up(bufnr)
				end)

				return true
			end,
		})
		:find()
end

-- =============================================================================
-- Search Type Variants
-- =============================================================================

function M.search_sections(opts)
	opts = opts or {}
	opts.search_type = "section"
	M.search(opts)
end

function M.search_articles(opts)
	opts = opts or {}
	opts.search_type = "article"
	M.search(opts)
end

return M
