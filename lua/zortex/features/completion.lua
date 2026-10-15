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
local KIND = { article = 17, tag = 14, heading = 22, bold_heading = 13, label = 10, follow = 18 }
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
	local parts = prefix ~= "" and link_mod().split(prefix) or {}
	local typing_col = open + (is_local and 1 or 0) + (last_slash or 0) -- 0-based

	return { parts = parts, typing = typing, typing_col = typing_col, is_local = is_local }
end

-- =============================================================================
-- Candidates
-- =============================================================================

local reachable_sections -- defined below

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
-- Area attributes: @a(...) / @area(...)
-- =============================================================================

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

--- Completion items for the link at `col` (bytes before the cursor).
---@param opts { bufnr?: integer, doc?: table }?
---@return table[] items { label, kind, detail, sortText }, table? ctx
function M.get_completions(line, col, opts)
	opts = opts or {}
	local actx = M.area_context(line, col)
	if actx then
		return area_items(), actx
	end
	local ctx = M.link_context(line, col)
	if not ctx then
		return {}, nil
	end
	opts.doc = opts.doc or Document().from_buffer(opts.bufnr or 0)

	local items
	local first_char = ctx.typing:sub(1, 1)
	if first_char == ">" then
		items = follow_items(ctx, opts)
	elseif #ctx.parts == 0 then
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
		return { "[", "/", "#", "@", ":", "*", "(", ",", ">" }
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
		local row = params.context.cursor.row - 1
		local items, ctx = M.get_completions(line, #line, { bufnr = params.context.bufnr })
		if not ctx then
			callback({ items = {}, isIncomplete = false })
			return
		end
		for _, item in ipairs(items) do
			item.filterText = item.filterText or item.label
			item.textEdit = {
				newText = item.area_value or item.label,
				range = {
					start = { line = row, character = ctx.typing_col },
					["end"] = { line = row, character = #line },
				},
			}
			item.section_type = nil
			item.area_value = nil
			item.insertText = nil
		end
		callback({ items = items, isIncomplete = false })
	end

	return source
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

function M.setup_cmp_sorting(cmp)
	local ok, cfg = pcall(require, "cmp.config")
	if not ok or type(cfg.filetypes) ~= "table" or not (cmp.setup and cmp.setup.filetype) then
		return
	end
	-- keep whatever else the user set for zortex buffers; leave a sorting of
	-- their own alone
	local current = vim.deepcopy(cfg.filetypes.zortex or {})
	current.revision = nil
	if current.sorting and not current.sorting._zortex then
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
