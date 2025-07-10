-- lua/zortex/cmp.lua
--
-- A nvim-cmp source for context-aware completion of Zortex links.
-- This source understands the structure of your notes, including articles,
-- headings, tags, labels, and more, with hierarchical suggestions.

local cmp = require("cmp")
local types = require("cmp.types")
local vim = vim

-- Zortex core modules
local parser = require("zortex.core.parser")
local search_managers = require("zortex.modules.search_managers")
local fs = require("zortex.core.filesystem")

local M = {}

-- =============================================================================
-- Helper Functions
-- =============================================================================

-- Get the file path for an article name from the cache
local function find_article_filepath(article_name)
	if not article_name or article_name == "" then
		return nil
	end
	local lower_name = article_name:lower()
	search_managers.IndexManager.update_sync()
	local cache = search_managers.IndexManager.cache
	for path, data in pairs(cache) do
		if data.metadata and data.metadata.aliases then
			for _, alias in ipairs(data.metadata.aliases) do
				if alias:lower() == lower_name then
					return path
				end
			end
		end
	end
	return nil
end

-- Get lines for a given file path, using the cache if possible
local function get_lines(filepath)
	if not filepath then
		return nil
	end
	local cache = search_managers.IndexManager.cache
	if cache[filepath] and cache[filepath].lines then
		return cache[filepath].lines
	end
	return fs.read_lines(filepath)
end

-- =============================================================================
-- Suggestion Fetchers
-- =============================================================================

--- Provides suggestions for Article names and aliases.
local function get_article_suggestions(query)
	local suggestions = {}
	local seen = {}
	search_managers.IndexManager.update_sync()
	local cache = search_managers.IndexManager.cache
	for _, data in pairs(cache) do
		if data.metadata and data.metadata.aliases then
			for _, alias in ipairs(data.metadata.aliases) do
				if not seen[alias] and alias:lower():find(query:lower(), 1, true) then
					table.insert(suggestions, {
						label = alias,
						kind = types.lsp.CompletionItemKind.File,
						detail = "Article",
						sortText = "1_" .. alias,
					})
					seen[alias] = true
				end
			end
		end
	end
	return suggestions
end

--- Provides suggestions for Tags.
local function get_tag_suggestions(query)
	local suggestions = {}
	local seen = {}
	local cache = search_managers.IndexManager.cache
	for _, data in pairs(cache) do
		if data.metadata and data.metadata.tags then
			for _, tag in ipairs(data.metadata.tags) do
				local tag_label = "@" .. tag
				if not seen[tag_label] and tag:lower():find(query:lower(), 1, true) then
					table.insert(suggestions, {
						label = tag_label,
						kind = types.lsp.CompletionItemKind.Constant,
						detail = "Tag",
						sortText = "2_" .. tag_label,
					})
					seen[tag_label] = true
				end
			end
		end
	end
	return suggestions
end

--- Provides suggestions for Headings within a given range.
local function get_heading_suggestions_in_range(lines, start_lnum, end_lnum, query)
	local suggestions = {}
	for i = start_lnum, end_lnum do
		local line = lines[i]
		local heading = parser.parse_heading(line)
		if heading and heading.text:lower():find(query:lower(), 1, true) then
			table.insert(suggestions, {
				label = string.rep("#", heading.level) .. " " .. heading.text,
				insertText = "#" .. heading.text,
				kind = types.lsp.CompletionItemKind.Struct,
				detail = "Heading (Lvl " .. heading.level .. ")",
				sortText = "1_h" .. heading.level .. "_" .. heading.text,
			})
		end
	end
	return suggestions
end

--- Provides suggestions for Bold Headings within a given range.
local function get_bold_heading_suggestions_in_range(lines, start_lnum, end_lnum, query)
	local suggestions = {}
	for i = start_lnum, end_lnum do
		local line = lines[i]
		if parser.is_bold_heading(line) then
			local text = line:match("^%*%*([^%*]+)%*%*:?$")
			if text and text:lower():find(query:lower(), 1, true) then
				table.insert(suggestions, {
					label = "**" .. text .. "**",
					insertText = "*" .. text, -- Use single * for link component
					kind = types.lsp.CompletionItemKind.Interface,
					detail = "Bold Heading",
					sortText = "2_" .. text,
				})
			end
		end
	end
	return suggestions
end

--- Provides suggestions for Labels within a given range.
local function get_label_suggestions_in_range(lines, start_lnum, end_lnum, query)
	local suggestions = {}
	for i = start_lnum, end_lnum do
		local line = lines[i]
		local label = line:match("^(%w[^:]+):")
		if label and label:lower():find(query:lower(), 1, true) then
			table.insert(suggestions, {
				label = label .. ":",
				insertText = ":" .. label,
				kind = types.lsp.CompletionItemKind.Field,
				detail = "Label",
				sortText = "3_" .. label,
			})
		end
	end
	return suggestions
end

-- =============================================================================
-- Main Completion Logic
-- =============================================================================

