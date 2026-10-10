-- ui/telescope/search.lua - Structural Search UI & Logic
--
-- Configuration (Config.ui.search, see config.lua):
--   default_mode        "section" (sections + matching lines) | "article"
--   max_results         cap on results per query
--   token_filters       [n] = section types eligible for a structural match
--                       when the prompt has n tokens ("all" = every type);
--                       typing more tokens searches deeper into the tree.
--                       Typed tokens (#heading, :label) ignore the filter.
--   breadcrumb_display  which path parts to show for 1 / 2 / 3+ tokens
--   min_score, access_decay_rate, history
--                       reserved for ranking/history (not implemented yet)
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

-- Predicate: may `node` match structurally when the prompt has `n` tokens?
local function section_filter(n)
	local filters = cfg().token_filters or {}
	local spec = filters[math.max(1, math.min(n, #filters))]
	if spec == nil or spec == "all" then
		return function()
			return true
		end
	end
	return function(node)
		for _, rule in ipairs(spec) do
			if type(rule) == "string" then
				if node.type == rule then
					return true
				end
			elseif node.type == rule[1] and (not rule.max_level or (node.level or 0) <= rule.max_level) then
				return true
			end
		end
		return false
	end
end

-- Breadcrumb kinds for `n` tokens: "article", "heading", "heading_1_2",
-- "bold_heading", "label".
local function breadcrumb_kinds(n)
	local display = cfg().breadcrumb_display or {}
	local kinds = (n <= 1 and display.one_token) or (n == 2 and display.two_tokens) or display.three_plus_tokens
	if not kinds then
		return nil
	end
	local set = {}
	for _, k in ipairs(kinds) do
		set[k] = true
	end
	return set
end

local function in_breadcrumb(node, kinds)
	if not kinds then
		return true
	end
	if node.type == "heading" then
		return kinds.heading or (kinds.heading_1_2 and (node.level or 0) <= 2) or false
	end
	return kinds[node.type] or false
end

-- ---------------------------------------------------------------------------
-- Tokenization
-- ---------------------------------------------------------------------------

local function tokenize(query)
	local tokens = {}
	for word in query:gmatch("%S+") do
		if word:match("^#") then
			table.insert(tokens, { type = "heading", text = word:sub(2):lower() })
		elseif word:match("^:") then
			table.insert(tokens, { type = "label", text = word:sub(2):lower() })
		else
			table.insert(tokens, { type = "general", text = word:lower() })
		end
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
	local kinds = breadcrumb_kinds(entry.value.ntokens or 0)

	for _, p_node in ipairs(node:get_full_path()) do
		if p_node.type ~= "root" and (p_node == node or in_breadcrumb(p_node, kinds)) then
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
-- Ranking
--
-- Sections are ranked, not just matched. Sort key, most significant first:
--   1. tier   0 = every token matches the section's own name (or an article
--               alias), 1 = every token matches somewhere on its path,
--               2 = some words only occur in its content
--   2. level  structural level: article < H1 … H6 < bold heading < label
--   3. live notes before archived ones (z/archive.*, @Archive)
--   4. class  how the first token matches the section's own name:
--               0 = name starts with it, 1 = a word in the name starts with
--               it, 2 = inside a word, 3 = not in the name
--   5. depth  shorter paths first, then note order
-- So typing "p" lists articles whose name starts with P (Projects, or the
-- @@P alias) before other articles, articles before headings, and so on.
-- ---------------------------------------------------------------------------

-- 0 = prefix, 1 = word start, 2 = inside a word, nil = absent
local function match_class(text, needle)
	local s = text:find(needle, 1, true)
	if not s then
		return nil
	end
	local best = 2
	while s do
		if s == 1 then
			return 0
		end
		if text:sub(s - 1, s - 1):match("[^%w]") then
			best = 1
		end
		s = text:find(needle, s + 1, true)
	end
	return best
end

-- Best class over a path element's name and aliases
local function element_class(p, needle)
	local best
	for _, text in ipairs(p.texts or { p.text }) do
		local c = match_class(text, needle)
		if c and (not best or c < best) then
			best = c
		end
	end
	return best
end

local function type_ok(tok, p)
	return tok.type == "general"
		or (tok.type == "heading" and (p.type == "heading" or p.type == "bold_heading"))
		or (tok.type == "label" and p.type == "label")
end

local function content_has(entry, lower_lines, needle)
	for lnum = entry.node.start_line, entry.node.end_line do
		local l = lower_lines[lnum]
		if l and l:find(needle, 1, true) then
			return true
		end
	end
	return false
end

-- Rank one pre-indexed section against the tokens; nil when it doesn't match.
-- Explicit #/: tokens MUST match structurally; general tokens may also match
-- anywhere in the section's content.
local function rank_section(entry, tokens, lower_lines, archived)
	local self_el = entry.path[#entry.path]
	local tier, class = 0, nil

	for i, tok in ipairs(tokens) do
		local own = self_el and type_ok(tok, self_el) and element_class(self_el, tok.text)
		if own then
			if i == 1 then
				class = own
			end
		else
			local on_path = false
			for _, p in ipairs(entry.path) do
				if type_ok(tok, p) and element_class(p, tok.text) then
					on_path = true
					break
				end
			end
			if on_path then
				tier = math.max(tier, 1)
			elseif tok.type == "general" and content_has(entry, lower_lines, tok.text) then
				tier = 2
			else
				return nil
			end
		end
	end

	return {
		tier = tier,
		level = entry.node.level or 99,
		class = class or 3,
		archived = archived and 1 or 0,
		depth = #entry.path,
	}
end

local function compare_ranks(a, b)
	local ra, rb = a.rank_key, b.rank_key
	if ra.tier ~= rb.tier then
		return ra.tier < rb.tier
	end
	if ra.level ~= rb.level then
		return ra.level < rb.level
	end
	if ra.archived ~= rb.archived then
		return ra.archived < rb.archived
	end
	if ra.class ~= rb.class then
		return ra.class < rb.class
	end
	if ra.depth ~= rb.depth then
		return ra.depth < rb.depth
	end
	return a.order < b.order
end

local function match_sections(index, tokens, allowed)
	local results = {}
	for _, file in ipairs(index) do
		for _, sec in ipairs(file.sections) do
			local rank_key = allowed(sec.node) and rank_section(sec, tokens, file.lower_lines, file.archived)
			if rank_key then
				results[#results + 1] = {
					rank_key = rank_key,
					order = #results + 1,
					archived = file.archived,
					result_type = "section",
					filepath = sec.filepath,
					node = sec.node,
					breadcrumb = sec.breadcrumb,
					ntokens = #tokens,
				}
			end
		end
	end
	table.sort(results, compare_ranks)
	return results
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
--   "section" mode: structural matches (filtered by token_filters) ranked
--                   first, matching lines appended
--   "article" mode: only articles whose content matches every token
-- Results are capped at max_results.
---@param opts { mode?: "section"|"article" }?
function M.query_index(index, prompt, opts)
	local c = cfg()
	local mode = (opts and opts.mode) or c.default_mode or "section"
	local tokens = tokenize(prompt)

	local results
	if mode == "article" then
		results = match_sections(index, tokens, function(node)
			return node.type == "article"
		end)
	else
		-- Typed tokens (#heading, :label) are explicit structural queries and
		-- search every depth; token_filters only shape untyped searches.
		local typed = false
		for _, tok in ipairs(tokens) do
			typed = typed or tok.type ~= "general"
		end
		local allowed = typed and function()
			return true
		end or section_filter(#tokens)
		results = match_sections(index, tokens, allowed)
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

function M.search_sections(files, tokens)
	return match_sections(M.build_index(files), tokens, section_filter(#tokens))
end

function M.search_lines(files, tokens)
	return match_lines(M.build_index(files), tokens)
end

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
