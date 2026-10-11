-- ui/telescope/search.lua - Structural Search UI & Logic
--
-- Results are sections shown as breadcrumbs of their hierarchy, then matching
-- lines. Search words are matched against a section's PATH, in order:
-- earlier words match ancestors, the last word matches the section itself,
-- and consecutive words may share one section. So "2 4" finds 1 › 2 › 3 › 4,
-- 2 › 4 and 2 › 3 › 4, but not 4 › 2.
--
-- Word syntax: "@@name" articles only, "#name" headings only, ":name" labels
-- only, "*name" bold headings only, plain words any section. "_" or "\ "
-- inside a word is a space ("1.4_zortex"). A prefix alone ("@@") matches any
-- section of that type.
--
-- Ranking (as in the original search service):
--   score  = 100 × word quality (exact 3, prefix 2, substring 1, summed)
--          + type bonus (article 2000, heading 1000 − 50 × level,
--            bold heading 400, label 300)
--   order  = files grouped by their best score (live notes before archived),
--            then document order inside a file, so parents precede children.
--   The direct sub-sections of a match are listed under it.
--
-- Configuration (Config.ui.search, see config.lua):
--   default_mode        "section" (sections + matching lines) | "article"
--   max_results         cap on results per query
--   token_filters       [n] = section types that may be a result when the
--                       prompt has n words ("all" = every type); bold
--                       headings and labels above the first heading count
--                       as H1. Typed words (#, :, *, @@) ignore the filter.
--   breadcrumb_display, min_score, access_decay_rate, history
--                       reserved (results always show the full breadcrumb)
local M = {}
local tree_module = require("zortex.core.tree")
local fs = require("zortex.utils.filesystem")
local highlights = require("zortex.features.highlights")
local Config = require("zortex.config")

-- Telescope is optional: load it only when a picker opens.
local function telescope()
	return {
		pickers = require("telescope.pickers"),
		finders = require("telescope.finders"),
		conf = require("telescope.config").values,
		actions = require("telescope.actions"),
		action_state = require("telescope.actions.state"),
		previewers = require("telescope.previewers"),
	}
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- Built-in defaults (Config.defaults.ui.search) overlaid with `opts`.
function M.setup(opts)
	local defaults = vim.deepcopy(Config.defaults and Config.defaults.ui and Config.defaults.ui.search or {})
	M.config = vim.tbl_deep_extend("force", defaults, opts or {})
	return M.config
end

local function cfg()
	return M.config or M.setup()
end

-- Predicate over index entries: may this section be a result when the
-- prompt has `n` words? Bold headings and labels above the first heading of
-- their article are treated as level-1 headings (as before).
local function section_filter(n)
	local filters = cfg().token_filters or {}
	local spec = filters[math.max(1, math.min(n, #filters))]
	if spec == nil or spec == "all" then
		return function()
			return true
		end
	end

	local function allows(node_type, level)
		for _, rule in ipairs(spec) do
			if type(rule) == "string" then
				if node_type == rule then
					return true
				end
			elseif node_type == rule[1] and (not rule.max_level or (level or 0) <= rule.max_level) then
				return true
			end
		end
		return false
	end

	return function(entry)
		local node = entry.node
		if entry.root_level and (node.type == "bold_heading" or node.type == "label") then
			return allows("heading", 1)
		end
		return allows(node.type, node.level)
	end
end

-- ---------------------------------------------------------------------------
-- Tokenization
-- ---------------------------------------------------------------------------

local TOKEN_PREFIXES = {
	{ "@@", "article" },
	{ "#", "heading" },
	{ ":", "label" },
	{ "*", "bold_heading" },
}

-- Split a prompt into typed words. "\ " and "_" are spaces inside a word.
local function tokenize(query)
	local tokens = {}
	local escaped = (query or ""):gsub("\\ ", "\0")
	for word in escaped:gmatch("%S+") do
		word = word:gsub("%z", " "):gsub("_", " "):lower()
		local kind = "general"
		for _, pref in ipairs(TOKEN_PREFIXES) do
			if word:sub(1, #pref[1]) == pref[1] then
				kind = pref[2]
				word = word:sub(#pref[1] + 1)
				if kind == "heading" then
					word = word:gsub("^#+", "")
				end
				break
			end
		end
		tokens[#tokens + 1] = { type = kind, text = word }
	end
	return tokens
end

-- ---------------------------------------------------------------------------
-- Highlight helpers
-- ---------------------------------------------------------------------------

-- Maps a section node type to its Zortex highlight group
local function get_hl_group(node)
	local ntype = node.type and tostring(node.type):lower() or ""
	if ntype == "article" then
		return "ZortexArticle"
	end
	if ntype == "heading" then
		return "ZortexHeading" .. math.min(tonumber(node.level) or 1, 3)
	end
	if ntype == "bold_heading" then
		return "ZortexBoldHeading"
	end
	if ntype == "label" then
		return "ZortexLabel"
	end
	return "Normal"
end

-- Maps a raw content line to its Zortex highlight group (mirrors highlights.lua patterns)
local function get_line_hl_group(line)
	if line:match("^%s*%-%s*%[x%]") then
		return "ZortexTaskDone"
	elseif line:match("^%s*%-%s*%[.?%]") then
		return "ZortexTaskText"
	elseif line:match("^%s*%-%s*%w[^:]*:%s") and not line:find("%.%s.-:") then
		return "ZortexLabelListText"
	elseif line:match("^%s*%-%s*%w[^:]*:$") and not line:find("%.%s.-:") then
		return "ZortexLabelList"
	elseif line:match("^%s*%-") then
		local indent = #(line:match("^(%s*)") or "")
		return "ZortexBullet" .. math.min(math.floor(indent / 2) + 1, 4)
	elseif line:match("^%s*%d+%.") then
		return "ZortexNumberList"
	end
	return "Normal"
end

-- ---------------------------------------------------------------------------
-- Display builders
-- ---------------------------------------------------------------------------

local function make_section_display(entry)
	local node = entry.value.node
	local display_str = ""
	local hl_table = {}
	local first = true

	for _, p_node in ipairs(node:get_full_path()) do
		if p_node.type ~= "root" then
			if not first then
				local sep_start = #display_str
				display_str = display_str .. " › "
				table.insert(hl_table, { { sep_start, #display_str }, "Comment" })
			end
			first = false

			local hl_group = get_hl_group(p_node)
			local start_pos = #display_str
			display_str = display_str .. (p_node.text or "Untitled")
			if start_pos < #display_str then
				table.insert(hl_table, { { start_pos, #display_str }, hl_group })
			end
		end
	end

	if entry.value.archived then
		local start = #display_str
		display_str = display_str .. "  (archive)"
		table.insert(hl_table, { { start, #display_str }, "Comment" })
	end

	return display_str, hl_table
end

-- Line result: article name › trimmed line content with semantic highlight
local function make_line_display(entry)
	local result = entry.value
	local display_str = ""
	local hl_table = {}

	if result.article_name then
		display_str = result.article_name
		table.insert(hl_table, { { 0, #display_str }, "ZortexArticle" })
		local sep_start = #display_str
		display_str = display_str .. " › "
		table.insert(hl_table, { { sep_start, #display_str }, "Comment" })
	end

	local text_start = #display_str
	display_str = display_str .. vim.trim(result.line)
	if text_start < #display_str then
		table.insert(hl_table, { { text_start, #display_str }, get_line_hl_group(result.line) })
	end

	return display_str, hl_table
end

-- ---------------------------------------------------------------------------
-- Previewer
-- ---------------------------------------------------------------------------

local function zortex_previewer()
	return telescope().previewers.new_buffer_previewer({
		title = "Zortex Preview",
		define_preview = function(self, entry, status)
			if not entry or not entry.value then
				return
			end
			local result = entry.value

			local lines = fs.read_lines(result.filepath)
			if not lines then
				return
			end

			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)

			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(self.state.bufnr) then
					highlights.highlight_buffer(self.state.bufnr)

					local ns_id = vim.api.nvim_create_namespace("zortex_search_preview")
					local focus_line -- 0-indexed

					if result.result_type == "section" then
						focus_line = result.node.start_line - 1
						for line = focus_line, result.node.end_line - 1 do
							if line < #lines then
								vim.api.nvim_buf_add_highlight(self.state.bufnr, ns_id, "Visual", line, 0, -1)
							end
						end
					else
						focus_line = result.lnum - 1
					end

					vim.api.nvim_buf_add_highlight(self.state.bufnr, ns_id, "CursorLine", focus_line, 0, -1)

					vim.api.nvim_win_call(status.preview_win, function()
						vim.fn.cursor(focus_line + 1, 1)
						vim.cmd("normal! zz")
					end)
				end
			end)
		end,
	})
end

-- ---------------------------------------------------------------------------
-- Index helpers (shared by indexing + matching)
-- ---------------------------------------------------------------------------

-- Collect set of line numbers that are structural section start lines
local function collect_structural_lines(node, set)
	if node.type ~= "root" then
		set[node.start_line] = true
	end
	for _, child in ipairs(node.children) do
		collect_structural_lines(child, set)
	end
end

-- Find the article node whose range contains lnum
local function get_article_for_line(tree, lnum)
	for _, child in ipairs(tree.children) do
		if child.type == "article" and lnum >= child.start_line and lnum <= child.end_line then
			return child
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Indexing: ALL disk reads, tree parsing and lower-casing happen here, once.
-- The picker builds the index when it opens; each keystroke then filters this
-- purely in-memory structure (see M.query_index).
-- ---------------------------------------------------------------------------

function M.build_index(files)
	local index = {}
	for _, filepath in ipairs(files) do
		local lines = fs.read_lines(filepath)
		if lines and not table.concat(lines, "\n", 1, math.min(5, #lines)):find("@Ignore") then
			local tree = tree_module.get_tree(filepath)
			if tree then
				-- Lower-case every line a single time.
				local lower_lines = {}
				for i, l in ipairs(lines) do
					lower_lines[i] = l:lower()
				end

				-- Structural start lines so the line scan can skip them.
				local structural = {}
				collect_structural_lines(tree, structural)

				-- Pre-compute section candidates: each carries its typed,
				-- lower-cased path (ancestors + self) for fast matching.
				local sections = {}
				local nodes = tree_module.search_nodes(tree, function()
					return true
				end)
				for _, node in ipairs(nodes) do
					local root_level = true
					for _, anc in ipairs(node:ancestors()) do
						if anc.type == "heading" then
							root_level = false
							break
						end
					end
					local typed = {}
					for _, p in ipairs(node:get_full_path()) do
						if not p:is_root() then
							local texts = { (p.text or ""):lower() }
							for _, alias in ipairs(p.names or {}) do
								texts[#texts + 1] = alias:lower()
							end
							typed[#typed + 1] = { type = p.type, text = texts[1], texts = texts }
						end
					end
					sections[#sections + 1] = {
						node = node,
						filepath = filepath,
						breadcrumb = node:get_breadcrumb(" › "),
						path = typed,
						root_level = root_level,
					}
				end

				-- Pre-compute line candidates (skip structural + blank lines).
				local line_items = {}
				for lnum, line in ipairs(lines) do
					if not structural[lnum] and vim.trim(line) ~= "" then
						local article = get_article_for_line(tree, lnum)
						line_items[#line_items + 1] = {
							filepath = filepath,
							lnum = lnum,
							line = line,
							lower = lower_lines[lnum],
							article_name = article and article.text or nil,
						}
					end
				end

				index[#index + 1] = {
					archived = require("zortex.core.notes").is_archived(filepath),
					lower_lines = lower_lines,
					sections = sections,
					lines = line_items,
				}
			end
		end
	end
	return index
end

-- ---------------------------------------------------------------------------
-- Matching (pure in-memory, no I/O)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Ordered path matching & scoring
-- ---------------------------------------------------------------------------

local TYPE_OK = {
	general = function()
		return true
	end,
	article = function(t)
		return t == "article"
	end,
	heading = function(t)
		return t == "heading"
	end,
	label = function(t)
		return t == "label"
	end,
	bold_heading = function(t)
		return t == "bold_heading"
	end,
}

-- Quality of one word on one path element: exact 3, prefix 2, substring 1,
-- 0 = no match. Article aliases count; a bare prefix ("@@") matches any
-- element of its type.
local function token_score(tok, el)
	if not TYPE_OK[tok.type](el.type) then
		return 0
	end
	if tok.text == "" then
		return 1
	end
	local best = 0
	for _, text in ipairs(el.texts or { el.text }) do
		local q = 0
		if text == tok.text then
			q = 3
		elseif text:sub(1, #tok.text) == tok.text then
			q = 2
		elseif text:find(tok.text, 1, true) then
			q = 1
		end
		if q > best then
			best = q
		end
	end
	return best
end

-- Best total word quality for matching the words along `path` in order, with
-- the LAST word on the last element (the section itself). Consecutive words
-- may share an element. nil when there is no such match.
-- best[j][i]: words 1..j matched, word j on element i.
local function path_match(path, tokens)
	local n, m = #path, #tokens
	if n == 0 then
		return nil
	end
	local prev = {}
	for i = 1, n do
		local q = token_score(tokens[1], path[i])
		prev[i] = q > 0 and q or nil
	end
	for j = 2, m do
		local cur, run = {}, nil -- run = best of prev[1..i]
		for i = 1, n do
			if prev[i] and (not run or prev[i] > run) then
				run = prev[i]
			end
			local q = token_score(tokens[j], path[i])
			if run and q > 0 then
				cur[i] = run + q
			end
		end
		prev = cur
	end
	return prev[n]
end

local function type_bonus(node)
	if node.type == "article" then
		return 2000
	elseif node.type == "heading" then
		return 1000 - (node.level or 1) * 50
	elseif node.type == "bold_heading" then
		return 400
	elseif node.type == "label" then
		return 300
	end
	return 0
end

local function section_result(sec, file, score, extra)
	local r = {
		result_type = "section",
		filepath = sec.filepath,
		node = sec.node,
		breadcrumb = sec.breadcrumb,
		score = score,
		archived = file.archived,
	}
	for k, v in pairs(extra or {}) do
		r[k] = v
	end
	return r
end

-- Section results, grouped by file (best file first, live before archived),
-- in document order within a file.
--   allowed(entry)    which sections may be results
--   with_children     also list the direct sub-sections of each match
local function match_sections(index, tokens, allowed, with_children)
	local groups = {}
	for _, file in ipairs(index) do
		local results, best = {}, -math.huge
		local matched = {} -- node -> score of explicit matches in this file
		for _, sec in ipairs(file.sections) do
			local node = sec.node
			local score
			if #tokens == 0 then
				-- Empty prompt: top-level sections only
				if #sec.path == 1 and allowed(sec) then
					score = type_bonus(node)
				end
			elseif allowed(sec) then
				local q = path_match(sec.path, tokens)
				score = q and (q * 100 + type_bonus(node)) or nil
			end

			if score then
				matched[node] = score
				results[#results + 1] = section_result(sec, file, score)
				best = math.max(best, score)
			elseif with_children and #tokens > 0 and node.parent and matched[node.parent] then
				results[#results + 1] = section_result(sec, file, matched[node.parent], { child = true })
			end
		end
		if #results > 0 then
			groups[#groups + 1] = { file = file, results = results, best = best }
		end
	end

	table.sort(groups, function(a, b)
		if a.file.archived ~= b.file.archived then
			return not a.file.archived
		end
		if a.best ~= b.best then
			return a.best > b.best
		end
		return a.results[1].filepath < b.results[1].filepath
	end)

	local out = {}
	for _, g in ipairs(groups) do
		vim.list_extend(out, g.results) -- already in document order
	end
	return out
end

-- AND match: every token must appear somewhere in the line.
local function match_lines(index, tokens)
	local results = {}
	if #tokens == 0 then
		return results
	end
	for _, file in ipairs(index) do
		for _, ln in ipairs(file.lines) do
			local all = true
			for _, tok in ipairs(tokens) do
				if not ln.lower:find(tok.text, 1, true) then
					all = false
					break
				end
			end
			if all then
				results[#results + 1] = {
					result_type = "line",
					filepath = ln.filepath,
					lnum = ln.lnum,
					line = ln.line,
					article_name = ln.article_name,
				}
			end
		end
	end
	return results
end

-- Full query over a pre-built index.
--   "section" mode: section matches (with their direct sub-sections), then
--                   lines containing every word
--   "article" mode: articles only
-- Results are capped at max_results and numbered (`rank`) for the picker.
---@param opts { mode?: "section"|"article" }?
function M.query_index(index, prompt, opts)
	local c = cfg()
	local mode = (opts and opts.mode) or c.default_mode or "section"
	local tokens = tokenize(prompt)

	local results
	if mode == "article" then
		results = match_sections(index, tokens, function(entry)
			return entry.node.type == "article"
		end, false)
	else
		-- Typed words (#, :, *, @@) are explicit structural queries and may
		-- match at any depth; token_filters only shape untyped searches.
		local typed = false
		for _, tok in ipairs(tokens) do
			typed = typed or tok.type ~= "general"
		end
		local allowed = typed and function()
			return true
		end or section_filter(#tokens)
		results = match_sections(index, tokens, allowed, true)
		vim.list_extend(results, match_lines(index, tokens))
	end

	local max = c.max_results
	if max and #results > max then
		results = vim.list_slice(results, 1, max)
	end
	for i, r in ipairs(results) do
		r.rank = i
	end
	return results
end

-- ---------------------------------------------------------------------------
-- Backwards-compatible one-shot API
-- (build a throwaway index, then query — preserves the old signatures)
-- ---------------------------------------------------------------------------

function M.search_sections(files, prompt)
	local tokens = type(prompt) == "string" and tokenize(prompt) or prompt
	return match_sections(M.build_index(files), tokens, section_filter(#tokens), true)
end

function M.search_lines(files, prompt)
	local tokens = type(prompt) == "string" and tokenize(prompt) or prompt
	return match_lines(M.build_index(files), tokens)
end

-- Exposed for tests
M._tokenize = tokenize
M._path_match = path_match

-- =============================================================================
-- Note Creation
-- =============================================================================

local function create_new_note(prompt_bufnr, initial_text)
	telescope().actions.close(prompt_bufnr)

	-- Generate unique filename
	local date = os.date("%Y-%m-%d")
	local ext = Config.extension
	math.randomseed(os.time() + os.clock() * 1000)

	for _ = 1, 1000 do
		local filename = string.format("%s.%03d%s", date, math.random(0, 999), ext)
		local filepath = fs.get_file_path(filename)

		if filepath and not fs.file_exists(filepath) then
			vim.cmd("edit " .. vim.fn.fnameescape(filepath))
			vim.defer_fn(function()
				-- Set initial content
				local lines = { "@@" }
				if initial_text and initial_text ~= "" then
					-- Add the search text as article name
					lines[1] = "@@" .. initial_text
				end

				vim.api.nvim_buf_set_lines(0, 0, 0, false, lines)
				vim.api.nvim_win_set_cursor(0, { 1, 2 + #(initial_text or "") })
				vim.cmd("startinsert!")
			end, 50)
			return
		end
	end

	vim.notify("Failed to create unique filename", vim.log.levels.ERROR)
end

-- ---------------------------------------------------------------------------
-- Main picker
-- ---------------------------------------------------------------------------

function M.structural_search(opts)
	opts = opts or {}
	local t = telescope()
	local pickers, finders, conf, actions, action_state = t.pickers, t.finders, t.conf, t.actions, t.action_state
	local mode = opts.mode or cfg().default_mode or "section"
	local files = fs.find_all_notes()

	-- All disk reads + tree parsing happen ONCE, here. Each keystroke below
	-- only filters this in-memory index.
	local index = M.build_index(files)

	pickers
		.new(opts, {
			prompt_title = "Zortex Structural Search (" .. mode .. ")",
			debounce = 80, -- ms: coalesce rapid keystrokes (telescope picker option)
			finder = finders.new_dynamic({
				fn = function(prompt)
					return M.query_index(index, prompt, { mode = mode })
				end,
				entry_maker = function(entry)
					if entry.result_type == "section" then
						return {
							value = entry,
							display = make_section_display,
							ordinal = entry.breadcrumb,
							filename = entry.filepath,
							lnum = entry.node.start_line,
						}
					else
						return {
							value = entry,
							display = make_line_display,
							ordinal = entry.line,
							filename = entry.filepath,
							lnum = entry.lnum,
						}
					end
				end,
			}),
			-- Keep query_index's ranking; borrow the fuzzy sorter's highlighter
			sorter = require("telescope.sorters").Sorter:new({
				scoring_function = function(_, _, _, entry)
					return entry.value.rank or math.huge
				end,
				highlighter = conf.generic_sorter(opts).highlighter,
			}),
			previewer = zortex_previewer(),
			layout_strategy = "horizontal",
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection and selection.value then
						local result = selection.value
						vim.cmd("edit " .. vim.fn.fnameescape(result.filepath))
						local lnum = result.result_type == "section" and result.node.start_line or result.lnum
						vim.fn.cursor(lnum, 1)
						vim.cmd("normal! zz")
					end
				end)

				local function open_in(split_type)
					return function()
						local selection = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if selection and selection.value then
							local result = selection.value
							vim.cmd(split_type .. " " .. vim.fn.fnameescape(result.filepath))
							local lnum = result.result_type == "section" and result.node.start_line or result.lnum
							vim.fn.cursor(lnum, 1)
							vim.cmd("normal! zz")
						end
					end
				end

				-- Create new note with current query
				map({ "i", "n" }, "<C-o>", function()
					local current_picker = action_state.get_current_picker(prompt_bufnr)
					local prompt = current_picker:_get_prompt()
					create_new_note(prompt_bufnr, prompt)
				end)

				-- Toggle section / article mode
				map({ "i", "n" }, "<C-t>", function()
					mode = mode == "article" and "section" or "article"
					local picker = action_state.get_current_picker(prompt_bufnr)
					picker.prompt_border:change_title("Zortex Structural Search (" .. mode .. ")")
					picker:refresh(picker.finder, { reset_prompt = false })
				end)

				-- Open in splits
				map({ "i", "n" }, "<C-x>", open_in("split"))
				map({ "i", "n" }, "<C-v>", open_in("vsplit"))

				-- Preview scrolling
				map({ "i", "n" }, "<C-f>", actions.preview_scrolling_down)
				map({ "i", "n" }, "<C-b>", actions.preview_scrolling_up)

				-- Clear prompt
				map("i", "<C-u>", function()
					vim.api.nvim_buf_set_lines(prompt_bufnr, 0, 1, false, { "" })
					vim.api.nvim_win_set_cursor(0, { 1, 0 })
				end)

				return true
			end,
		})
		:find()
end

return M
