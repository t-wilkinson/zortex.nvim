-- core/link_index.lua - Every link in every note, resolved, with backlinks
--
-- For each (non-archived) note the index stores the links it contains and
-- where each one resolves (with core/link, so the same rules as
-- following the link). From that it answers:
--
--   references(file, start_line, end_line)  links pointing into a line range
--   backlinks(node_or_entity, opts)         links pointing at a section/entity
--   links_from(file)                        links found in a note
--   linked_lines(file)                      lnum -> the links pointing at it
--   generation()                            changes whenever links change
--   unresolved()                            links that resolve nowhere (a
--                                           path link, [./z/scan.pdf], when
--                                           its file is missing)
--
-- The index is persisted to this machine's state folder (core/state, a
-- device file: link_index.json) and refreshed
-- incrementally. A link only needs re-resolving when
--   * its own note changed,
--   * its current target's note changed,
--   * it is unresolved,
--   * its first component is not an article/tag (it searches every note), or
--   * its first component is an article/tag that a changed note declares.
-- When any changed note's header (aliases/tags) changed, everything is
-- re-resolved. Refreshes are lazy (on query) and throttled; the file is
-- written a little after the last refresh (and on exit), not on every one.
local M = {}

local link_mod = require("zortex.core.link")

local VERSION = 5 -- bump when link extraction changes (forces a rebuild)
local REFRESH_TTL_MS = 1000
local SAVE_DELAY_MS = 10000

local state = {
	loaded = false,
	files = {}, -- path -> { stamp, names, tags, links = { link... }, line_tags = { tag = count } }
	last_refresh = nil,
	dirty = false,
	generation = 0, -- bumped whenever a refresh changed anything
	by_target = nil, -- file -> { lnum -> { ref... } }, for this generation
}

local function notes()
	return require("zortex.core.notes")
end

local function Document()
	return require("zortex.core.document")
end

local store = require("zortex.core.state").open("link_index", {
	version = VERSION,
	device = true, -- a cache every Neovim rewrites: never synced
	default = function()
		return { files = {} }
	end,
})

-- =============================================================================
-- Persistence
-- =============================================================================

local function load_from_disk()
	state.loaded = true
	store:reload()
	state.files = store:get().files or {}
end

local save_timer = nil

local function save_to_disk()
	if save_timer then
		save_timer:stop()
		save_timer:close()
		save_timer = nil
	end
	if not state.dirty then
		return
	end
	store:get().files = state.files
	store:save()
	state.dirty = false
end

-- Encoding a large index takes a while: refreshes (after every save of a
-- note) only schedule the write
local function schedule_save()
	if save_timer then
		return
	end
	save_timer = vim.uv.new_timer()
	save_timer:start(SAVE_DELAY_MS, 0, vim.schedule_wrap(save_to_disk))
end

-- =============================================================================
-- Extraction
-- =============================================================================

-- Change stamp for a note: a modified buffer is tracked by changedtick,
-- otherwise by mtime + size.
local function stamp(path, modified)
	local bufnr = require("zortex.utils.buffer").modified_buf(path, modified)
	if bufnr then
		return "buf:" .. vim.api.nvim_buf_get_changedtick(bufnr)
	end
	local st = vim.uv.fs_stat(path)
	if not st then
		return nil
	end
	return string.format("%d.%d:%d", st.mtime.sec, st.mtime.nsec, st.size)
end

-- First component of a link definition, for invalidation:
-- { kind = "article"|"tag"|"global"|"local"|"path"|"os", text }
local function first_component(def)
	if link_mod.is_parent_relative(def) then
		return { kind = "global" } -- through its parent line's link: re-resolve with every change
	end
	if vim.trim(def):match("^%.%.?/") then
		return { kind = "path" } -- a file, checked when queried
	end
	if vim.trim(def):sub(1, 1) == "/" and link_mod.os_path(def) then
		return { kind = "os" } -- a file on this computer ([/home/me/a.pdf]): never broken
	end
	local parsed = link_mod.parse(def)
	if not parsed or not parsed.components[1] then
		return { kind = "global" }
	end
	if parsed.scope == "local" then
		return { kind = "local" }
	end
	local c = parsed.components[1]
	if c.type == "article" or c.type == "tag" then
		return { kind = c.type, text = c.text:lower() }
	end
	return { kind = "global" }
end

-- Bare @words that are attributes, not tags (utils/attributes shortcuts)
-- Bare @words that are attributes, not tags: @2h, @p1, @sm, @step, @event,
-- @fold, @someday (app/links IsAttributeWord is the same)
local ATTRIBUTE_WORDS =
	{ step = true, steps = true, event = true, fold = true, someday = true, share = true, free = true }

