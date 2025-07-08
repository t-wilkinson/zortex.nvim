-- lua/zortex/cmp_source.lua - nvim-cmp source for context-aware Zortex completions
local M = {}

local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local search = require("zortex.core.search")

-- Cache for performance
local cache = {
	headings = {},
	tags = {},
	labels = {},
	articles = {},
	last_update = 0,
}

-- Update cache periodically
local function update_cache()
	local now = os.time()
	if now - cache.last_update < 5 then -- Cache for 5 seconds
		return
	end

	cache.last_update = now
	cache.headings = {}
	cache.tags = {}
	cache.labels = {}
	cache.articles = {}

	local files = fs.get_all_note_files()
	for _, file in ipairs(files) do
		local lines = fs.read_lines(file)
		if lines then
			local article_name = nil
			local current_heading = nil

			for lnum, line in ipairs(lines) do
				-- Extract article name
				local title = line:match("^@@(.+)")
				if title then
					article_name = parser.trim(title)
					table.insert(cache.articles, {
						name = article_name,
						file = file,
						lnum = lnum,
					})
				end

				-- Extract headings
				local heading_level = parser.get_heading_level(line)
				if heading_level > 0 then
					local heading_text = line:match("^#+%s*(.+)")
					if heading_text then
						local heading = {
							text = parser.trim(heading_text),
							level = heading_level,
							file = file,
							lnum = lnum,
							article = article_name,
						}
						table.insert(cache.headings, heading)
						current_heading = heading
					end
				end

				-- Extract tags
				local tag = line:match("^@([^@].+)")
				if tag then
					table.insert(cache.tags, {
						text = parser.trim(tag),
						file = file,
						lnum = lnum,
						article = article_name,
					})
				end

				-- Extract labels (under current heading)
				local label = line:match("^([^:]+):%s*")
				if label and not parser.is_task_line(line) and current_heading then
					table.insert(cache.labels, {
						text = parser.trim(label),
						file = file,
						lnum = lnum,
						article = article_name,
						heading = current_heading,
					})
				end
			end
		end
	end
end

