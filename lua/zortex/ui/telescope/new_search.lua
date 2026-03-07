-- features/search.lua - Structural Search UI & Logic
local M = {}
local tree_module = require("zortex.core.tree")
local fs = require("zortex.utils.filesystem")
local highlights = require("zortex.features.highlights")

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
-- Section matching
-- ---------------------------------------------------------------------------

-- Strict algorithm resolving path ancestors and explicit token requirements
local function node_matches(node, query_tokens, lines)
	local path = vim.list_extend({}, node:get_path())
	table.insert(path, node)

	local unmatched = {}
	for _, token in ipairs(query_tokens) do
		local matched = false
		if token.type == "heading" then
			for _, p in ipairs(path) do
				if (p.type == "heading" or p.type == "bold_heading") and p.text:lower():find(token.text, 1, true) then
					matched = true
					break
				end
			end
		elseif token.type == "label" then
			for _, p in ipairs(path) do
				if p.type == "label" and p.text:lower():find(token.text, 1, true) then
					matched = true
					break
				end
			end
		else
			for _, p in ipairs(path) do
				if p.text:lower():find(token.text, 1, true) then
					matched = true
					break
				end
			end
		end
		if not matched then
			table.insert(unmatched, token)
		end
	end

	if #unmatched > 0 then
		local content = table.concat(lines, "\n", node.start_line, node.end_line):lower()
		for _, token in ipairs(unmatched) do
			if token.type == "heading" or token.type == "label" then
				return false -- Explicit tokens MUST exist strictly in structure/path
			end
			if not content:find(token.text, 1, true) then
				return false
			end
		end
	end

	return true
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

local function get_clean_breadcrumb(node)
	local path = vim.list_extend({}, node:get_path())
	table.insert(path, node)
	local parts = {}
	for _, p in ipairs(path) do
		if p.type ~= "root" then
			table.insert(parts, p.text)
		end
	end
	return table.concat(parts, " › ")
end

-- Section result: coloured breadcrumb path only (no child preview lines)
local function make_section_display(entry)
	local node = entry.value.node
	local path = vim.list_extend({}, node:get_path())
	table.insert(path, node)

	local display_str = ""
	local hl_table = {}
	local first = true

	for _, p_node in ipairs(path) do
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
-- Search backends (modular – each returns a flat list of result tables)
-- ---------------------------------------------------------------------------

function M.search_sections(files, tokens)
	local results = {}
	for _, filepath in ipairs(files) do
		local tree = tree_module.get_tree(filepath)
		if tree then
			local lines = fs.read_lines(filepath)
			if lines then
				local matched = tree_module.search_nodes(tree, function(node)
					return node_matches(node, tokens, lines)
				end)
				for _, node in ipairs(matched) do
					table.insert(results, {
						result_type = "section",
						filepath = filepath,
						node = node,
						breadcrumb = get_clean_breadcrumb(node),
					})
				end
			end
		end
	end
	return results
end

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

-- AND match: every token must appear somewhere in the line
function M.search_lines(files, tokens)
	local results = {}
	if #tokens == 0 then
		return results
	end

	for _, filepath in ipairs(files) do
		local tree = tree_module.get_tree(filepath)
		if tree then
			local lines = fs.read_lines(filepath)
			if lines then
				local structural = {}
				collect_structural_lines(tree, structural)

				for lnum, line in ipairs(lines) do
					if not structural[lnum] and vim.trim(line) ~= "" then
						local lower = line:lower()
						local all_match = true
						for _, token in ipairs(tokens) do
							if not lower:find(token.text, 1, true) then
								all_match = false
								break
							end
						end
						if all_match then
							local article = get_article_for_line(tree, lnum)
							table.insert(results, {
								result_type = "line",
								filepath = filepath,
								lnum = lnum,
								line = line,
								article_name = article and article.text or nil,
							})
						end
					end
				end
			end
		end
	end
	return results
end

-- ---------------------------------------------------------------------------
-- Main picker
-- ---------------------------------------------------------------------------

function M.structural_search(opts)
	opts = opts or {}
	local files = fs.find_all_notes()

	pickers
		.new(opts, {
			prompt_title = "Zortex Structural Search",
			finder = finders.new_dynamic({
				fn = function(prompt)
					local tokens = tokenize(prompt)
					-- Sections ranked first; line results appended after
					local results = M.search_sections(files, tokens)
					for _, r in ipairs(M.search_lines(files, tokens)) do
						table.insert(results, r)
					end
					return results
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
			attach_mappings = function(prompt_bufnr, _)
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
				return true
			end,
		})
		:find()
end

return M