local function shortcut(key)
	return key:match("^%d+%.?%d*[hdmw]$") or key:match("^[pi][123]$") or ATTRIBUTE_WORDS[key]
		or require("zortex.utils.attributes").is_size(key)
end
M.is_attribute_word = function(key)
	return shortcut(key:lower()) and true or false
end

-- The tags used on a note's lines: { tag = number of lines }
local function extract_line_tags(doc)
	local syntax = require("zortex.core.syntax")
	local counts = {}
	for lnum, line in ipairs(doc.lines) do
		if line:find("@", 1, true) and not doc:in_code(lnum) then
			local seen = {}
			syntax.walk_spans(doc:inline(lnum), function(span)
				if span.type == "attribute" and span.value == nil then
					local key = span.key:lower()
					if not seen[key] and not shortcut(key) then
						seen[key] = true
						counts[key] = (counts[key] or 0) + 1
					end
				end
			end)
		end
	end
	return counts
end

local function extract_links(doc)
	local syntax = require("zortex.core.syntax")
	local links = {}
	for lnum, line in ipairs(doc.lines) do
		if line:find("[", 1, true) and not doc:in_code(lnum) then
			for _, span in ipairs(syntax.links(line, doc:inline(lnum))) do
				links[#links + 1] = {
					lnum = lnum,
					col = span.s + 1,
					def_col = span.def_s and span.def_s + 1, -- [text](definition)
					text = line:sub(span.s + 1, span.e),
					definition = span.definition,
					first = first_component(span.definition),
				}
			end
		end
	end
	return links
end

