-- search.lua – incremental exact‑substring note search with smart sorting & enhanced caching
--   • Space separates tokens (logical AND across the entire file)
--   • Use underscore "_" instead of spaces for phrase search (hello_world ↔ "hello world")
--   • Smart sorting based on: recency (30-day half-life), tags, length, word count, and more
--   • Access tracking for intelligent ranking
--   • Enhanced preview with better highlighting
--   • Header matching with priority based on header level
--   • Start-of-text matching preference
--   • Ignores storage.zortex file

local M = {}
local S = require("zortex.search_managers")

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

function Utils.extract_article_name(title)
	if title:match("^@@") then
		return title:sub(3):gsub("^%s+", ""):gsub("%s+$", "")
	end
	return title
end

function Utils.extract_date_from_filename(fname)
	local basename = fname:match("([^/]+)$")
	local stem = basename:match("^(.+)%.[^.]+$") or basename

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

function Utils.generate_unique_filename()
	local date = os.date("%Y-%m-%d")
	local dir = vim.g.zortex_notes_dir
	local ext = vim.g.zortex_extension

	-- Generate random 3-digit number until we find a unique filename
	math.randomseed(os.time())
	for i = 1, 1000 do
		local num = string.format("%03d", math.random(0, 999))
		local filename = date .. "." .. num .. ext
		local filepath = dir .. filename

		-- Check if file exists
		local f = io.open(filepath, "r")
		if not f then
			return filename
		else
			f:close()
		end
	end

	-- Fallback: use timestamp if we somehow can't find a unique name
	return date .. "." .. os.time() .. ext
end

