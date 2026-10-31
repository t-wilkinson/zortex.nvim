-- features/completion.lua - Link completion built on the link resolver
--
-- While typing a link, the components already typed are resolved with
-- core/link (the same rules as following the link), and the
-- completions are what can legitimately come next:
--
--   [|                 article names and aliases (or @tags after "[@")
--   [P/|               sections of the Projects article, plus the names of
--                      notes reached through the P tag ([P/Flipping/...])
--   [P/#1 Programming/|  sections inside "1 Programming"
--   [/|                sections of the current note (local link)
--
-- A typed "#", ":" or "*" narrows completions to headings, labels or bold
-- headings; a typed ">" offers the links in range ([R/#Rust/>The Rust Book]).
-- Every suggestion resolves when inserted.
--
-- Tags: after a bare "@" (starting a word) and inside @[...], the tags used
-- on notes' lines, most used first, with how many lines use each.
local M = {}

local function notes()
	return require("zortex.core.notes")
end

local function Document()
	return require("zortex.core.document")
end

local function link_mod()
	return require("zortex.core.link")
end

-- LSP CompletionItemKind values
local KIND = { article = 17, tag = 14, heading = 22, bold_heading = 13, label = 10, follow = 18, line_tag = 21, item = 12, attribute = 5 }
local PREFIX = { heading = "#", label = ":", bold_heading = "*" }
local FILTER = { ["#"] = "heading", [":"] = "label", ["*"] = "bold_heading", ["-"] = "item" }

-- =============================================================================
-- Context
-- =============================================================================

--- The link being typed when the cursor is after `col` bytes of `line`:
--- { parts = {completed components}, typing, typing_col (0-based), is_local }
--- or nil when not inside a zortex link.
function M.link_context(line, col)
	local before = line:sub(1, col)
	-- [text](P/#… : the definition after "](" completes like one in brackets
	local paren = before:match(".*%[[^%]]+%]%(()[^%)]*$")
	if paren then
		before = before:sub(1, paren - 2) .. "[" .. before:sub(paren)
	end
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
	local parts = prefix ~= "" and link_mod().split(prefix) or {}
	local typing_col = open + (is_local and 1 or 0) + (last_slash or 0) -- 0-based

	return { parts = parts, typing = typing, typing_col = typing_col, is_local = is_local }
end

-- =============================================================================
-- Candidates
-- =============================================================================

local reachable_sections -- defined below

-- the notes a link written in `doc` can reach (notes.root_of)
local function index_for(doc)
	return notes().index({ root = doc and doc.filepath and notes().root_of(doc.filepath) or nil, documents = true })
end

local function article_items(paths, doc)
	local idx = index_for(doc)
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

local function tag_items(doc)
	local idx = index_for(doc)
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
			-- Same shortening as generated links (core/link component_text)
			local text = link_mod().component_text(n.text)
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

-- List items in `node`'s range as "-" components: its own items first (not
-- inside a sub-section), then deeper ones, each in document order
local function item_items(doc, node)
	local items = {}
	local last = node:is_root() and #doc.lines or node.end_line
	for lnum = node:is_root() and 1 or node.start_line + 1, last do
		local d = doc.syntax.lines[lnum]
		if d and d.item then
			local comp = link_mod().item_component(doc.lines[lnum])
			if comp and comp ~= "-" then
				local own = doc:node_at(lnum) == node
				items[#items + 1] = {
					label = comp,
					kind = KIND.item,
					detail = vim.trim(doc.lines[lnum]),
					sortText = string.format("%s%06d", own and "0" or "1", lnum),
					section_type = "item",
				}
			end
		end
	end
	return items
end

-- Sections of `r.doc` (reached through a tag) that "[Name/<label>" would
-- land on: no candidate before it in `results` has a match for the label.
-- They sort after the main article's sections and show their note.
reachable_sections = function(r, results)
	local earlier = {}
	for _, other in ipairs(results) do
		if other == r then
			break
		end
		earlier[#earlier + 1] = other.doc
	end
	local node = r.doc:node_starting_at(r.lnum) or r.doc:node_at(r.lnum)
	local out = {}
	for _, item in ipairs(section_items(r.doc, node)) do
		local comp = link_mod().parse_component(item.label)
		local shadowed = false
		for _, doc in ipairs(earlier) do
			if comp and #link_mod().search_lines(doc.lines, comp) > 0 then
				shadowed = true
				break
			end
		end
		if not shadowed then
			item.sortText = "~" .. item.sortText
			out[#out + 1] = item
		end
	end
	return out
end

-- Completions after resolving the typed components
local function after_parts(ctx, opts)
	local prefix_link = (ctx.is_local and "/" or "") .. table.concat(ctx.parts, "/")
	local resolve_opts = ctx.is_local and { doc = opts.doc } or nil
	local results = link_mod().resolve(prefix_link, resolve_opts)
	local last = link_mod().parse_component(ctx.parts[#ctx.parts]) or {}

	-- Every matched section counts: "[P/#1/" matches "1 Programming" and
	-- "1 Personal" in the same note, and both have children to offer.
	local items, seen = {}, {}
	for _, r in ipairs(results) do
		local node = r.doc:node_starting_at(r.lnum) or r.doc:node_at(r.lnum)
		local key = r.file .. ":" .. tostring(node.start_line)
		if not seen[key] then
			seen[key] = true
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
					else
						-- [P/#Subaru]: a heading of a standalone @P note is
						-- reached directly when no earlier candidate (the
						-- Projects note, earlier @P notes) has a match.
						vim.list_extend(items, reachable_sections(r, results))
					end
				end
			elseif not node:is_root() then
				vim.list_extend(items, section_items(r.doc, node))
			end
			if opts.items and not node:is_root() then
				vim.list_extend(items, item_items(r.doc, node))
			end
		end
	end
	return items
end

-- Links a ">" component can follow in the range the typed parts reach (the
-- current note when there are none)
local function follow_items(ctx, opts)
	local base = (ctx.is_local or #ctx.parts == 0) and "/" or ""
	if #ctx.parts > 0 then
		base = base .. table.concat(ctx.parts, "/") .. "/"
	end
	local resolve_opts = (ctx.is_local or #ctx.parts == 0) and { doc = opts.doc } or nil
	if resolve_opts and not opts.doc then
		return {}
	end
	local items = {}
	for i, r in ipairs(link_mod().resolve(base .. ">", resolve_opts)) do
		local text = link_mod().follow_text(r.text, r.target)
		if text ~= "" then
			local t = r.target
			items[#items + 1] = {
				label = ">" .. text,
				kind = KIND.follow,
				detail = t.url or t.path or t.definition,
				sortText = string.format("%06d", i),
			}
		end
	end
	return items
end

-- =============================================================================
-- Tags: @rust, @[rust async, rl]
-- =============================================================================

--- The tag being typed before `col`: after a bare "@" that starts a word, or
--- a word inside @[...] (after its last "/", "," or space). Returns
--- { typing, typing_col (0-based), tag = "bare"|"search" } or nil.
function M.tag_context(line, col)
	local before = line:sub(1, col)
	local open = before:match(".*()@%[")
	if open and not before:sub(open + 2):find("]", 1, true) then
		local typing = before:match("([^/,%s]*)$")
		return { typing = typing, typing_col = col - #typing, tag = "search" }
	end
	local at, word = before:match("()@([%w_%-]*)$")
	if at and (at == 1 or before:sub(at - 1, at - 1):match("%s")) then
		return { typing = "@" .. word, typing_col = at - 1, tag = "bare" }
	end
	return nil
end

-- The attributes (attributes_help) for a bare "@…": "@due(" with what it
-- means and how it is written, after the tags
local function attribute_items()
	local items = {}
	for i, e in ipairs(require("zortex.attributes_help").list) do
		if not e.pseudo then
			items[#items + 1] = {
				label = "@" .. e.key .. (e.insert:sub(-1) == "(" and "(…)" or ""),
				filterText = "@" .. e.key,
				kind = KIND.attribute,
				detail = e.formats[1] .. " · " .. e.where,
				documentation = require("zortex.attributes_help").documentation(e),
				area_value = e.insert, -- what is inserted (lsp_items)
				sortText = string.format("9%05d", i),
				data = { zortex_order = 100000 + i },
			}
		end
	end
	return items
end
M._attribute_items = attribute_items

local function line_tag_items(ctx)
	local items = {}
	-- in a tag search, "is:" words narrow it to a kind of line
	if ctx.tag == "search" and ctx.typing:sub(1, 2) == "is" then
		for i, kind in ipairs(link_mod().IS_KINDS) do
			items[#items + 1] = {
				label = "is:" .. kind,
				kind = KIND.line_tag,
				detail = "kind of line",
				sortText = string.format("%06d", i),
				data = { zortex_order = i },
			}
		end
		return items
	end
	for i, t in ipairs(require("zortex.core.link_index").line_tags()) do
		local text = ctx.tag == "bare" and ("@" .. t.tag) or t.tag
		items[#items + 1] = {
			label = text,
			kind = KIND.line_tag,
			detail = t.count == 1 and "1 line" or (t.count .. " lines"),
			sortText = string.format("%06d", i),
			data = { zortex_order = i }, -- see order_comparator
		}
	end
	if ctx.tag == "bare" then
		-- sizes ("@sm", with what each is worth), then the other attributes
		vim.list_extend(items, M._size_items(ctx.line or "", ctx.opts, true))
		vim.list_extend(items, attribute_items())
	end
	return items
end
M._line_tag_items = line_tag_items

-- =============================================================================
-- Area attributes: @a(...) / @area(...)
-- =============================================================================

--- The size being typed inside @size( before `col`: { typing,
--- typing_col (0-based), size = true } or nil.
function M.size_context(line, col)
	local before = line:sub(1, col)
	local open = before:match(".*()@size%(")
	if not open then
		return nil
	end
	local typing = before:sub(open + 6)
	if typing:find("[)%s]") then
		return nil
	end
	return { typing = typing, typing_col = col - #typing, size = true }
end

-- The sizes for the line's kind (a heading: a project's, in the OKR note an
-- objective's; else a task's), each with what it is worth: "30m · 5 XP".
-- bare: "@sm" shortcuts after a bare "@" (not for objectives' sizes).
local function size_items(line, opts, bare)
	local calc = require("zortex.services.xp.calculator")
	local hint = require("zortex.features.size_hint")
	local path = opts and opts.bufnr and vim.api.nvim_buf_get_name(opts.bufnr) or nil
	local kind = hint.kind_of(line, path)
	local attrs = require("zortex.utils.attributes").parse_attributes(line, require("zortex.utils.attributes").schemas.project)
	local items = {}
	for i, size in ipairs(calc.size_names(kind)) do
		if not bare or require("zortex.utils.attributes").is_size(size) then
			local text = calc.size_hint(kind, size, attrs)
			items[#items + 1] = {
				label = (bare and "@" or "") .. size,
				kind = KIND.attribute,
				detail = text,
				documentation = string.format("%s size %s: %s (xp.sizes.%s)", kind, size, text, kind),
				sortText = string.format("%s%04d", bare and "8" or "0", i),
				data = { zortex_order = (bare and 50000 or 0) + i },
			}
		end
	end
	return items
end
M._size_items = size_items

--- The area value being typed inside @a( / @area( before `col`:
--- { typing, typing_col (0-based) } or nil.
function M.area_context(line, col)
	local before = line:sub(1, col)
	local a, area = before:match(".*()@a%("), before:match(".*()@area%(")
	local open = math.max(a or 0, area or 0)
	if open == 0 then
		return nil
	end
	if open > 1 and not before:sub(open - 1, open - 1):match("%s") then
		return nil -- an email address, not an attribute
	end
	local rest = before:sub(open)
	local inside = rest:match("^@a%((.*)$") or rest:match("^@area%((.*)$")
	if not inside or inside:find(")", 1, true) then
		return nil
	end
	local typing = inside:match("([^,]*)$"):gsub("^%s+", "")
	return { typing = typing, typing_col = col - #typing, area = true }
end

local area_cache = { signature = nil, items = nil }

-- The shortest @a(...) value that resolves to `area`, or nil.
local function area_value(area)
	local attributes = require("zortex.utils.attributes")
	local areas = require("zortex.services.areas")
	local function resolves(v)
		local parsed = attributes.attribute_parsers.area(v)
		local def = parsed and parsed[1] and parsed[1].definition
		local hit = def and areas.resolve(def)
		return hit and hit.key == area.key
	end
	local candidates = {}
	local number = area.name:match("^(%d[%d%.]*)%s") or area.name:match("^(%d[%d%.]*)$")
	if number then
		candidates[#candidates + 1] = number
	end
	candidates[#candidates + 1] = link_mod().component_text(area.name)
	local parent = area.parent
	if area.kind == "label" and parent and not parent:is_root() then
		local pnum = parent.name:match("^(%d[%d%.]*)%s")
		candidates[#candidates + 1] = (pnum or link_mod().component_text(parent.name)) .. "/" .. link_mod().component_text(area.name)
	end
	local parts = link_mod().node_components(area.doc, area.node)
	table.remove(parts, 1) -- the article
	if #parts >= 3 then
		candidates[#candidates + 1] = table.concat(parts, "/")
	end
	for _, v in ipairs(candidates) do
		if v ~= "" and resolves(v) then
			return v
		end
	end
	return nil
end

-- Every area as an item: label indented by depth (the tree), inserting the
-- shortest value that resolves to it. Cached until the areas note changes.
local function area_items()
	local areas = require("zortex.services.areas")
	local sig = areas.signature()
	if area_cache.signature == sig and area_cache.items then
		return vim.deepcopy(area_cache.items)
	end
	local items = {}
	for i, area in ipairs(areas.all({ include_roots = false })) do
		local value = area_value(area)
		if value then
			items[#items + 1] = {
				label = string.rep("  ", math.max(0, area.depth - 1)) .. area.name,
				insertText = value,
				filterText = value .. " " .. area.name,
				kind = 19, -- Folder
				detail = value,
				documentation = area:breadcrumb(" › "),
				sortText = string.format("%06d", i),
				area_value = value,
				data = { zortex_order = i }, -- see order_comparator
			}
		end
	end
	area_cache.signature, area_cache.items = sig, items
	return vim.deepcopy(items)
end
M._area_items = area_items

-- =============================================================================
-- Project attributes: @project(...) (services/triage)
-- =============================================================================

--- The project value being typed inside @project( before `col`:
--- { typing, typing_col (0-based), project = true } or nil.
function M.project_context(line, col)
	local before = line:sub(1, col)
	local open = before:match(".*()@project%(")
	if not open or (open > 1 and not before:sub(open - 1, open - 1):match("%s")) then
		return nil
	end
	local inside = before:sub(open + #"@project(")
	if inside:find(")", 1, true) then
		return nil
	end
	local typing = inside:gsub("^%s+", "")
	return { typing = typing, typing_col = col - #typing, project = true }
end

-- Every open project as an item, inserting the shortest @project value that
-- resolves to it ("1.4", its name, or its link)
local function project_items()
	local triage = require("zortex.services.triage")
	local items = {}
	local all = require("zortex.services.projects").all({
		filter = function(p)
			return not p:is_root() and not p:is_done()
		end,
	})
	for i, p in ipairs(all) do
		local function resolves(v)
			local r = link_mod().resolve_first(triage.link(v))
			return r and vim.fn.fnamemodify(r.file, ":p") == vim.fn.fnamemodify(p.file, ":p") and r.lnum == p.lnum
		end
		local candidates = {}
		local number = p.name:match("^(%d[%d%.]*)%s") or p.name:match("^(%d[%d%.]*)$")
		if number then
			candidates[#candidates + 1] = number
		end
		candidates[#candidates + 1] = link_mod().component_text(p.name)
		candidates[#candidates + 1] = p.link and p.link:sub(2, -2)
		for _, v in ipairs(candidates) do
			if v and v ~= "" and resolves(v) then
				items[#items + 1] = {
					label = string.rep("  ", math.max(0, (p.depth or 1) - 1)) .. p.name,
					filterText = v .. " " .. p.name,
					kind = 19, -- Folder
					detail = v,
					documentation = p.link,
					sortText = string.format("%06d", i),
					area_value = v,
					data = { zortex_order = i },
				}
				break
			end
		end
	end
	return items
end
M._project_items = project_items

--- Completion items for the link at `col` (bytes before the cursor).
---@param opts { bufnr?: integer, doc?: table, lnum?: integer }? lnum: the line, for "[./" links
---@return table[] items { label, kind, detail, sortText }, table? ctx
function M.get_completions(line, col, opts)
	opts = opts or {}
	local sctx = M.size_context(line, col)
	if sctx then
		return size_items(line, opts), sctx
	end
	local actx = M.area_context(line, col)
	if actx then
		return area_items(), actx
	end
	local pctx = M.project_context(line, col)
	if pctx then
		return project_items(), pctx
	end
	local ctx = M.link_context(line, col)
	if not ctx then
		local tctx = M.tag_context(line, col)
		if tctx then
			tctx.line, tctx.opts = line, opts
			local items = line_tag_items(tctx)
			tctx.line, tctx.opts = nil, nil
			return items, tctx
		end
		return {}, nil
	end
	opts.doc = opts.doc or Document().from_buffer(opts.bufnr or 0)

	local items
	local first_char = ctx.typing:sub(1, 1)

	-- "[./" continues the link of the line it is nested under: complete as
	-- if that link were typed ("[./-" lists the parent section's items)
	if not ctx.is_local and #ctx.parts == 1 and ctx.parts[1] == "." then
		if not (ctx.typing == "" or link_mod().is_parent_relative("./" .. ctx.typing)) then
			return {}, ctx -- "[./scan.pdf]" is a file path
		end
		local parent = opts.doc and opts.lnum and link_mod().parent_link(opts.doc.lines, opts.lnum)
		if not parent then
			return {}, ctx
		end
		ctx.is_local = parent:sub(1, 1) == "/"
		ctx.parts = link_mod().split(ctx.is_local and parent:sub(2) or parent)
		-- right after "./" every kind of component is offered, items too
		opts.items = ctx.typing == "" or first_char == "-"
	elseif first_char == "-" then
		opts.items = true
	end

	if first_char == ">" then
		items = follow_items(ctx, opts)
	elseif #ctx.parts == 0 then
		if ctx.is_local then
			items = opts.doc and section_items(opts.doc, opts.doc.tree) or {}
			if opts.items and opts.doc then
				vim.list_extend(items, item_items(opts.doc, opts.doc.tree))
			end
		elseif first_char == "@" then
			items = tag_items(opts.doc)
		elseif FILTER[first_char] then
			-- "[#..." searches every note; suggest sections of the current one
			items = opts.doc and section_items(opts.doc, opts.doc.tree) or {}
		else
			items = article_items(nil, opts.doc)
		end
	else
		items = after_parts(ctx, opts)
	end

	-- A typed "#", ":", "*" or "-" narrows to that kind of component
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
-- Completion engines: blink.cmp (features/blink) and nvim-cmp
-- =============================================================================

M.TRIGGERS = { "[", "/", "#", "@", ":", "*", "(", ",", ">", "-" }
M.FILETYPES = { zortex = true, markdown = true, text = true }

--- LSP completion items for the text before the cursor (`before`) on 0-based
--- `row`: each replaces the component being typed (textEdit, byte columns),
--- or nil when the cursor isn't in a link or an @a(...) value.
function M.lsp_items(before, row, bufnr)
	local items, ctx = M.get_completions(before, #before, { bufnr = bufnr, lnum = row + 1 })
	if not ctx then
		return nil
	end
	-- what nvim-cmp filters by (get_keyword_pattern): the text since the last
	-- "[", "/", "(" or ","; inside @[rust as] that's "rust as" for "async"
	local kw = before:match(".*[%[/(,]()") or 1
	local typed_before = ctx.tag and before:sub(kw, ctx.typing_col):gsub("^%s+", "") or ""
	for _, item in ipairs(items) do
		item.filterText = (item.filterText and (typed_before .. item.filterText)) or (typed_before .. item.label)
		item.textEdit = {
			newText = item.area_value or item.label,
			range = {
				start = { line = row, character = ctx.typing_col },
				["end"] = { line = row, character = #before },
			},
		}
		item.section_type = nil
		item.area_value = nil
		item.insertText = nil
	end
	return items
end

function M.new()
	local source = {}

	function source:is_available()
		return M.FILETYPES[vim.bo.filetype] == true
	end

	function source:get_debug_name()
		return "zortex"
	end

	function source:get_trigger_characters()
		return M.TRIGGERS
	end

	function source:get_keyword_pattern()
		-- What cmp filters against: the text typed since the last "[", "/",
		-- "(" or "," (a link component, or an @a(...) value), not starting
		-- with a space. Link components may contain spaces, dots and dashes.
		-- Without "(" and "," here, cmp took everything from the line's last
		-- "]" (e.g. "Tune bike @a(") as the typed word and filtered every
		-- area away.
		return [=[\%([^\[\]/(,[:space:]][^\[\]/(,]*\)\=]=]
	end

	function source:complete(params, callback)
		local line = params.context.cursor_before_line
		local items = M.lsp_items(line, params.context.cursor.row - 1, params.context.bufnr)
		callback({ items = items or {}, isIncomplete = false })
	end

	return source
end

--- Hook the source into the completion plugin that is installed: blink.cmp
--- when it is (features/blink), else nvim-cmp. Called on the first zortex
--- buffer, so neither is loaded at startup on zortex's account.
---@return "blink"|"cmp"|nil
function M.register()
	if M.register_blink() then
		return "blink"
	end
	if M.register_cmp() then
		return "cmp"
	end
	return nil
end

function M.setup()
	local group = vim.api.nvim_create_augroup("ZortexCompletion", { clear = true })
	if package.loaded["blink.cmp"] or package.loaded.cmp then
		M.register()
		return
	end
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = "zortex",
		once = true,
		callback = function()
			M.register()
		end,
	})
end

--- blink.cmp: a "zortex" provider (unless your config defines one) that
--- zortex buffers list next to your default sources.
function M.register_blink()
	local ok, blink = pcall(require, "blink.cmp")
	if not ok or type(blink) ~= "table" or type(blink.add_source_provider) ~= "function" then
		return false
	end
	local providers = vim.tbl_get(require("blink.cmp.config"), "sources", "providers") or {}
	if not providers.zortex then
		blink.add_source_provider("zortex", { name = "Zortex", module = "zortex.features.blink" })
	end
	if not M._blink_filetype then
		M._blink_filetype = true
		blink.add_filetype_source("zortex", "zortex")
	end
	return true
end

--- Register the nvim-cmp source once. setup() may run more than once
--- (re-sourced config, plugin-manager reloads); registering again would make
--- cmp list every suggestion once per registration.
function M.register_cmp()
	local ok, cmp = pcall(require, "cmp")
	if not ok or type(cmp.register_source) ~= "function" then
		return nil
	end
	if M._cmp_id and type(cmp.unregister_source) == "function" then
		pcall(cmp.unregister_source, M._cmp_id)
	end
	M._cmp_id = cmp.register_source("zortex", M.new())
	M.setup_cmp_sorting(cmp)
	return M._cmp_id
end

-- nvim-cmp sorts every menu with its global comparators: recently used
-- items, and words near the cursor ("locality": a projects note is full of
-- "4.1"s), come first. Area suggestions are a tree and read best in the
-- Areas note's order, so in zortex buffers our order wins between two area
-- items; everything else falls through to your comparators, read when
-- sorting so a later cmp.setup() still counts.
function M.order_comparator(a, b)
	local da, db = a.completion_item.data, b.completion_item.data
	local oa = type(da) == "table" and da.zortex_order or nil
	local ob = type(db) == "table" and db.zortex_order or nil
	if oa and ob and oa ~= ob then
		return oa < ob
	end
	return nil
end

-- In zortex buffers: the zortex source next to your global sources (unless
-- you set sources for zortex buffers), and the comparator above in front of
-- yours (unless you set a sorting for them).
function M.setup_cmp_sorting(cmp)
	local ok, cfg = pcall(require, "cmp.config")
	if not ok or type(cfg.filetypes) ~= "table" or not (cmp.setup and cmp.setup.filetype) then
		return
	end
	local current = vim.deepcopy(cfg.filetypes.zortex or {})
	current.revision = nil
	local ours = M._cmp_sources and vim.deep_equal(current.sources, M._cmp_sources)
	if not current.sources or ours then
		local sources = { { name = "zortex" } }
		for _, src in ipairs((cfg.global or {}).sources or {}) do
			if src.name ~= "zortex" then
				sources[#sources + 1] = src
			end
		end
		current.sources = sources
		M._cmp_sources = vim.deepcopy(sources)
	end
	if current.sorting and not current.sorting._zortex then
		pcall(cmp.setup.filetype, "zortex", current)
		return
	end
	local function chained(a, b)
		local r = M.order_comparator(a, b)
		if r ~= nil then
			return r
		end
		for _, f in ipairs((cfg.global.sorting or {}).comparators or {}) do
			r = f(a, b)
			if r ~= nil then
				return r
			end
		end
		return nil
	end
	current.sorting = {
		_zortex = true,
		priority_weight = (cfg.global.sorting or {}).priority_weight or 2,
		comparators = { chained },
	}
	pcall(cmp.setup.filetype, "zortex", current)
end

return M