-- `memo`: targets of the links already resolved in this refresh, by
-- definition. A link that doesn't depend on where it is written (not local,
-- not parent-relative) means the same everywhere, and most notes link the
-- same few places ([P/#2], [Areas]) many times.
local function resolve(link, source_path, memo)
	if link.first.kind == "path" or link.first.kind == "os" then
		link.target = nil
		return
	end
	local opts = {}
	local placed = link.first.kind == "local" or link_mod.is_parent_relative(link.definition)
	if placed then
		opts.doc = Document().get(source_path)
		opts.lnum = link.lnum
	elseif memo and memo[link.definition] ~= nil then
		local t = memo[link.definition]
		link.target = t and { file = t.file, lnum = t.lnum } or nil
		return
	end
	local ok, result = pcall(function()
		return (link_mod.resolve_first(link.definition, opts))
	end)
	if ok and result then
		link.target = { file = result.file, lnum = result.lnum }
	else
		link.target = nil
	end
	if memo and not placed then
		memo[link.definition] = link.target or false
	end
end

-- =============================================================================
-- Refresh
-- =============================================================================

local function same_list(a, b)
	if #(a or {}) ~= #(b or {}) then
		return false
	end
	for i = 1, #a do
		if a[i]:lower() ~= b[i]:lower() then
			return false
		end
	end
	return true
end

--- Bring the index up to date (throttled; `force` skips the throttle).
function M.refresh(force)
	if not state.loaded then
		load_from_disk()
	end
	local now = vim.uv.now()
	if not force and state.last_refresh and now - state.last_refresh < REFRESH_TTL_MS then
		return
	end
	state.last_refresh = now

	-- A fresh notes snapshot, so the resolver below sees current headers
	local idx = notes().index({ fresh = true })
	local current = {}
	for _, path in ipairs(idx.files) do
		current[vim.fn.fnamemodify(path, ":p")] = true
	end

	-- 1. Which notes changed (added, edited, removed)?
	local changed = {} -- path -> true
	local header_changed = false
	local changed_names = {} -- lowercased alias/tag -> true

	local function mark_header(names, tags)
		for _, n in ipairs(names or {}) do
			changed_names[n:lower()] = true
		end
		for _, t in ipairs(tags or {}) do
			changed_names[t:lower()] = true
		end
	end

	for path in pairs(state.files) do
		if not current[path] then
			local old = state.files[path]
			changed[path] = true
			header_changed = header_changed or #(old.names or {}) > 0 or #(old.tags or {}) > 0
			mark_header(old.names, old.tags)
			state.files[path] = nil
		end
	end

	local modified = require("zortex.utils.buffer").modified_map()
	for path in pairs(current) do
		local s = stamp(path, modified)
		local entry = state.files[path]
		if not entry or entry.stamp ~= s then
			local doc = Document().get(path)
			if doc then
				local names, tags = doc.names, doc.tags
				if not entry or not same_list(entry.names, names) or not same_list(entry.tags, tags) then
					header_changed = true
				end
				if entry then
					mark_header(entry.names, entry.tags)
				end
				mark_header(names, tags)
				state.files[path] =
					{ stamp = s, names = names, tags = tags, links = extract_links(doc), line_tags = extract_line_tags(doc) }
				changed[path] = true
			end
		end
	end

	if next(changed) == nil then
		return
	end
	state.dirty = true
	state.generation = state.generation + 1
	state.by_target = nil

	-- 2. Re-resolve every link whose target could have changed.
	local memo = {}
	for path, entry in pairs(state.files) do
		for _, link in ipairs(entry.links) do
			local needs = header_changed
				or changed[path]
				or link.target == nil
				or (link.target and changed[link.target.file])
				or link.first.kind == "global"
				or ((link.first.kind == "article" or link.first.kind == "tag") and changed_names[link.first.text])
			if needs then
				resolve(link, path, memo)
			end
		end
	end

	schedule_save()
end

--- Drop the index (memory and disk) and rebuild it from scratch.
function M.rebuild()
	state.files = {}
	state.by_target = nil
	state.loaded = true
	state.dirty = true
	state.last_refresh = nil
	M.refresh(true)
	save_to_disk()
end

-- =============================================================================
-- Queries
-- =============================================================================

local function as_ref(path, link)
	return {
		file = path,
		lnum = link.lnum,
		col = link.col,
		def_col = link.def_col,
		text = link.text,
		definition = link.definition,
		target = link.target,
	}
end

--- Write the index to disk now (normally a little after it changes).
M.save = save_to_disk

--- Links found in a note.
--- The tags used on notes' lines, most used first: { { tag, count }... }
function M.line_tags()
	M.refresh()
	local counts = {}
	for _, entry in pairs(state.files) do
		for tag, n in pairs(entry.line_tags or {}) do
			counts[tag] = (counts[tag] or 0) + n
		end
	end
	local out = {}
	for tag, n in pairs(counts) do
		out[#out + 1] = { tag = tag, count = n }
	end
	table.sort(out, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.tag < b.tag
	end)
	return out
end

function M.links_from(path)
	M.refresh()
	path = vim.fn.fnamemodify(path, ":p")
	local out = {}
	local entry = state.files[path]
	for _, link in ipairs(entry and entry.links or {}) do
		out[#out + 1] = as_ref(path, link)
	end
	return out
end

--- Links whose canonical target lies in file between start_line and end_line.
--- Sorted by source file, then line.
function M.references(file, start_line, end_line)
	M.refresh()
	file = vim.fn.fnamemodify(file, ":p")
	end_line = end_line or start_line
	local out = {}
	for path, entry in pairs(state.files) do
		for _, link in ipairs(entry.links) do
			local t = link.target
			if t and t.file == file and t.lnum >= start_line and t.lnum <= end_line then
				out[#out + 1] = as_ref(path, link)
			end
		end
	end
	table.sort(out, function(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.lnum < b.lnum
	end)
	return out
end

--- A number that changes whenever the index does (after a refresh), so
--- what is derived from links can be cached against it.
function M.generation()
	M.refresh()
	return state.generation
end

--- The lines of `file` that links point at: { [lnum] = { ref... } }.
function M.linked_lines(file)
	M.refresh()
	file = vim.fn.fnamemodify(file, ":p")
	if not state.by_target then
		state.by_target = {}
		for path, entry in pairs(state.files) do
			for _, link in ipairs(entry.links) do
				local t = link.target
				if t and t.file then
					local f = state.by_target[t.file] or {}
					state.by_target[t.file] = f
					f[t.lnum] = f[t.lnum] or {}
					table.insert(f[t.lnum], as_ref(path, link))
				end
			end
		end
	end
	return state.by_target[file] or {}
end

--- Backlinks of a section node (with its document) or an entity (project,
--- area, objective). By default only links into the item's own content
--- (up to its first child); opts.descendants includes the whole subtree.
---@param item table Entity, or { doc = Document, node = Section }
---@param opts { descendants?: boolean }?
function M.backlinks(item, opts)
	opts = opts or {}
	local file, s, e
	if item.own_range then -- entity
		file = item.file
		if opts.descendants then
			s, e = item.start_line, item.end_line
		else
			s, e = item:own_range()
		end
	else
		local node = item.node
		file = item.doc.filepath
		s = node.start_line
		e = opts.descendants and node.end_line or node:get_direct_end_line()
	end
	return M.references(file, s, e)
end

-- A file on this computer outside the notes ([/home/me/a.pdf],
-- [~/Documents/tax.pdf]) is never broken: link.os_path
local function missing(link, path)
	if link.first.kind == "os" or (not link.target and link_mod.os_path(link.definition)) then
		return false
	end
	if link.first.kind == "path" then
		return not vim.uv.fs_stat(link_mod.relative_path(link.definition, path))
	end
	return not link.target
end

--- Links of one note that resolve nowhere (each with `path = true` for a
--- file that isn't there), brought up to date first.
function M.unresolved_in(path)
	M.refresh(true)
	path = vim.fn.fnamemodify(path, ":p")
	local out = {}
	local entry = state.files[path]
	for _, link in ipairs(entry and entry.links or {}) do
		if missing(link, path) then
			local ref = as_ref(path, link)
			ref.path = link.first.kind == "path" or nil
			out[#out + 1] = ref
		end
	end
	return out
end

--- Links that resolve nowhere.
function M.unresolved()
	M.refresh()
	local out = {}
	for path, entry in pairs(state.files) do
		for _, link in ipairs(entry.links) do
			if missing(link, path) then
				out[#out + 1] = as_ref(path, link)
			end
		end
	end
	table.sort(out, function(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.lnum < b.lnum
	end)
	return out
end

--- Tags that go nowhere, computed on request (every note is read):
---   searches  tag searches (@[...]) that find nothing, with why
---   links     [@Tag] links to a header tag no note has
---   orphans   bare tags on lines that no tag search asks for, most used
---             first ({ tag, count, file, lnum } of its first use); bare
---             attributes (@p1, @sm, @2h, @event) are not tags
function M.tag_problems()
	M.refresh()
	local syntax = require("zortex.core.syntax")
	local Document = Document()
	local out = { searches = {}, links = {}, orphans = {} }
	local asked, used = {}, {}
	for _, path in ipairs(notes().index().files) do
		local doc = Document.get(path)
		for lnum, line in ipairs(doc and doc.lines or {}) do
			if line:find("@", 1, true) and not doc:in_code(lnum) then
				syntax.walk_spans(doc:inline(lnum), function(span)
					if span.type == "tag_search" then
						local q = link_mod.parse_tag_search(span.content)
						for _, group in ipairs(q.groups) do
							for _, term in ipairs(group) do
								if not term:match("^is:") then
									asked[term] = true
								end
							end
						end
						local ok, results, err = pcall(link_mod.tag_search, span.content, { doc = doc, lnum = lnum })
						if not ok or #results == 0 then
							out.searches[#out.searches + 1] = {
								file = path,
								lnum = lnum,
								col = span.s + 1,
								text = "@[" .. span.content .. "]",
								why = ok and err or tostring(results),
							}
						end
					elseif span.type == "attribute" and span.value == nil then
						local key = span.key:lower()
						if not shortcut(key) then
							local u = used[key]
							if not u then
								u = { tag = key, count = 0, file = path, lnum = lnum, col = span.s + 1 }
								used[key] = u
							end
							u.count = u.count + 1
						end
					end
				end)
			end
		end
	end
	for path, entry in pairs(state.files) do
		for _, link in ipairs(entry.links) do
			if link.first.kind == "tag" and not link.target then
				out.links[#out.links + 1] = as_ref(path, link)
			end
		end
	end
	for key, u in pairs(used) do
		if not asked[key] then
			out.orphans[#out.orphans + 1] = u
		end
	end
	local function by_place(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.lnum < b.lnum
	end
	table.sort(out.searches, by_place)
	table.sort(out.links, by_place)
	table.sort(out.orphans, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.tag < b.tag
	end)
	return out
end

--- Put unresolved links in the quickfix list, then the tags that go nowhere
--- (M.tag_problems): broken links first, apart from the tags.
function M.broken_links_quickfix()
	local items = {}
	for _, ref in ipairs(M.unresolved()) do
		if not (ref.definition or ""):match("^%s*@") then
			items[#items + 1] = { filename = ref.file, lnum = ref.lnum, col = ref.col, text = "Unresolved: " .. ref.text }
		end
	end
	local tags = M.tag_problems()
	for _, ref in ipairs(tags.links) do
		items[#items + 1] = { filename = ref.file, lnum = ref.lnum, col = ref.col, text = "No note has this tag: " .. ref.text }
	end
	for _, x in ipairs(tags.searches) do
		items[#items + 1] = { filename = x.file, lnum = x.lnum, col = x.col, text = "Tag search finds nothing: " .. x.text }
	end
	for _, x in ipairs(tags.orphans) do
		items[#items + 1] = {
			filename = x.file,
			lnum = x.lnum,
			col = x.col,
			text = string.format("No tag search asks for @%s (%d line%s)", x.tag, x.count, x.count == 1 and "" or "s"),
		}
	end
	vim.fn.setqflist(items, "r")
	if #items > 0 then
		vim.cmd("copen")
	else
		vim.notify("No broken links", vim.log.levels.INFO)
	end
	return items
end

function M.setup()
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("ZortexLinkIndex", { clear = true }),
		callback = function()
			save_to_disk()
		end,
	})
end

-- Test hook
function M._reset()
	if save_timer then
		save_timer:stop()
		save_timer:close()
		save_timer = nil
	end
	-- the generation keeps counting, so nothing cached against it survives
	state = { loaded = false, files = {}, last_refresh = nil, dirty = false, generation = (state.generation or 0) + 1 }
end

return M
