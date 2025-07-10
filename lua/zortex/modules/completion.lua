-- modules/completion.lua - Context-aware completion for Zortex links
local M = {}

local parser = require("zortex.core.parser")
local search = require("zortex.core.search")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")

-- Cache for performance
local cache = {
	articles = nil,
	article_data = {},
	last_update = 0,
}

-- Update cache
local function update_cache()
	local now = vim.loop.now()
	if now - cache.last_update < 5000 then -- 5 second cache
		return
	end

	cache.articles = {}
	cache.article_data = {}
	local files = fs.get_all_note_files()

	for _, file in ipairs(files) do
		local lines = fs.read_lines(file)
		if lines then
			-- Extract article names and aliases
			local article_name = parser.extract_article_name(lines[1])
			if article_name then
				table.insert(cache.articles, {
					name = article_name,
					file = file,
					type = "article",
				})

				-- Cache file data for quick access
				cache.article_data[file] = {
					lines = lines,
					headings = {},
					tags = {},
					labels = {},
				}

				-- Parse the file structure
				for lnum, line in ipairs(lines) do
					-- Tags
					if line:match("^@[^@]") then
						local tag = line:match("^@(.+)")
						if tag then
							table.insert(cache.article_data[file].tags, {
								text = tag,
								lnum = lnum,
							})
						end
					end

					-- Headings
					local heading = parser.parse_heading(line)
					if heading then
						table.insert(cache.article_data[file].headings, {
							level = heading.level,
							text = heading.text,
							lnum = lnum,
						})
					end

					-- Bold headings
					if parser.is_bold_heading(line) then
						local text = line:match("^%*%*([^%*]+)%*%*:?$")
						if text then
							table.insert(cache.article_data[file].headings, {
								level = 0, -- Bold headings are treated as special
								text = text,
								lnum = lnum,
								is_bold = true,
							})
						end
					end

					-- Labels
					if line:match("^%w[^:]+:") then
						local label = line:match("^([^:]+):")
						if label then
							table.insert(cache.article_data[file].labels, {
								text = label,
								lnum = lnum,
							})
						end
					end
				end
			end
		end
	end

	cache.last_update = now
end

-- Get completions for articles
local function get_article_completions()
	update_cache()
	local items = {}

	for _, article in ipairs(cache.articles) do
		table.insert(items, {
			label = article.name,
			kind = 1, -- Text
			detail = "Article",
			sortText = "1_" .. article.name,
		})
	end

	return items
end

-- Get completions for tags (global)
local function get_tag_completions()
	update_cache()
	local seen = {}
	local items = {}

	for _, data in pairs(cache.article_data) do
		for _, tag in ipairs(data.tags) do
			if not seen[tag.text] then
				seen[tag.text] = true
				table.insert(items, {
					label = "@" .. tag.text,
					kind = 14, -- Keyword
					detail = "Tag",
					sortText = "2_" .. tag.text,
				})
			end
		end
	end

	return items
end

-- Get completions for current file
local function get_current_file_completions(section_bounds)
	local lines = buffer.get_lines()
	local items = {}

	local start_line = section_bounds and section_bounds.start_line or 1
	local end_line = section_bounds and section_bounds.end_line or #lines

	-- Process lines within bounds
	for lnum = start_line, end_line do
		local line = lines[lnum]

		-- Headings
		local heading = parser.parse_heading(line)
		if heading then
			-- Only include sub-headings if we're in a section
			if not section_bounds or heading.level > (section_bounds.parent_level or 0) then
				local prefix = string.rep("#", heading.level)
				table.insert(items, {
					label = "#" .. heading.text,
					kind = 15, -- Snippet
					detail = prefix .. " " .. heading.text,
					sortText = "1_" .. string.format("%02d", heading.level) .. "_" .. heading.text,
					data = { lnum = lnum, level = heading.level },
				})
			end
		end

		-- Bold headings
		if parser.is_bold_heading(line) then
			local text = line:match("^%*%*([^%*]+)%*%*:?$")
			if text then
				table.insert(items, {
					label = "*" .. text,
					kind = 15,
					detail = "**" .. text .. "**",
					sortText = "2_" .. text,
					data = { lnum = lnum, is_bold = true },
				})
			end
		end

		-- Labels
		if line:match("^%w[^:]+:") then
			local label = line:match("^([^:]+):")
			if label then
				table.insert(items, {
					label = ":" .. label,
					kind = 12, -- Property
					detail = label .. ":",
					sortText = "3_" .. label,
					data = { lnum = lnum },
				})
			end
		end
	end

	return items
