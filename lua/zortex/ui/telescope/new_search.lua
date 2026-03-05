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

-- Tokenize and apply typing properties locally
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
			-- General Token: Can it match ANY parent component?
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

	-- Re-resolve unmatched general tokens strictly as an "AND" payload in node's content
	if #unmatched > 0 then
		local content = table.concat(lines, "\n", node.start_line, node.end_line):lower()

		for _, token in ipairs(unmatched) do
			if token.type == "heading" or token.type == "label" then
				return false -- Explicit tokens MUST exist strictly in the structure/path
			end
			if not content:find(token.text, 1, true) then
				return false
			end
		end
	end

	return true
end

-- Maps a node type to its corresponding highlight group from features/highlights.lua
local function get_hl_group(node)
	if node.type == "article" then
		return "ZortexArticle"
	end
	if node.type == "heading" then
		return "ZortexHeading" .. math.min(node.level or 1, 3)
	end
	if node.type == "bold_heading" then
		return "ZortexBoldHeading"
	end
	if node.type == "label" then
		return "ZortexLabel"
	end
	return "Normal"
end

-- Extracts the direct children of the node (e.g. h3s inside an h2)
local function get_first_3_children(node, lines)
	local children = {}

	for _, child in ipairs(node.children) do
		table.insert(children, {
			prefix = "  ↳ ",
			text = child.text,
			hl_group = get_hl_group(child),
		})
		if #children == 3 then
			break
		end
	end

	-- Fallback to standard lines if no structured sub-sections exist
	if #children < 3 then
		local start_l = node.start_line + 1
		local end_l = node.end_line
		if #node.children > 0 then
			end_l = node.children[1].start_line - 1
		end
		for i = start_l, end_l do
			local line = lines[i]
			if line:match("^%s*-%s*%[.%]") or line:match("^%s*%-") then
				table.insert(children, {
					prefix = "  • ",
					text = vim.trim(line),
					hl_group = "Normal",
				})
				if #children == 3 then
					break
				end
			end
		end
	end
	return children
end

-- Creates a raw string for matching without highlights
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

-- Dynamically builds the Multiline string + Highlight table mappings
local function make_display(entry)
	local node = entry.value.node
	local path = vim.list_extend({}, node:get_path())
	table.insert(path, node)

	local display_str = ""
	local hl_table = {}
	local first = true

	-- 1. Format Breadcrumb (Excluding Root)
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
			display_str = display_str .. p_node.text
			table.insert(hl_table, { { start_pos, #display_str }, hl_group })
		end
	end

	-- 2. Format Direct Children Context
	for _, child in ipairs(entry.value.children_texts) do
		display_str = display_str .. "\n"
		local prefix_start = #display_str
		display_str = display_str .. child.prefix
		table.insert(hl_table, { { prefix_start, #display_str }, "Comment" })

		local text_start = #display_str
		display_str = display_str .. child.text
		table.insert(hl_table, { { text_start, #display_str }, child.hl_group })
	end

	return display_str, hl_table
end

local function zortex_previewer()
	return previewers.new_buffer_previewer({
		title = "Zortex Section Preview",
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
					for line = result.node.start_line - 1, result.node.end_line - 1 do
						if line < #lines then
							vim.api.nvim_buf_add_highlight(self.state.bufnr, ns_id, "Visual", line, 0, -1)
						end
					end
					vim.api.nvim_buf_add_highlight(
						self.state.bufnr,
						ns_id,
						"CursorLine",
						result.node.start_line - 1,
						0,
						-1
					)

					vim.api.nvim_win_call(status.preview_win, function()
						vim.fn.cursor(result.node.start_line, 1)
						vim.cmd("normal! zz")
					end)
				end
			end)
		end,
	})
end

function M.structural_search(opts)
	opts = opts or {}
	local files = fs.find_all_notes()

	local function finder()
		return finders.new_dynamic({
			fn = function(prompt)
				local tokens = tokenize(prompt)
				local results = {}

				for _, filepath in ipairs(files) do
					local tree = tree_module.get_tree(filepath)
					if tree then
						local lines = fs.read_lines(filepath)
						if lines then
							local matched_nodes = tree_module.search_nodes(tree, function(node)
								return node_matches(node, tokens, lines)
							end)

							for _, node in ipairs(matched_nodes) do
								local children_texts = get_first_3_children(node, lines)
								table.insert(results, {
									filepath = filepath,
									node = node,
									breadcrumb = get_clean_breadcrumb(node),
									children_texts = children_texts,
								})
							end
						end
					end
				end
				return results
			end,
			entry_maker = function(entry)
				return {
					value = entry,
					display = function(ent)
						return make_display(ent)
					end,
					ordinal = entry.breadcrumb,
					filename = entry.filepath,
					lnum = entry.node.start_line,
				}
			end,
		})
	end

	pickers
		.new(opts, {
			prompt_title = "Zortex Structural Search",
			finder = finder(),
			sorter = conf.generic_sorter(opts),
			previewer = zortex_previewer(),
			layout_strategy = "horizontal",
			multiline = true, -- Enables Telescope native multiline mapping
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection and selection.value then
						vim.cmd("edit " .. vim.fn.fnameescape(selection.value.filepath))
						vim.fn.cursor(selection.value.node.start_line, 1)
						vim.cmd("normal! zz")
					end
				end)
				return true
			end,
		})
		:find()
end

return M
