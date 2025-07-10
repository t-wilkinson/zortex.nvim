-- cmp_gpt.lua — nvim‑cmp source for Zortex context‑aware link completion
-- Place this file somewhere in your `runtimepath`, e.g.  `lua/plugins/cmp_zortex.lua`
-- It exposes a completion source called “zortex” that understands the Zortex
-- link grammar defined in Schema.md and surfaces context‑aware suggestions:
--   [                → all article names / aliases
--   [@              → global tags (@Tag)
--   [# / [/#        → headings in current buffer
--   [Article/#      → headings from the named article (first match)
--   [/#Heading/:    → labels inside the named heading in the current buffer
--   [*              → inline highlights (bold/italic) in scope (TODO)
--   [-              → list items in scope (TODO)
--
-- The source re‑uses Zortex’s existing parser & search modules so it stays
-- perfectly in‑sync with your note model.
--
-- ───────────────────────────────────────────────────────────────────────────
local cmp = require("cmp")
local parser = require("zortex.core.parser")
local buffer = require("zortex.core.buffer")
local fs = require("zortex.core.filesystem")
local search = require("zortex.core.search")
local Index = require("zortex.modules.search_managers").IndexManager

local Source = {}
Source.__index = Source

function Source.new()
	return setmetatable({}, Source)
end

function Source:get_debug_name()
	return "zortex"
end

function Source:is_available()
	return true -- Always available inside Neovim.
end

function Source:get_trigger_characters()
	return { "[", "#", "@", "/", ":" }
end

-- Very permissive – we let the “[” anchor the completion.  cmp will search
-- backwards from cursor to the first non‑matching char.
function Source:get_keyword_pattern()
	return "\\[[^\\]]*" -- everything after last '[' that has not been closed
end

-- Utility: de‑duplicate array keeping insertion order
local function dedup(list)
	local seen, out = {}, {}
	for _, v in ipairs(list) do
		if not seen[v] then
			seen[v] = true
			out[#out + 1] = v
		end
	end
	return out
end

-- Fetch all primary article names ("@@Title") + aliases for global suggestions
local function collect_all_articles()
	local titles = {}
	for path, data in pairs(Index.cache) do
		if data and data.lines then
			for i = 1, math.min(#data.lines, 20) do
				local line = data.lines[i]
				if line:match("^@@") then
					local title = parser.trim(line:sub(3))
					titles[#titles + 1] = title
				elseif line:match("^@[^@]") then -- tags/aliases; stop on first body text
				-- continue scanning
				elseif line:match("%S") then
					break
				end
			end
		end
	end
	return dedup(titles)
end

-- Tags across the vault
local function collect_all_tags()
	local tags = {}
	for path, data in pairs(Index.cache) do
		if data and data.metadata then
			for _, tag in ipairs(data.metadata.tags or {}) do
				tags[#tags + 1] = tag
			end
		end
	end
	return dedup(tags)
end

-- Headings in current buffer
local function collect_current_headings()
	local items = {}
	for _, h in ipairs(buffer.get_all_headings(0)) do
		items[#items + 1] = string.rep("#", h.level) .. " " .. h.text
	end
	return items
end

-- Headings from a different article (first matching file only)
local function collect_headings_from_article(article)
	local files = search.find_article_files(article)
	if #files == 0 then
		return {}
	end
	local lines = fs.read_lines(files[1]) or {}
	local headings = {}
	for _, line in ipairs(lines) do
		local h = parser.parse_heading(line)
		if h then
			headings[#headings + 1] = string.rep("#", h.level) .. " " .. h.text
		end
	end
	return headings
end

-- Labels under a given heading in current buffer
local function collect_labels_in_heading(heading_text)
	local lines = buffer.get_lines(0)
	local labels = {}
	local start_idx
	for i, l in ipairs(lines) do
		local h = parser.parse_heading(l)
		if h and h.text == heading_text then
			start_idx = i
			break
		end
	end
	if not start_idx then
		return labels
	end
	local end_idx = parser.find_section_end(lines, start_idx, parser.SectionType.HEADING)
	for i = start_idx + 1, end_idx do
		local lbl = lines[i]:match("^(%w[^:]+):")
		if lbl then
			labels[#labels + 1] = lbl
		end
	end
	return labels
end

-- MAIN COMPLETION ENTRY -----------------------------------------------------
function Source:complete(params, callback)
	local line, col = params.context.line, params.context.cursor.col
	local prefix = line:sub(1, col)
	local bracket = prefix:match("()%[[^%]]*$")
	if not bracket then
		return callback()
	end -- no open bracket

	local inside = prefix:sub(bracket + 1) -- text after the last '['
	local proposals = {}

	-- Case 1: just "[" → articles
	if inside == "" then
		for _, title in ipairs(collect_all_articles()) do
			table.insert(proposals, { label = title, insertText = title, kind = cmp.lsp.CompletionItemKind.File })
		end

	-- Case 2: "[@" → tags
	elseif inside:sub(1, 1) == "@" then
		local partial = inside:sub(2):lower()
		for _, tag in ipairs(collect_all_tags()) do
			if tag:lower():find(partial, 1, true) then
				table.insert(
					proposals,
					{ label = "@" .. tag, insertText = "@" .. tag, kind = cmp.lsp.CompletionItemKind.Keyword }
				)
			end
		end

	-- Case 3: "[#" or "[/#" → headings in current buffer
	elseif inside == "#" or inside == "/#" or inside:match("^/#") then
		for _, head in ipairs(collect_current_headings()) do
			table.insert(
				proposals,
				{ label = head, insertText = head:gsub("^#+%s*", ""), kind = cmp.lsp.CompletionItemKind.Text }
			)
		end

	-- Case 4: "<Article>/#" → headings from that article
	elseif inside:match("^.-/#$") then
		local art = inside:match("^(.-)/#$")
		for _, head in ipairs(collect_headings_from_article(parser.trim(art))) do
			table.insert(
				proposals,
				{ label = head, insertText = head:gsub("^#+%s*", ""), kind = cmp.lsp.CompletionItemKind.Text }
			)
		end

	-- Case 5: "[/#Heading/:" → labels under that heading in current buffer
	elseif inside:match("^/#.-/:$") then
		local heading = inside:match("^/#(.-)/:$")
		for _, lbl in ipairs(collect_labels_in_heading(heading)) do
			table.insert(
				proposals,
				{ label = lbl .. ":", insertText = lbl .. ":", kind = cmp.lsp.CompletionItemKind.Snippet }
			)
		end
	end

	callback({ items = proposals, isIncomplete = false })
end

cmp.register_source("zortex", Source.new())

-- ───────────────────────────────────────────────────────────────────────────
-- LAZYVIM SETUP
-- Add the following *once* in your LazyVim → plugins spec (e.g.  `~/.config/nvim/lua/plugins/cmp.lua`):
--
-- ```lua
-- return {
--   {
--     "hrsh7th/nvim-cmp",
--     dependencies = {
--       "Saghen/blink.cmp",   -- keep using Blink’s improvements
--       { dir = "~/.config/nvim/lua/plugins" }, -- path where cmp_zortex.lua lives
--     },
--     opts = function(_, opts)
--       opts.sources = opts.sources or {}
--       table.insert(opts.sources, { name = "zortex" })
--     end,
--   },
-- }
-- ```
--
-- After saving, run `:Lazy sync`, restart Neovim, and start typing `[` inside a
-- Zortex file – you should see the dynamic suggestions described above.
