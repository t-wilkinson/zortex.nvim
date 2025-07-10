-- blink_source.lua - blink.cmp source for context‑aware Zortex link completions

--- @module 'zortex.blink_source'
--- @class blink.cmp.Source
local source = {}

-------------------------------------------------------------------------------
-- Dependencies
-------------------------------------------------------------------------------
local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")

-------------------------------------------------------------------------------
-- Simple in‑memory cache for headings/tags/etc. (copied from nvim‑cmp source)
-------------------------------------------------------------------------------
local cache = {
	headings = {},
	tags = {},
	labels = {},
	articles = {},
	last_update = 0,
}

local function update_cache()
	local now = os.time()
	if now - cache.last_update < 5 then -- refresh every 5 s
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
		if not lines then
			goto continue
		end

		local article_name ---@type string|nil
		local current_heading ---@type table|nil

		for lnum, line in ipairs(lines) do
			-- @@ Article title
			local title = line:match("^@@(.+)")
			if title then
				article_name = parser.trim(title)
				table.insert(cache.articles, { name = article_name, file = file, lnum = lnum })
			end

			-- # Headings
			local heading_level = parser.get_heading_level(line)
			if heading_level > 0 then
				local heading_text = line:match("^#+%s*(.+)")
				if heading_text then
					local heading_obj = {
						text = parser.trim(heading_text),
						level = heading_level,
						file = file,
						lnum = lnum,
						article = article_name,
					}
					table.insert(cache.headings, heading_obj)
					current_heading = heading_obj
				end
			end

			-- @tags / aliases (single leading @, not @@)
			local tag = line:match("^@([^@].+)")
			if tag then
				table.insert(cache.tags, {
					text = parser.trim(tag),
					file = file,
					lnum = lnum,
					article = article_name,
				})
			end

			-- labels (word: …) under the current heading
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
		::continue::
	end
end