function M.complete(self, params, callback)
	if type(params.offset) ~= "number" then
		callback(nil)
		return
	end

	local line = vim.api.nvim_get_current_line()
	local cursor_col = params.offset
	local link_start_col = -1
	for i = cursor_col, 1, -1 do
		if line:sub(i, i) == "[" then
			link_start_col = i
			break
		end
	end

	if link_start_col == -1 then
		callback(nil)
		return
	end

	local link_text = line:sub(link_start_col + 1, cursor_col)

	-- Case 1: Just typed '[' -- show all articles
	if link_text == "" then
		callback({ items = get_article_suggestions(""), isIncomplete = true })
		return
	end

	local components = vim.split(link_text, "/", { trimempty = false })
	local current_comp_idx = #components
	local query = components[current_comp_idx] or ""
	local context_path = {}
	for i = 1, current_comp_idx - 1 do
		table.insert(context_path, components[i])
	end

	local is_local_scope = link_text:sub(1, 1) == "/"
	local search_filepath
	local start_lnum, end_lnum = 1, -1

	-- Determine File Context
	if is_local_scope then
		search_filepath = vim.api.nvim_buf_get_name(0)
	else
		if #context_path > 0 then
			search_filepath = find_article_filepath(context_path[1])
		elseif #components == 1 then -- Top-level, not local
			local suggestions = get_article_suggestions(query)
			suggestions = vim.list_extend(suggestions, get_tag_suggestions(query:gsub("^@", "")))
			callback({ items = suggestions, isIncomplete = true })
			return
		end
	end

	if not search_filepath then
		callback(nil)
		return
	end

	local lines = get_lines(search_filepath)
	if not lines then
		callback(nil)
		return
	end
	end_lnum = #lines

	-- Determine Section Context (narrow down search range)
	local context_offset = is_local_scope and 0 or 1
	for i = 1, #context_path - context_offset do
		local comp_text = context_path[i + context_offset]:gsub("^[#*:]", "")
		local found_section = false
		for lnum = start_lnum, end_lnum do
			local line_text = lines[lnum]
			local section_type = parser.detect_section_type(line_text)
			local match = false
			if section_type == parser.SectionType.HEADING then
				local h = parser.parse_heading(line_text)
				if h and h.text == comp_text then
					match = true
				end
			elseif section_type == parser.SectionType.BOLD_HEADING then
				local t = line_text:match("^%*%*([^%*]+)%*%*:?$")
				if t and t == comp_text then
					match = true
				end
			elseif section_type == parser.SectionType.LABEL then
				local l = line_text:match("^(%w[^:]+):")
				if l and l == comp_text then
					match = true
				end
			end
			if match then
				start_lnum = lnum + 1
				end_lnum = parser.find_section_end(lines, lnum, section_type)
				found_section = true
				break
			end
		end
		if not found_section then
			callback(nil)
			return
		end
	end

	-- Get suggestions based on the final query/context
	local suggestions = {}
	local query_prefix = query:match("^[#:*@]")
	local query_text = query:gsub("^[#:*@]%s*", "")

	if query_prefix == "@" then
		suggestions = get_tag_suggestions(query_text)
	elseif query_prefix == "#" then
		suggestions = get_heading_suggestions_in_range(lines, start_lnum, end_lnum, query_text)
	elseif query_prefix == "*" then
		suggestions = get_bold_heading_suggestions_in_range(lines, start_lnum, end_lnum, query_text)
	elseif query_prefix == ":" then
		suggestions = get_label_suggestions_in_range(lines, start_lnum, end_lnum, query_text)
	else
		-- No prefix, or just text after a '/'
		local h_sugs = get_heading_suggestions_in_range(lines, start_lnum, end_lnum, query)
		local b_sugs = get_bold_heading_suggestions_in_range(lines, start_lnum, end_lnum, query)
		local l_sugs = get_label_suggestions_in_range(lines, start_lnum, end_lnum, query)
		suggestions = vim.list_extend(h_sugs, b_sugs)
		suggestions = vim.list_extend(suggestions, l_sugs)
	end

	callback({ items = suggestions, isIncomplete = true })
end

-- =============================================================================
-- nvim-cmp Source Definition
-- =============================================================================

M.source = {
	name = "zortex",
	priority = 1000, -- High priority to override others inside links
	group_index = 1,
	trigger_characters = { "[", "/", "#", ":", "@", "*", " " },
	is_triggered = function()
		local line = vim.api.nvim_get_current_line()
		local cursor_col = vim.api.nvim_win_get_cursor(0)[2]
		local part_of_line = line:sub(1, cursor_col)
		-- Only trigger if the cursor is inside an unclosed '[' bracket
		local link_start = part_of_line:match(".*/([^/]-)%.lua")
		if not link_start then
			return false
		end
		-- Ensure there is no closing ']' after the opening '['
		return not part_of_line:sub(link_start):find("%]")
	end,
	complete = M.complete,
}

--- Registers the Zortex source with nvim-cmp.
function M.setup()
	cmp.register_source(M.source.name, M.source)
end

return M