end

-- Get completions for a specific file
local function get_file_completions(file, section_bounds)
	update_cache()
	local data = cache.article_data[file]
	if not data then
		return {}
	end

	local items = {}
	local start_line = section_bounds and section_bounds.start_line or 1
	local end_line = section_bounds and section_bounds.end_line or #data.lines

	-- Headings
	for _, heading in ipairs(data.headings) do
		if heading.lnum >= start_line and heading.lnum <= end_line then
			-- Only include sub-headings if we're in a section
			if not section_bounds or heading.level > (section_bounds.parent_level or 0) then
				local label = "#" .. heading.text
				local detail = heading.is_bold and ("**" .. heading.text .. "**")
					or (string.rep("#", heading.level) .. " " .. heading.text)

				table.insert(items, {
					label = label,
					kind = 15,
					detail = detail,
					sortText = heading.is_bold and ("2_" .. heading.text)
						or ("1_" .. string.format("%02d", heading.level) .. "_" .. heading.text),
					data = { lnum = heading.lnum, level = heading.level },
				})
			end
		end
	end

	-- Bold headings
	for _, heading in ipairs(data.headings) do
		if heading.is_bold and heading.lnum >= start_line and heading.lnum <= end_line then
			table.insert(items, {
				label = "*" .. heading.text,
				kind = 15,
				detail = "**" .. heading.text .. "**",
				sortText = "2_" .. heading.text,
				data = { lnum = heading.lnum, is_bold = true },
			})
		end
	end

	-- Labels
	for _, label_data in ipairs(data.labels) do
		if label_data.lnum >= start_line and label_data.lnum <= end_line then
			table.insert(items, {
				label = ":" .. label_data.text,
				kind = 12,
				detail = label_data.text .. ":",
				sortText = "3_" .. label_data.text,
				data = { lnum = label_data.lnum },
			})
		end
	end

	return items
end

