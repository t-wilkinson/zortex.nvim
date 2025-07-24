-- features/completion.lua - Context-aware completion for Zortex links
local M = {}

local parser = require("zortex.utils.parser")
local link_resolver = require("zortex.utils.link_resolver")
local fs = require("zortex.utils.filesystem")
local buffer = require("zortex.utils.buffer")

-- Cache for performance
local cache = {
	articles = nil,
	article_data = {},
	last_update = 0,
}

-- Extract all article names/aliases from the start of a file
local function extract_article_names(lines)
	local names = {}

	for i, line in ipairs(lines) do
		local name = parser.extract_article_name(line)
		if name then
			table.insert(names, name)
		else
			-- Stop when we hit a non-article-name line
			break
		end

		-- Safety limit
		if i > 10 then
			break
		end
	end

	return names
end

-- Get structural elements from lines in file order
local function get_structural_elements(lines, start_line, end_line, section_bounds, type_filter)
	local items = {}
	start_line = start_line or 1
	end_line = end_line or #lines

	-- Single pass through lines to maintain order
	for lnum = start_line, end_line do
		local line = lines[lnum]

		-- Check what type of structural element this line is
		local element_type = nil
		local label = nil
		local detail = nil

		-- Check for heading
		local heading = parser.parse_heading(line)
		if heading then
			-- Only include sub-headings if we're in a section
			if not section_bounds or heading.level > (section_bounds.parent_level or 0) then
				element_type = "heading"
				label = "#" .. heading.text
				detail = string.rep("#", heading.level) .. " " .. heading.text
			end

			-- Check for bold heading
		elseif parser.is_bold_heading(line) then
			local text = line:match("^%*%*([^%*]+)%*%*:?$")
			if text then
				element_type = "bold"
				label = "*" .. text
				detail = "**" .. text .. "**"
			end

			-- Check for label
		elseif line:match("^%w[^:]+:$") then
			local label_text = line:match("^([^:]+):")
			if label_text then
				element_type = "label"
				label = ":" .. label_text
				detail = label_text .. ":"
			end
		end

		-- Add element if it matches the filter (or no filter)
		if element_type and label and (not type_filter or type_filter == element_type) then
			table.insert(items, {
				label = label,
				real_kind = element_type == "heading" and 15 or element_type == "label" and 12 or 13,
				detail = detail,
				sortText = string.format("%08d", lnum), -- Preserve line order
				data = {
					lnum = lnum,
					type = element_type,
					level = heading and heading.level or nil,
					is_bold = element_type == "bold",
				},
			})
		end
	end

	return items
end

-- Get completions for current file
local function get_current_file_completions(section_bounds, type_filter)
	local lines = buffer.get_lines()
	return get_structural_elements(
		lines,
		section_bounds and section_bounds.start_line or nil,
		section_bounds and section_bounds.end_line or nil,
		section_bounds,
		type_filter
	)
end

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
			-- Extract all article names/aliases
			local article_names = extract_article_names(lines)

			if #article_names > 0 then
				-- Add entry for each alias
				for _, name in ipairs(article_names) do
					table.insert(cache.articles, {
						name = name,
						file = file,
						type = "article",
						is_alias = name ~= article_names[1],
						primary_name = article_names[1],
					})
				end

				-- Cache file data for quick access
				cache.article_data[file] = {
					lines = lines,
					headings = {},
					tags = {},
					labels = {},
					names = article_names,
				}

				-- Parse the file structure
				for lnum, line in ipairs(lines) do
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
						local heading_text = heading.text
						-- -- Remove attributes from heading
						-- if string.find(heading.text, "@") then
						-- 	heading_text = attributes.strip_project_attributes(heading.text)
						-- end

						table.insert(cache.article_data[file].headings, {
							level = heading.level,
							text = heading_text,
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
	local seen = {}

	for _, article in ipairs(cache.articles) do
		if not seen[article.name] then
			seen[article.name] = true
			local detail = article.is_alias and ("Alias for " .. article.primary_name) or "Article"
			table.insert(items, {
				label = article.name,
				real_kind = 1, -- Text
				detail = detail,
			})
		end
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
					real_kind = 14, -- Keyword
					detail = "Tag",
				})
			end
		end
	end

	return items