-- Parse the current context to understand what type of completion is needed
local function parse_context(line, col)
	local before_cursor = line:sub(1, col)

	-- Check if we're in a link
	local link_start = before_cursor:match("()%[[^%]]*$")
	if not link_start then
		return nil
	end

	local link_content = before_cursor:sub(link_start + 1)

	-- Parse the link content to determine context
	local context = {
		type = nil,
		article = nil,
		heading = nil,
		prefix = "",
	}

	-- Check for local scope
	if link_content:match("^/") then
		context.scope = "local"
		link_content = link_content:sub(2)
	else
		context.scope = "global"
	end

	-- Split by / to analyze components
	local components = {}
	for component in link_content:gmatch("[^/]+") do
		table.insert(components, component)
	end

	-- Analyze the last component for type
	local last_component = components[#components] or ""

	if last_component:match("^#") then
		context.type = "heading"
		context.prefix = last_component:sub(2)

		-- If we have an article component before this
		if #components > 1 and not components[#components - 1]:match("^[#@:]") then
			context.article = components[#components - 1]
		end
	elseif last_component:match("^@") then
		context.type = "tag"
		context.prefix = last_component:sub(2)
	elseif last_component:match("^:") then
		context.type = "label"
		context.prefix = last_component:sub(2)

		-- Check if we have a heading component before this
		for i = #components - 1, 1, -1 do
			if components[i]:match("^#") then
				context.heading = components[i]:sub(2)
				break
			end
		end
	elseif last_component == "" and link_content:match("/$") then
		-- Just typed a slash, determine what to suggest based on previous components
		if #components > 1 then
			local prev = components[#components - 1]
			if prev:match("^#") then
				context.type = "after_heading"
				context.heading = prev:sub(2)
			else
				context.type = "article_content"
				context.article = prev
			end
		else
			context.type = "root"
		end
	else
		-- Default to article search
		context.type = "article"
		context.prefix = last_component
	end

	return context
end

-- Generate completion items based on context
local function get_completion_items(context)
	update_cache()

	local items = {}
	local seen = {} -- Deduplication

	if context.type == "heading" then
		local headings = cache.headings

		-- Filter by article if specified
		if context.article then
			local filtered = {}
			for _, h in ipairs(headings) do
				if h.article and h.article:lower():find(context.article:lower(), 1, true) then
					table.insert(filtered, h)
				end
			end
			headings = filtered
		elseif context.scope == "local" then
			-- Local scope - only current file
			local current_file = vim.fn.expand("%:p")
			local filtered = {}
			for _, h in ipairs(headings) do
				if h.file == current_file then
					table.insert(filtered, h)
				end
			end
			headings = filtered
		end

		-- Create items
		for _, heading in ipairs(headings) do
			if heading.text:lower():find(context.prefix:lower(), 1, true) then
				local key = heading.text
				if not seen[key] then
					seen[key] = true
					table.insert(items, {
						label = "#" .. heading.text,
						kind = 15, -- Text
						detail = string.format(
							"Level %d heading%s",
							heading.level,
							heading.article and (" in " .. heading.article) or ""
						),
						sortText = string.format("%d%s", heading.level, heading.text),
						insertText = "#" .. heading.text,
					})
				end
			end
		end
	elseif context.type == "tag" then
		for _, tag in ipairs(cache.tags) do
			if tag.text:lower():find(context.prefix:lower(), 1, true) then
				local key = tag.text
				if not seen[key] then
					seen[key] = true
					table.insert(items, {
						label = "@" .. tag.text,
						kind = 9, -- Module
						detail = tag.article and ("in " .. tag.article) or nil,
						insertText = "@" .. tag.text,
					})
				end
			end
		end
	elseif context.type == "label" then
		local labels = cache.labels

		-- Filter by heading if specified
		if context.heading then
			local filtered = {}
			for _, l in ipairs(labels) do
				if l.heading and l.heading.text:lower():find(context.heading:lower(), 1, true) then
					table.insert(filtered, l)
				end
			end
			labels = filtered
		end

		for _, label in ipairs(labels) do
			if label.text:lower():find(context.prefix:lower(), 1, true) then
				local key = label.text
				if not seen[key] then
					seen[key] = true
					table.insert(items, {
						label = ":" .. label.text,
						kind = 5, -- Field
						detail = label.heading and ("under " .. label.heading.text) or nil,
						insertText = ":" .. label.text,
					})
				end
			end
		end
	elseif context.type == "article" then
		for _, article in ipairs(cache.articles) do
			if article.name:lower():find(context.prefix:lower(), 1, true) then
				table.insert(items, {
					label = article.name,
					kind = 7, -- File
					detail = "Article",
					insertText = article.name,
				})
			end
		end
	elseif context.type == "after_heading" then
		-- Suggest labels under this heading
		for _, label in ipairs(cache.labels) do
			if label.heading and label.heading.text:lower() == context.heading:lower() then
				table.insert(items, {
					label = ":" .. label.text,
					kind = 5,
					detail = "Label under " .. context.heading,
					insertText = ":" .. label.text,
				})
			end
		end
	elseif context.type == "article_content" then
		-- Suggest headings in this article
		for _, heading in ipairs(cache.headings) do
			if heading.article and heading.article:lower() == context.article:lower() then
				table.insert(items, {
					label = "#" .. heading.text,
					kind = 15,
					detail = "Heading in " .. context.article,
					insertText = "#" .. heading.text,
				})
			end
		end
	end

	return items
end

-- nvim-cmp source
function M.new()
	return setmetatable({}, { __index = M })
end

function M:is_available()
	return vim.bo.filetype == "zortex" or vim.fn.expand("%:e") == "zortex"
end

function M:get_debug_name()
	return "zortex"
end

function M:get_trigger_characters()
	return { "[", "/", "#", "@", ":" }
end

function M:complete(params, callback)
	local line = params.context.cursor_line
	local col = params.context.cursor.col

	local context = parse_context(line, col)
	if not context then
		callback({ items = {}, isIncomplete = false })
		return
	end

	local items = get_completion_items(context)
	callback({ items = items, isIncomplete = false })
end

return M
