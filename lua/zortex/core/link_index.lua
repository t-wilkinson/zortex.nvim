-- core/link_index.lua - Every link in every note, resolved, with backlinks
--
-- For each (non-archived) note the index stores the links it contains and
-- where each one resolves (with core/link, so the same rules as
-- following the link). From that it answers:
--
--   references(file, start_line, end_line)  links pointing into a line range
--   backlinks(node_or_entity, opts)         links pointing at a section/entity
--   links_from(file)                        links found in a note
--   unresolved()                            links that resolve nowhere (a
--                                           path link, [./z/scan.pdf], when
--                                           its file is missing)
--
-- The index is persisted to notes_dir/.z/link_index.json and refreshed
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

local VERSION = 3 -- bump when link extraction changes (forces a rebuild)
local REFRESH_TTL_MS = 1000
local SAVE_DELAY_MS = 10000

local state = {
	loaded = false,
	files = {}, -- path -> { stamp, names, tags, links = { link... } }
	last_refresh = nil,
	dirty = false,
}

local function notes()
	return require("zortex.core.notes")
end

local function Document()
	return require("zortex.core.document")
end

local store = require("zortex.core.state").open("link_index", {
	version = VERSION,
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
local function stamp(path)
	local bufnr = vim.fn.bufnr(path)
	if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
		return "buf:" .. vim.api.nvim_buf_get_changedtick(bufnr)
	end
	local st = vim.uv.fs_stat(path)
	if not st then
		return nil
	end
	return string.format("%d.%d:%d", st.mtime.sec, st.mtime.nsec, st.size)
end

-- First component of a link definition, for invalidation:
-- { kind = "article"|"tag"|"global"|"local"|"path", text }
local function first_component(def)
	if link_mod.is_parent_relative(def) then
		return { kind = "global" } -- through its parent line's link: re-resolve with every change
	end
	if vim.trim(def):match("^%.%.?/") then
		return { kind = "path" } -- a file, checked when queried
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

local function extract_links(doc)
	local syntax = require("zortex.core.syntax")
	local links = {}
	for lnum, line in ipairs(doc.lines) do
		if line:find("[", 1, true) and not doc:in_code(lnum) then
			for _, span in ipairs(syntax.links(line, doc:inline(lnum))) do
				links[#links + 1] = {
					lnum = lnum,
					col = span.s + 1,
					text = line:sub(span.s + 1, span.e),
					definition = span.definition,
					first = first_component(span.definition),
				}
			end
		end
	end
	return links
end

local function resolve(link, source_path)
	if link.first.kind == "path" then
		link.target = nil
		return
	end
	local opts = {}
	if link.first.kind == "local" or link_mod.is_parent_relative(link.definition) then
		opts.doc = Document().get(source_path)
		opts.lnum = link.lnum
	end
	local ok, result = pcall(function()
		return (link_mod.resolve_first(link.definition, opts))
	end)
	if ok and result then
		link.target = { file = result.file, lnum = result.lnum }
	else
		link.target = nil
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

	for path in pairs(current) do
		local s = stamp(path)
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
				state.files[path] = { stamp = s, names = names, tags = tags, links = extract_links(doc) }
				changed[path] = true
			end
		end
	end

	if next(changed) == nil then
		return
	end
	state.dirty = true

	-- 2. Re-resolve every link whose target could have changed.
	for path, entry in pairs(state.files) do
		for _, link in ipairs(entry.links) do
			local needs = header_changed
				or changed[path]
				or link.target == nil
				or (link.target and changed[link.target.file])
				or link.first.kind == "global"
				or ((link.first.kind == "article" or link.first.kind == "tag") and changed_names[link.first.text])
			if needs then
				resolve(link, path)
			end
		end
	end

	schedule_save()
end

--- Drop the index (memory and disk) and rebuild it from scratch.
function M.rebuild()
	state.files = {}
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
		text = link.text,
		definition = link.definition,
		target = link.target,
	}
end

--- Write the index to disk now (normally a little after it changes).
M.save = save_to_disk

--- Links found in a note.
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

--- Links that resolve nowhere.
function M.unresolved()
	M.refresh()
	local out = {}
	for path, entry in pairs(state.files) do
		for _, link in ipairs(entry.links) do
			local missing
			if link.first.kind == "path" then
				missing = not vim.uv.fs_stat(link_mod.relative_path(link.definition, path))
			else
				missing = not link.target
			end
			if missing then
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

--- Put unresolved links in the quickfix list.
function M.broken_links_quickfix()
	local items = {}
	for _, ref in ipairs(M.unresolved()) do
		items[#items + 1] = { filename = ref.file, lnum = ref.lnum, col = ref.col, text = "Unresolved: " .. ref.text }
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
	state = { loaded = false, files = {}, last_refresh = nil, dirty = false }
end

return M
