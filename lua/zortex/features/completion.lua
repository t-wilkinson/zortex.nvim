-- features/completion.lua - Link completion built on the link resolver
--
-- While typing a link, the components already typed are resolved with
-- utils/link_resolver (the same rules as following the link), and the
-- completions are what can legitimately come next:
--
--   [|                 article names and aliases (or @tags after "[@")
--   [P/|               sections of the Projects article, plus the names of
--                      notes reached through the P tag ([P/Flipping/...])
--   [P/#1 Programming/|  sections inside "1 Programming"
--   [/|                sections of the current note (local link)
--
-- A typed "#", ":" or "*" narrows completions to headings, labels or bold
-- headings. Every suggestion resolves when inserted.
local M = {}

local parser = require("zortex.utils.parser")

local function notes()
	return require("zortex.core.notes")
end

local function Document()
	return require("zortex.core.document")
end

local function link_resolver()
	return require("zortex.utils.link_resolver")
end

-- LSP CompletionItemKind values
local KIND = { article = 17, tag = 14, heading = 22, bold_heading = 13, label = 10 }
local PREFIX = { heading = "#", label = ":", bold_heading = "*" }
local FILTER = { ["#"] = "heading", [":"] = "label", ["*"] = "bold_heading" }

-- =============================================================================
-- Context
-- =============================================================================

--- The link being typed when the cursor is after `col` bytes of `line`:
--- { parts = {completed components}, typing, typing_col (0-based), is_local }
--- or nil when not inside a zortex link.
function M.link_context(line, col)
	local before = line:sub(1, col)
	local open = before:match(".*()%[")
	if not open then
		return nil
	end
	local inner = before:sub(open + 1)
	if inner:find("]", 1, true) or inner:sub(1, 1) == "^" then
		return nil -- closed link or footnote
	end
	if open > 1 and before:sub(open - 1, open - 1) == "@" then
		return nil -- @[tag search]
	end

	local is_local = inner:sub(1, 1) == "/"
	local body = is_local and inner:sub(2) or inner

	-- Last "/" outside parentheses separates completed parts from the typing
	local depth, last_slash = 0, nil
	for i = 1, #body do
		local c = body:sub(i, i)
		if c == "(" then
			depth = depth + 1
		elseif c == ")" then
			depth = depth - 1
		elseif c == "/" and depth == 0 then
			last_slash = i
		end
	end

	local prefix = last_slash and body:sub(1, last_slash - 1) or ""
	local typing = last_slash and body:sub(last_slash + 1) or body
	local parts = prefix ~= "" and parser.split_link(prefix) or {}
	local typing_col = open + (is_local and 1 or 0) + (last_slash or 0) -- 0-based

	return { parts = parts, typing = typing, typing_col = typing_col, is_local = is_local }
end

-- =============================================================================
-- Candidates
-- =============================================================================

local function article_items(paths)
	local idx = notes().index()
	local items = {}
	for _, path in ipairs(paths or idx.files) do
		local header = idx.headers[path]
		for i, name in ipairs(header and header.names or {}) do
			items[#items + 1] = {
				label = name,
				kind = KIND.article,
				detail = i == 1 and "Article" or ("Alias of " .. header.names[1]),
				sortText = "!" .. name:lower(),
			}
		end
	end
	return items
end

local function tag_items()
	local idx = notes().index()
	local seen, items = {}, {}
	for _, path in ipairs(idx.files) do
		for _, tag in ipairs(idx.headers[path].tags or {}) do
			if not seen[tag:lower()] then
				seen[tag:lower()] = true
				items[#items + 1] = { label = "@" .. tag, kind = KIND.tag, detail = "Tag", sortText = tag:lower() }
			end
		end
	end
	return items
end

-- Sections below `node` (children first, then deeper), as link components
local function section_items(doc, node)
	local items = {}
	local base = node:depth()
	for _, n in ipairs(node:get_descendants()) do
		local prefix = PREFIX[n.type]
		if prefix then
			-- Same shortening as generated links (link_resolver.component_text)
			local text = link_resolver().component_text(n.text)
			items[#items + 1] = {
				label = prefix .. text,
				kind = KIND[n.type],
				detail = n:get_breadcrumb(" › "),
				sortText = string.format("%02d%06d", n:depth() - base, n.start_line),
				section_type = n.type,
			}
		end
	end
	return items
end

-- Completions after resolving the typed components
local function after_parts(ctx, opts)
	local prefix_link = (ctx.is_local and "/" or "") .. table.concat(ctx.parts, "/")
	local resolve_opts = ctx.is_local and { doc = opts.doc } or nil
	local results = link_resolver().resolve(prefix_link, resolve_opts)
	local last = parser.parse_link_component(ctx.parts[#ctx.parts]) or {}

	local items, seen_files = {}, {}
	for _, r in ipairs(results) do
		if not seen_files[r.file] then
			seen_files[r.file] = true
			local node = r.doc:node_starting_at(r.lnum) or r.doc:node_at(r.lnum)
			if node.type == "article" then
				local by_alias = last.type == "article" and r.doc:has_name(last.text)
				if by_alias then
					vim.list_extend(items, section_items(r.doc, node))
				else
					-- Reached through a tag ([P/ or [@P/): the canonical next
					-- component is the note's own name; its sections also resolve.
					if r.doc:name() then
						items[#items + 1] = {
							label = r.doc:name(),
							kind = KIND.article,
							detail = "Article",
							sortText = "!" .. r.doc:name():lower(),
						}
					end
					if last.type == "tag" then
						vim.list_extend(items, section_items(r.doc, node))
					end
				end
			elseif not node:is_root() then
				vim.list_extend(items, section_items(r.doc, node))
			end
		end
	end
	return items
end

--- Completion items for the link at `col` (bytes before the cursor).
---@param opts { bufnr?: integer, doc?: table }?
---@return table[] items { label, kind, detail, sortText }, table? ctx
function M.get_completions(line, col, opts)
	opts = opts or {}
	local ctx = M.link_context(line, col)
	if not ctx then
		return {}, nil
	end
	opts.doc = opts.doc or Document().from_buffer(opts.bufnr or 0)

	local items
	local first_char = ctx.typing:sub(1, 1)
	if #ctx.parts == 0 then
		if ctx.is_local then
			items = opts.doc and section_items(opts.doc, opts.doc.tree) or {}
		elseif first_char == "@" then
			items = tag_items()
		elseif FILTER[first_char] then
			-- "[#..." searches every note; suggest sections of the current one
			items = opts.doc and section_items(opts.doc, opts.doc.tree) or {}
		else
			items = article_items()
		end
	else
		items = after_parts(ctx, opts)
	end

	-- A typed "#", ":" or "*" narrows to that section type
	local wanted = FILTER[first_char]
	if wanted then
		items = vim.tbl_filter(function(item)
			return item.section_type == wanted
		end, items)
	end

	-- Articles first, then sections by depth and position (cmp uses sortText too)
	table.sort(items, function(a, b)
		return (a.sortText or a.label) < (b.sortText or b.label)
	end)

	-- One item per label
	local seen, out = {}, {}
	for _, item in ipairs(items) do
		if not seen[item.label] then
			seen[item.label] = true
			out[#out + 1] = item
		end
	end
	return out, ctx
end

-- =============================================================================
-- nvim-cmp source
-- =============================================================================

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
		return { "[", "/", "#", "@", ":", "*" }
	end

	function source:get_keyword_pattern()
		-- Link components may contain spaces, dots and dashes
		return [[\%([^\[\]/]\)*]]
	end

	function source:complete(params, callback)
		local line = params.context.cursor_before_line
		local row = params.context.cursor.row - 1
		local items, ctx = M.get_completions(line, #line, { bufnr = params.context.bufnr })
		if not ctx then
			callback({ items = {}, isIncomplete = false })
			return
		end
		for _, item in ipairs(items) do
			item.filterText = item.label
			item.textEdit = {
				newText = item.label,
				range = {
					start = { line = row, character = ctx.typing_col },
					["end"] = { line = row, character = #line },
				},
			}
			item.section_type = nil
		end
		callback({ items = items, isIncomplete = false })
	end

	return source
end

-- Backwards-compatible name
M.parse_link_context = M.link_context

return M