---Return the (lnum, line, priority) of the first match for `token`.
---Priority order: 1‑article, 2‑tag, 3‑header, 4‑body. `nil` if not found.
---@param lines string[]             Buffer contents
---@param token string               Search token (already raw, *not* lower‑cased)
---@return integer|nil, string|nil, integer|nil
function Utils.prioritized_match_line(lines, token)
	if not token or token == "" then
		return nil
	end
	local tok = token:lower()

	-- 1 ▸ article title (line 1, strip the leading @@)
	if lines[1] then
		local art = Utils.extract_article_name(lines[1]):lower()
		if art:find(tok, 1, true) then
			return 1, lines[1], 1
		end
	end

	-- 2 ▸ tags / aliases (first ~15 lines for cheap scan)
	for i = 2, math.min(#lines, 15) do
		local line = lines[i]
		if line:match("^@+") and line:lower():find(tok, 1, true) then
			return i, line, 2
		end
	end

	-- 3 ▸ markdown headings
	for i, line in ipairs(lines) do
		if line:match("^%s*#+") and line:lower():find(tok, 1, true) then
			return i, line, 3
		end
	end

	-- 4 ▸ any other text
	for i, line in ipairs(lines) do
		if line:lower():find(tok, 1, true) then
			return i, line, 4
		end
	end
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
		header_bonus = 0,
		start_match_bonus = 0,
	}

	-- Recency score with 30-day half-life
	if entry.filename then
		scores.recency = S.AccessTracker.get_score(entry.filename, current_time)
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
		local found_in_header = false
		local found_at_start = false

		-- Check for header matches
		if entry.metadata and entry.metadata.headers then
			for _, header in ipairs(entry.metadata.headers) do
				local header_lower = header.text:lower()
				if header_lower:find(tok_lower, 1, true) then
					found_in_header = true
					-- Header bonus: inversely proportional to header level
					-- Level 1 (#) gets 10x, Level 2 (##) gets 5x, etc.
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

				-- Extra bonus for start-of-article match
				if article_lower:sub(1, #tok_lower) == tok_lower then
					found_at_start = true
					relevance_multiplier = relevance_multiplier * 3
				end
				goto continue
			end
		end

		-- Tag/alias match (high priority)
		if not found_in_header and entry.tags then
			local tags_lower = entry.tags:lower()
			if tags_lower:find(tok_lower, 1, true) then
				relevance_multiplier = relevance_multiplier * 3
				has_any_match = true

				-- Check if any individual tag starts with the token
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

		-- Content match (standard priority)
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
			math.min(#(meta.tags or {}), 5) * 0.4 -- Tag count (capped)
			+ math.log(math.max(1, (meta.word_count or 0) / 100)) * 0.3 -- Word count (log scale)
			+ (entry.line_count and math.log(entry.line_count + 1) * 0.2 or 0) -- Line count
			+ ((meta.has_code or meta.has_links) and 0.5 or 0) -- Special content
			+ (#(meta.headers or {}) > 0 and 1 or 0) -- Has structure
		)
	end

	-- Structure quality score
	if meta then
		scores.structure = (
			((meta.avg_line_length or 0) > 20 and (meta.avg_line_length or 0) < 80 and 1 or 0)
			+ (meta.has_lists and 0.5 or 0)
			+ ((meta.complexity_score or 0) > 2 and 0.5 or 0)
			+ (#(meta.headers or {}) > 3 and 1 or 0) -- Well-structured with headers
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
			if not prompt or prompt == "" then
				return {}
			end

			local tokens = Utils.parse_tokens(prompt)
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

--------------------------------------------------
-- Note Creation
--------------------------------------------------
local function create_new_note(prompt_bufnr)
	local actions = require("telescope.actions")
	actions.close(prompt_bufnr)

	local name = Utils.generate_unique_filename()
	local path = vim.g.zortex_notes_dir .. name

	vim.cmd("edit " .. path)
	vim.defer_fn(function()
		vim.api.nvim_buf_set_lines(0, 0, 0, false, { "@@" })
		vim.api.nvim_win_set_cursor(0, { 1, 2 })
		vim.cmd("startinsert")
	end, 100)
end

--------------------------------------------------
-- Entry Opening with Access Tracking
--------------------------------------------------
local function locate_token(bufnr, token)
	if not token or token == "" then
		return nil
	end
	local token_lower = token:lower()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- 1. Article title (first line – strip "@@")
	if #lines > 0 then
		local article_name = Utils.extract_article_name(lines[1])
		local s = article_name:lower():find(token_lower, 1, true)
		if s then
			return 1, s
		end
	end

	-- 2. Tags or aliases (lines that start with @ / @@)
	for i, line in ipairs(lines) do
		if line:match("^@+") then
			local s = line:lower():find(token_lower, 1, true)
			if s then
				return i, s
			end
		end
	end

	-- 3. Markdown headers (#, ##, ### …)
	for i, line in ipairs(lines) do
		if line:match("^%s*#+") then
			local s = line:lower():find(token_lower, 1, true)
			if s then
				return i, s
			end
		end
	end

	-- 4. Fallback: first occurrence anywhere in the note
	for i, line in ipairs(lines) do
		local s = line:lower():find(token_lower, 1, true)
		if s then
			return i, s
		end
	end
end

local function open_location(entry, cmd, tokens)
	cmd = cmd or "edit"
	if not (entry and entry.filename) then
		return
	end

	-- Track access
	S.AccessTracker.record(entry.filename)

	-- Open in the requested window / split
	if cmd == "split" or cmd == "vsplit" then
		if #vim.api.nvim_list_wins() == 1 then -- ensure we actually split when only one window
			vim.cmd(cmd)
		end
		vim.cmd(string.format("edit %s", entry.filename))
	else
		vim.cmd(string.format("%s %s", cmd, entry.filename))
	end

	-- Default cursor location (fallback)
	local fallback_lnum = entry.lnum or 1
	vim.fn.cursor(fallback_lnum, 1)

	-- 🔍 Single‑token smart jump using the priority order
	if tokens and #tokens == 1 then
		local l, c = locate_token(0, tokens[1])
		if l then
			vim.fn.cursor(l, c)
		end
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
	S.IndexManager.update_sync()

	-- Track current tokens for single-token navigation
	local current_tokens = {}

	-- Entry gathering function
	local function gather(prompt)
		prompt = prompt or ""
		local tokens = Utils.parse_tokens(prompt)
		current_tokens = tokens -- Used later by `open_location`

		local results = {}
		local empty = #tokens == 0

		for path, data in pairs(S.IndexManager.cache) do
			local title = data.lines[1] or ""
			local article_name = Utils.extract_article_name(title)
			local date_str = Utils.extract_date_from_filename(path) or Utils.format_timestamp(data.mtime)
			local tags_line = Utils.extract_aliases_and_tags(data.lines)

			------------------------------------------------------------------------
			-- 2.1 ▸ Resolve the *best* line for each token ------------------------
			local seen_tok, first_idx, first_line, first_prio = {}, nil, nil, nil

			for _, tok in ipairs(tokens) do
				local lnum, line, prio = Utils.prioritized_match_line(data.lines, tok)
				if lnum then
					seen_tok[tok] = { lnum, line, prio }
					if not first_prio or prio < first_prio then -- smaller = higher priority
						first_idx, first_line, first_prio = lnum, line, prio
					end
				end
			end

			-- 2.2 ▸ Verify that *all* tokens matched (logical AND semantics) -------
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
				--------------------------------------------------------------------
				-- 2.3 ▸ Build pretty display line ---------------------------------
				local recency_indicator = ""
				if S.AccessTracker.data[path] and #S.AccessTracker.data[path].times > 0 then
					local last_access = S.AccessTracker.data[path].times[#S.AccessTracker.data[path].times]
					local age_days = (os.time() - last_access) / 86400
					if age_days < 1 then
						recency_indicator = "● " -- today
					elseif age_days < 3 then
						recency_indicator = "◐ " -- last 3 days
					elseif age_days < 7 then
						recency_indicator = "○ " -- this week
					end
				end

				-- extra previews (excluding the main one)
				local extras = {}
				for _, v in pairs(seen_tok) do
					local line = v[2]
					if line ~= first_line then
						extras[#extras + 1] = (line:gsub("^%s+", ""))
					end
				end
				table.sort(extras) -- stable ordering

				local parts = {
					date_str,
					recency_indicator .. article_name .. (tags_line ~= "" and (" " .. tags_line) or ""),
				}

				if first_line and (#extras > 0 or first_line ~= title) then
					local preview = first_line
					if #extras > 0 then
						preview = preview .. " ∥ " .. table.concat(extras, " ∥ ")
					end
					parts[#parts + 1] = preview:gsub("^%s+", "")
				end

				local display = table.concat(parts, " | ")
				local ordinal = table.concat({ article_name, date_str, tags_line, first_line or "" }, " ")

				results[#results + 1] = {
					value = path .. ":" .. (first_idx or 1),
					ordinal = ordinal,
					display = display,
					filename = path,
					lnum = first_idx or 1,
					article_name = article_name,
					tags = tags_line,
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
					open_location(sel, nil, current_tokens)
				end)

				-- Create new note
				map({ "i", "n" }, "<C-o>", function()
					create_new_note(bufnr)
				end)

				-- Clear prompt (C-u in insert mode)
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