-------------------------------------------------------------------------------
-- Context parser – figures out what kind of thing the user is completing
-------------------------------------------------------------------------------
---@param line string current line text
---@param col  integer (1‑indexed) cursor column
---@return table|nil context
local function parse_context(line, col)
	local before_cursor = line:sub(1, col)

	-- Inside square bracket «[ …» ?
	local link_start = before_cursor:match("()%[[^%]]*$")
	if not link_start then
		return nil
	end

	local link_content = before_cursor:sub(link_start + 1)
	local context = {
		scope = "global", -- "local" when link starts with '/'
		type = nil, -- article|heading|tag|label|after_heading|article_content|root
		article = nil,
		heading = nil,
		prefix = "",
	}

	-- Local scope (starts with '/')
	if link_content:match("^") then
	elseif link_content:match("^/") then
		context.scope = "local"
		link_content = link_content:sub(2)
	end

	-- Split content by '/'
	local components = {}
	for comp in link_content:gmatch("[^/]+") do
		table.insert(components, comp)
	end
	local last = components[#components] or ""

	if last:match("^#") then -- heading
		context.type = "heading"
		context.prefix = last:sub(2)
		if #components > 1 and not components[#components - 1]:match("^[#@:]") then
			context.article = components[#components - 1]
		end
	elseif last:match("^@") then
		context.type = "tag"
		context.prefix = last:sub(2)
	elseif last:match("^:") then
		context.type = "label"
		context.prefix = last:sub(2)
		-- heading might be component before last
		for i = #components - 1, 1, -1 do
			if components[i]:match("^#") then
				context.heading = components[i]:sub(2)
				break
			end
		end
	elseif last == "" and link_content:sub(-1) == "/" then
		-- typed a trailing slash
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
		context.type = "article"
		context.prefix = last
	end

	return context
end

-------------------------------------------------------------------------------
-- Create LSP CompletionItems based on the context / cache
-------------------------------------------------------------------------------
local function get_completion_items(context)
	update_cache()

	local items = {}
	local seen = {}

	local function insert(obj)
		if not seen[obj.label] then
			table.insert(items, obj)
			seen[obj.label] = true
		end
	end

	if context.type == "heading" then
		local headings = cache.headings

		-- filter for article
		if context.article then
			local filtered = {}
			for _, h in ipairs(headings) do
				if h.article and h.article:lower():find(context.article:lower(), 1, true) then
					table.insert(filtered, h)
				end
			end
			headings = filtered
		elseif context.scope == "local" then
			local file = vim.fn.expand("%:p")
			local filtered = {}
			for _, h in ipairs(headings) do
				if h.file == file then
					table.insert(filtered, h)
				end
			end
			headings = filtered
		end

		for _, h in ipairs(headings) do
			if h.text:lower():find(context.prefix:lower(), 1, true) then
				insert({
					label = "#" .. h.text,
					kind = require("blink.cmp.types").CompletionItemKind.Text,
					detail = string.format("Level %d heading%s", h.level, h.article and (" in " .. h.article) or ""),
					sortText = string.format("%d%s", h.level, h.text),
					insertText = "#" .. h.text,
				})
			end
		end
	elseif context.type == "tag" then
		for _, t in ipairs(cache.tags) do
			if t.text:lower():find(context.prefix:lower(), 1, true) then
				insert({
					label = "@" .. t.text,
					kind = require("blink.cmp.types").CompletionItemKind.Module,
					detail = t.article and ("in " .. t.article) or nil,
					insertText = "@" .. t.text,
				})
			end
		end
	elseif context.type == "label" then
		local labels = cache.labels
		if context.heading then
			local filtered = {}
			for _, l in ipairs(labels) do
				if l.heading and l.heading.text:lower():find(context.heading:lower(), 1, true) then
					table.insert(filtered, l)
				end
			end
			labels = filtered
		end
		for _, l in ipairs(labels) do
			if l.text:lower():find(context.prefix:lower(), 1, true) then
				insert({
					label = ":" .. l.text,
					kind = require("blink.cmp.types").CompletionItemKind.Field,
					detail = l.heading and ("under " .. l.heading.text) or nil,
					insertText = ":" .. l.text,
				})
			end
		end
	elseif context.type == "article" then
		for _, a in ipairs(cache.articles) do
			if a.name:lower():find(context.prefix:lower(), 1, true) then
				insert({
					label = a.name,
					kind = require("blink.cmp.types").CompletionItemKind.File,
					detail = "Article",
					insertText = a.name,
				})
			end
		end
	elseif context.type == "after_heading" then
		for _, l in ipairs(cache.labels) do
			if l.heading and l.heading.text:lower() == context.heading:lower() then
				insert({
					label = ":" .. l.text,
					kind = require("blink.cmp.types").CompletionItemKind.Field,
					detail = "Label under " .. context.heading,
					insertText = ":" .. l.text,
				})
			end
		end
	elseif context.type == "article_content" then
		for _, h in ipairs(cache.headings) do
			if h.article and h.article:lower() == context.article:lower() then
				insert({
					label = "#" .. h.text,
					kind = require("blink.cmp.types").CompletionItemKind.Text,
					detail = "Heading in " .. context.article,
					insertText = "#" .. h.text,
				})
			end
		end
	end

	return items
end

-------------------------------------------------------------------------------
-- blink.cmp source methods
-------------------------------------------------------------------------------

---Create new instance
---@param opts table|nil user‑supplied opts
function source.new(opts)
	opts = opts or {}
	local self = setmetatable({ opts = opts }, { __index = source })
	return self
end

---Enable only for Zortex filetype(s)
function source:enabled()
	return vim.bo.filetype == "zortex" or vim.fn.expand("%:e") == "zortex"
end

---Trigger characters (non‑alphanumeric) that request fresh completions
function source:get_trigger_characters()
	return { "[", "/", "#", "@", ":" }
end

---Main completion entry point
---@param ctx table blink context (see docs)
---@param callback fun(res:{items:table,is_incomplete_backward:boolean,is_incomplete_forward:boolean})
function source:get_completions(ctx, callback)
	local line = ctx.line
	local col = ctx.col
	local context = parse_context(line, col)
	if not context then
		callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = false })
		return function() end -- cancel fn
	end

	local items = get_completion_items(context)
	callback({ items = items, is_incomplete_backward = false, is_incomplete_forward = false })
	return function() end -- synchronous, nothing to cancel
end

return source