-- Parse the current link context
local function parse_link_context(line, col)
	-- Find the start of the link
	local link_start = nil
	for i = col, 1, -1 do
		if line:sub(i, i) == "[" then
			link_start = i
			break
		elseif line:sub(i, i) == "]" then
			-- We're outside a link
			return nil
		end
	end

	if not link_start then
		return nil
	end

	-- Extract the link content up to cursor
	local link_content = line:sub(link_start + 1, col)

	-- Parse the link
	local parts = {}
	local current_part = ""

	for i = 1, #link_content do
		local char = link_content:sub(i, i)
		if char == "/" then
			table.insert(parts, current_part)
			current_part = ""
		else
			current_part = current_part .. char
		end
	end

	-- Add the final part (what we're currently typing)
	local typing_part = current_part

	return {
		parts = parts,
		typing = typing_part,
		is_new_path = link_content:sub(-1) == "/",
		is_local = link_content:sub(1, 1) == "/",
		full_content = link_content,
	}
end

-- Get section bounds based on parsed components
local function get_section_bounds_for_context(context, file)
	if #context.parts == 0 then
		return nil
	end

	local lines = file and cache.article_data[file] and cache.article_data[file].lines or buffer.get_lines()
	local current_bounds = { start_line = 1, end_line = #lines }

	-- Process each part to narrow down bounds
	for _, part in ipairs(context.parts) do
		if part ~= "" then
			local component = parser.parse_link_component(part)
			if component then
				-- Find the component in current bounds
				local found = false

				if component.type == "heading" then
					-- Search for heading
					for lnum = current_bounds.start_line, current_bounds.end_line do
						local heading = parser.parse_heading(lines[lnum])
						if heading and heading.text:lower() == component.text:lower() then
							current_bounds.start_line = lnum
							current_bounds.end_line = search.get_section_end(lines, lnum, component)
							current_bounds.parent_level = heading.level
							found = true
							break
						end
					end
				elseif component.type == "label" then
					-- Search for label
					for lnum = current_bounds.start_line, current_bounds.end_line do
						if lines[lnum]:match("^" .. parser.escape_pattern(component.text) .. ":") then
							current_bounds.start_line = lnum
							current_bounds.end_line = search.get_section_end(lines, lnum, component)
							found = true
							break
						end
					end
				end

				if not found then
					-- Component not found, no valid bounds
					return nil
				end
			end
		end
	end

	return current_bounds
end

-- Main completion function
function M.get_completions(line, col)
	local context = parse_link_context(line, col)
	if not context then
		return {}
	end

	local items = {}

	-- Initial "[" - show all articles
	if context.full_content == "" or (context.full_content == "/" and context.typing == "") then
		if context.is_local then
			-- Local scope - show current file sections
			items = get_current_file_completions()
		else
			-- Global scope - show articles
			items = get_article_completions()
		end
	elseif context.typing:sub(1, 1) == "@" and #context.parts == 0 then
		-- Tag completion
		items = get_tag_completions()
	elseif context.typing:sub(1, 1) == "#" and #context.parts == 0 and not context.is_local then
		-- Heading in current file (when not in article context)
		items = get_current_file_completions()
	else
		-- Complex context
		local target_file = nil
		local section_bounds = nil

		if context.is_local then
			-- Local scope - current file
			section_bounds = get_section_bounds_for_context(context)
		elseif #context.parts > 0 then
			-- Check if first part is an article
			local first_part = context.parts[1]
			update_cache()

			for _, article in ipairs(cache.articles) do
				if article.name:lower() == first_part:lower() then
					target_file = article.file
					-- Get section bounds within this article
					local article_context = { parts = {} }
					for i = 2, #context.parts do
						table.insert(article_context.parts, context.parts[i])
					end
					section_bounds = get_section_bounds_for_context(article_context, target_file)
					break
				end
			end
		end

		-- Get completions based on context
		if context.is_new_path or context.typing == "" then
			-- Show sections (headings, bold headings, labels)
			if target_file then
				items = get_file_completions(target_file, section_bounds)
			else
				items = get_current_file_completions(section_bounds)
			end
		else
			-- Filter based on what's being typed
			local prefix = context.typing:sub(1, 1)

			if prefix == "#" or prefix == ":" or prefix == "*" or prefix == "-" then
				-- Get appropriate completions
				if target_file then
					items = get_file_completions(target_file, section_bounds)
				else
					items = get_current_file_completions(section_bounds)
				end

				-- Filter by prefix
				local filtered = {}
				for _, item in ipairs(items) do
					if item.label:sub(1, #context.typing) == context.typing then
						table.insert(filtered, item)
					end
				end
				items = filtered
			elseif #context.parts == 0 then
				-- Still completing article name
				items = get_article_completions()
				local filtered = {}
				for _, item in ipairs(items) do
					if item.label:lower():find(context.typing:lower(), 1, true) then
						table.insert(filtered, item)
					end
				end
				items = filtered
			end
		end
	end

	return items
end

-- nvim-cmp source
function M.new()
	local source = {}

	function source:is_available()
		local ft = vim.bo.filetype
		return ft == "zortex" or ft == "markdown" or ft == "text"
	end

	function source:get_debug_name()
		return "zortex"
	end

	function source:get_trigger_characters()
		return { "[", "/", "#", "@", ":", "*", "-", " " }
	end

	function source:complete(params, callback)
		local line = params.context.cursor_line
		local col = params.context.cursor.col

		-- Check if we're in a link context
		local link_context = parse_link_context(line, col - 1)
		if not link_context then
			callback({ items = {}, isIncomplete = false })
			return
		end

		local items = M.get_completions(line, col - 1)

		-- Adjust items for nvim-cmp
		for _, item in ipairs(items) do
			-- Set insert text
			if link_context.is_new_path then
				-- Remove prefix for new path completions
				item.insertText = item.label
			else
				-- For partial typing, complete the rest
				local prefix_len = #link_context.typing
				if prefix_len > 0 and item.label:sub(1, prefix_len) == link_context.typing then
					item.insertText = item.label:sub(prefix_len + 1)
				else
					item.insertText = item.label
				end
			end

			-- Ensure label shows full text for display
			item.labelDetails = { detail = item.detail }
			item.detail = nil
		end

		callback({
			items = items,
			isIncomplete = false,
		})
	end

	return source
end

return M
