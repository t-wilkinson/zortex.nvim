-- features/search.lua - Hierarchical search integrated with unified parser
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local search_managers = require("zortex.features.search_managers")

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
-- Hierarchical Search
-- =============================================================================

local function find_token_in_range(lines, token, start_idx, end_idx)
	local tok_lower = token:lower()
	local matches = {}

	for i = math.max(1, start_idx), math.min(#lines, end_idx) do
		if lines[i]:lower():find(tok_lower, 1, true) then
			table.insert(matches, {
				lnum = i,
				line = lines[i],
				section_type = parser.detect_section_type(lines[i]),
			})
		end
	end

	-- Sort matches by section type priority (lower values = higher priority)
	table.sort(matches, function(a, b)
		return a.section_type < b.section_type
	end)

	return matches
end

local function hierarchical_search(lines, tokens)
	if #tokens == 0 then
		return true, nil, nil
	end

	-- Find first token anywhere in the file
	local first_matches = find_token_in_range(lines, tokens[1], 1, #lines)
	if #first_matches == 0 then
		return false, nil, nil
	end

	-- For single token, return the best match
	if #tokens == 1 then
		local best = first_matches[1]
		return true, best.lnum, best.line
	end

	-- For multiple tokens, search hierarchically
	for _, first_match in ipairs(first_matches) do
		local current_start = first_match.lnum
		local current_end = parser.find_section_end(lines, current_start, first_match.section_type)
		local all_found = true
		local match_chain = { first_match }

		-- Search for remaining tokens within progressively narrower contexts
		for i = 2, #tokens do
			local token_matches = find_token_in_range(lines, tokens[i], current_start, current_end)

			if #token_matches == 0 then
				all_found = false
				break
			end

			-- Use the best match for this token
			local best_match = token_matches[1]
			table.insert(match_chain, best_match)

			-- Narrow the search range for the next token
			current_start = best_match.lnum
			current_end = parser.find_section_end(lines, current_start, best_match.section_type)
		end

		if all_found then
			-- Return the match info for the last token in the chain
			local final_match = match_chain[#match_chain]
			return true, final_match.lnum, final_match.line
		end
	end

	return false, nil, nil
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
		relevance = 0,
		richness = 0,
		structure = 0,
		header_bonus = 0,
		start_match_bonus = 0,
		hierarchical_bonus = 0,
	}

	-- Recency score with 30-day half-life
	if entry.filename then
		scores.recency = search_managers.AccessTracker.get_score(entry.filename, current_time)
		entry.recency_score = scores.recency
	end

	-- Base score for all entries
	if #tokens == 0 then
		return scores.recency * 10 + 1
	end

	-- Hierarchical matching bonus
	if entry.hierarchical_match then
		scores.hierarchical_bonus = 5.0
	end

	-- Relevance score based on token matches
	local relevance_multiplier = 1
	local has_any_match = false

	for _, token in ipairs(tokens) do
		local tok_lower = token:lower()
		local found_in_header = false
		local found_at_start = false

		-- Check for header matches
		if entry.metadata and entry.metadata.headers then
			for _, header in ipairs(entry.metadata.headers) do
				local header_lower = header.text:lower()
				if header_lower:find(tok_lower, 1, true) then
					found_in_header = true
					-- Header bonus: inversely proportional to header level
					local header_multiplier = 10 / header.level
					relevance_multiplier = relevance_multiplier * header_multiplier

					-- Extra bonus for start-of-header match
					if header_lower:sub(1, #tok_lower) == tok_lower then
						found_at_start = true
						relevance_multiplier = relevance_multiplier * 2
					end

					has_any_match = true
					break
				end
			end
		end

		-- Article match (highest priority)
		if not found_in_header and entry.article_name then
			local article_lower = entry.article_name:lower()
			if article_lower:find(tok_lower, 1, true) then
				relevance_multiplier = relevance_multiplier * 20
				has_any_match = true

				if article_lower:sub(1, #tok_lower) == tok_lower then
					found_at_start = true
					relevance_multiplier = relevance_multiplier * 3
				end
				goto continue
			end
		end

		-- Tag/alias match
		if not found_in_header and entry.tags then
			local tags_lower = entry.tags:lower()
			if tags_lower:find(tok_lower, 1, true) then
				relevance_multiplier = relevance_multiplier * 3
				has_any_match = true

				for tag in entry.tags:gmatch("@%S+") do
					if tag:lower():sub(2, #tok_lower + 1) == tok_lower then
						found_at_start = true
						relevance_multiplier = relevance_multiplier * 2
						break
					end
				end
				goto continue
			end
		end

		-- Content match
		if not found_in_header and entry.matched_line and entry.matched_line:lower():find(tok_lower, 1, true) then
			relevance_multiplier = relevance_multiplier * 1.5
			has_any_match = true
			goto continue
		end

		-- Track bonuses
		if found_in_header then
			scores.header_bonus = scores.header_bonus + 1
		end
		if found_at_start then
			scores.start_match_bonus = scores.start_match_bonus + 1
		end

		::continue::
	end

	-- If no matches found, return very low score
	if not has_any_match and #tokens > 0 then
		return 0.001
	end

	scores.relevance = relevance_multiplier

	-- Content richness score
	local meta = entry.metadata
	if meta then
		scores.richness = (
			math.min(#(meta.tags or {}), 5) * 0.4
			+ math.log(math.max(1, (meta.word_count or 0) / 100)) * 0.3
			+ (entry.line_count and math.log(entry.line_count + 1) * 0.2 or 0)
			+ ((meta.has_code or meta.has_links) and 0.5 or 0)
			+ (#(meta.headers or {}) > 0 and 1 or 0)
		)
	end

	-- Structure quality score
	if meta then
		scores.structure = (
			((meta.avg_line_length or 0) > 20 and (meta.avg_line_length or 0) < 80 and 1 or 0)
			+ (meta.has_lists and 0.5 or 0)
			+ ((meta.complexity_score or 0) > 2 and 0.5 or 0)
			+ (#(meta.headers or {}) > 3 and 1 or 0)
		)
	end

	-- Calculate weighted total
	local weights = {
		recency = 5.0,
		relevance = 5.0,
		richness = 1.5,
		structure = 0.5,
		header_bonus = 3.0,
		start_match_bonus = 2.0,
		hierarchical_bonus = 10.0,
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

local function locate_token(bufnr, token)
	if not token or token == "" then
		return nil
	end
	local token_lower = token:lower()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- Use hierarchical search for single token
	local found, lnum, _ = hierarchical_search(lines, { token })
	if found then
		local line = lines[lnum]
		local col = line:lower():find(token_lower, 1, true)
		return lnum, col
	end

	return nil
end

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

	-- Position cursor
	local fallback_lnum = entry.lnum or 1
	vim.fn.cursor(fallback_lnum, 1)

	-- Single-token smart jump
	if tokens and #tokens == 1 then
		local l, c = locate_token(0, tokens[1])
		if l then
			vim.fn.cursor(l, c)
		end
	end
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
			local score = 1000 / (actual_entry.total_score + 1)
			return score
		end,

		highlighter = function(_, prompt, display)
			if not prompt or prompt == "" then
				return {}
			end

			local tokens = parse_tokens(prompt)
			local highlights = {}
			local disp_lower = display:lower()

			for _, tok in ipairs(tokens) do
				local tok_lower = tok:lower()
				local start = 1

				while true do
					local s, e = disp_lower:find(tok_lower, start, true)
					if not s then
						break
					end

					highlights[#highlights + 1] = { start = s, finish = e }
					start = e + 1
				end
			end

			table.sort(highlights, function(a, b)
				return a.start < b.start
			end)

			return highlights
		end,
	})
end

-- =============================================================================
-- Main Search Function
-- =============================================================================

function M.search(opts)
	opts = opts or {}

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
		local empty = #tokens == 0

		for path, data in pairs(search_managers.IndexManager.cache) do
			local title = data.lines[1] or ""
			local article_name = parser.extract_article_name(title)
			local date_str = search_managers.Utils.extract_date_from_filename(path) or os.date("%Y-%m-%d", data.mtime)
			local tags_line = table.concat(parser.extract_tags_from_lines(data.lines), " ")

			-- Use hierarchical search
			local qualifies, match_lnum, match_line
			if empty then
				qualifies = true
			else
				qualifies, match_lnum, match_line = hierarchical_search(data.lines, tokens)
			end

			if qualifies then
				-- Build display
				local recency_indicator = ""
				if search_managers.AccessTracker.data[path] and #search_managers.AccessTracker.data[path].times > 0 then
					local last_access =
						search_managers.AccessTracker.data[path].times[#search_managers.AccessTracker.data[path].times]
					local age_days = (os.time() - last_access) / 86400
					if age_days < 1 then
						recency_indicator = "● "
					elseif age_days < 3 then
						recency_indicator = "◐ "
					elseif age_days < 7 then
						recency_indicator = "○ "
					end
				end

				local parts = {
					date_str,
					recency_indicator .. (article_name or "Untitled") .. (tags_line ~= "" and (" " .. tags_line) or ""),
				}

				if match_line and match_line ~= title then
					parts[#parts + 1] = parser.trim(match_line)
				end

				local display = table.concat(parts, " | ")
				local ordinal = table.concat({
					article_name or "",
					date_str,
					tags_line,
					match_line or "",
				}, " ")

				results[#results + 1] = {
					value = path .. ":" .. (match_lnum or 1),
					ordinal = ordinal,
					display = display,
					filename = path,
					lnum = match_lnum or 1,
					article_name = article_name,
					tags = tags_line,
					matched_line = match_line,
					mtime = data.mtime,
					metadata = data.metadata,
					line_count = #data.lines,
					hierarchical_match = not empty and match_lnum ~= nil,
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
						"--language=markdown",
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
			prompt_title = "Zortex Hierarchical Search",
			default_text = "",
			finder = finder,
			sorter = sorter,
			previewer = previewer,
			attach_mappings = function(bufnr, map)
				-- Default action
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(bufnr)
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
					open_location(sel, "split", current_tokens)
				end)

				-- Open in vsplit
				map({ "i", "n" }, "<C-v>", function()
					local sel = action_state.get_selected_entry()
					actions.close(bufnr)
					open_location(sel, "vsplit", current_tokens)
				end)

				return true
			end,
		})
		:find()
end

return M
