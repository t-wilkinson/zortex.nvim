-- features/search.lua - Structural Search UI & Logic
local M = {}
local tree_module = require("zortex.core.tree")
local fs = require("zortex.utils.filesystem")
local highlights = require("zortex.features.highlights")
local Config = require("zortex.config")

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

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
	return previewers.new_buffer_previewer({
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
-- Indexing: ALL disk reads, tree parsing and lower-casing happen here, ONCE.
-- The picker builds the index when it opens; each keystroke then filters this
-- purely in-memory structure (see M.query_index).
-- ---------------------------------------------------------------------------

-- NOTE: @Ignore now excludes a file from BOTH section and line results.
-- (The previous code only skipped ignored files for section results, so an
-- ignored file could still surface line matches. That asymmetry looked like
-- an oversight; this version is consistent. To restore the old behaviour,
-- index ignored files too and skip them only in the section loop.)
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
						typed[#typed + 1] = { type = p.type, text = (p.text or ""):lower() }
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

-- Does one pre-indexed section candidate satisfy the tokens?
-- Faithful re-implementation of the old node_matches, but over data that was
-- already resolved + lower-cased at index time.
local function section_matches(entry, tokens, lower_lines)
	local unmatched = {}
	for _, tok in ipairs(tokens) do
		local matched = false
		for _, p in ipairs(entry.path) do
			local type_ok = (tok.type == "general")
				or (tok.type == "heading" and (p.type == "heading" or p.type == "bold_heading"))
				or (tok.type == "label" and p.type == "label")
			if type_ok and p.text:find(tok.text, 1, true) then
				matched = true
				break
			end
		end
		if not matched then
			unmatched[#unmatched + 1] = tok
		end
	end

	-- Explicit #/: tokens MUST exist structurally; general tokens may live
	-- anywhere inside the node's content range. Tokens never contain
	-- whitespace, so a per-line scan is equivalent to concatenating the range.
	for _, tok in ipairs(unmatched) do
		if tok.type ~= "general" then
			return false
		end
		local found = false
		for lnum = entry.node.start_line, entry.node.end_line do
			local l = lower_lines[lnum]
			if l and l:find(tok.text, 1, true) then
				found = true
				break
			end
		end
		if not found then
			return false
		end
	end

	return true
end

local function match_sections(index, tokens)
	local results = {}
	for _, file in ipairs(index) do
		for _, sec in ipairs(file.sections) do
			if section_matches(sec, tokens, file.lower_lines) then
				results[#results + 1] = {
					result_type = "section",
					filepath = sec.filepath,
					node = sec.node,
					breadcrumb = sec.breadcrumb,
				}
			end
		end
	end
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

-- Full query over a pre-built index: sections ranked first, lines appended.
function M.query_index(index, prompt)
	local tokens = tokenize(prompt)
	local results = match_sections(index, tokens)
	vim.list_extend(results, match_lines(index, tokens))
	return results
end

-- ---------------------------------------------------------------------------
-- Backwards-compatible one-shot API
-- (build a throwaway index, then query — preserves the old signatures)
-- ---------------------------------------------------------------------------

function M.search_sections(files, tokens)
	return match_sections(M.build_index(files), tokens)
end

function M.search_lines(files, tokens)
	return match_lines(M.build_index(files), tokens)
end

-- =============================================================================
-- Note Creation
-- =============================================================================

local function create_new_note(prompt_bufnr, initial_text)
	actions.close(prompt_bufnr)

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
	local files = fs.find_all_notes()

	-- All disk reads + tree parsing happen ONCE, here. Each keystroke below
	-- only filters this in-memory index.
	local index = M.build_index(files)

	pickers
		.new(opts, {
			prompt_title = "Zortex Structural Search",
			debounce = 80, -- ms: coalesce rapid keystrokes (telescope picker option)
			finder = finders.new_dynamic({
				fn = function(prompt)
					return M.query_index(index, prompt)
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
			sorter = conf.generic_sorter(opts),
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