end

-- Get completions for a specific file
local function get_file_completions(file, section_bounds, type_filter)
	update_cache()
	local data = cache.article_data[file]
	if not data then
		return {}
	end

	return get_structural_elements(
		data.lines,
		section_bounds and section_bounds.start_line or nil,
		section_bounds and section_bounds.end_line or nil,
		section_bounds,
		type_filter
	)
end

-- Get current section bounds based on cursor position
local function get_cursor_section_bounds()
	local cursor_line, _ = buffer.get_cursor_pos()
	local lines = buffer.get_lines()

	-- Find the nearest heading above cursor
	local parent_heading = nil
	local parent_level = 0
	local parent_lnum = 1

	for i = cursor_line, 1, -1 do
		local heading = parser.parse_heading(lines[i])
		if heading then
			parent_heading = heading
			parent_level = heading.level
			parent_lnum = i
			break
		end

		-- Check for bold heading
		if parser.is_bold_heading(lines[i]) then
			parent_level = 0
			parent_lnum = i
			break
		end
	end

	-- Find where this section ends
	local end_lnum = #lines
	for i = parent_lnum + 1, #lines do
		local heading = parser.parse_heading(lines[i])
		if heading and heading.level <= parent_level then
			end_lnum = i - 1
			break
		elseif parent_level == 0 and parser.is_bold_heading(lines[i]) then
			-- Bold headings end at next bold heading
			end_lnum = i - 1
			break
		end
	end

	return {
		start_line = parent_lnum,
		end_line = end_lnum,
		parent_level = parent_level,
	}
end

-- Get completions for current file with file order preserved
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
							current_bounds.end_line = link_resolver.get_section_end(lines, lnum, component)
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
							current_bounds.end_line = link_resolver.get_section_end(lines, lnum, component)
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

	-- Initial "[" - show all articles or current file sections
	if context.full_content == "" or (context.full_content == "/" and context.typing == "") then
		if context.is_local then
			-- Local scope - show current file sections within cursor's section
			local cursor_bounds = get_cursor_section_bounds()
			items = get_current_file_completions(cursor_bounds)
		else
			-- Global scope - show articles
			items = get_article_completions()
		end
	elseif context.typing:sub(1, 1) == "@" and #context.parts == 0 then
		-- Tag completion
		items = get_tag_completions()
	elseif context.typing:sub(1, 1) == "#" and #context.parts == 0 and not context.is_local then
		-- Heading in current file (when not in article context)
		local cursor_bounds = get_cursor_section_bounds()
		items = get_current_file_completions(cursor_bounds, "heading")
	else
		-- Complex context
		local target_file = nil
		local section_bounds = nil

		if context.is_local then
			-- Local scope - current file
			section_bounds = get_cursor_section_bounds()

			-- Then narrow down based on link parts
			if #context.parts > 0 then
				local narrowed_bounds = get_section_bounds_for_context(context)
				if narrowed_bounds then
					section_bounds.start_line = math.max(section_bounds.start_line, narrowed_bounds.start_line)
					section_bounds.end_line = math.min(section_bounds.end_line, narrowed_bounds.end_line)
					section_bounds.parent_level = narrowed_bounds.parent_level or section_bounds.parent_level
				end
			end
		elseif #context.parts > 0 then
			-- Check if first part is an article
			local first_part = context.parts[1]
			update_cache()

			for _, article in ipairs(cache.articles) do
				if article.name:lower() == first_part:lower() then
					target_file = article.file
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
			-- Show all structural elements in file order
			if target_file then
				items = get_file_completions(target_file, section_bounds)
			else
				items = get_current_file_completions(section_bounds)
			end
		else
			-- Determine type filter based on prefix
			local prefix = context.typing:sub(1, 1)
			local type_filter = nil

			if prefix == "#" then
				type_filter = "heading"
			elseif prefix == ":" then
				type_filter = "label"
			elseif prefix == "*" then
				type_filter = "bold"
			end

			if type_filter then
				-- Get appropriate completions with type filter
				if target_file then
					items = get_file_completions(target_file, section_bounds, type_filter)
				else
					items = get_current_file_completions(section_bounds, type_filter)
				end

				-- Filter by what's being typed
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
