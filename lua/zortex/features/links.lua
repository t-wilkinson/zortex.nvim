-- features/links.lua - Following links in a buffer, and section navigation
--
-- What a link means is core/link; this module opens what it points to:
-- notes (quickfix list for several targets), @[scope/tag] searches,
-- footnotes, URLs, media and files. A link ending in a > component opens
-- the links it matched (a picker when there are several).
local M = {}

local link_mod = require("zortex.core.link")
local buffer = require("zortex.utils.buffer")
local fs = require("zortex.utils.filesystem")
local constants = require("zortex.constants")

-- =============================================================================
-- External Link Handling
-- =============================================================================

-- Open external link (URL or file)
local function open_external(target)
	if not target or target == "" then
		vim.notify("Error: No target specified for open_external.", vim.log.levels.ERROR)
		return
	end

	local cmd_parts
	if vim.fn.has("macunix") == 1 then
		cmd_parts = { "open", target }
	elseif vim.fn.has("unix") == 1 and vim.fn.executable("xdg-open") == 1 then
		cmd_parts = { "xdg-open", target }
	elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		cmd_parts = { "cmd", "/c", "start", "", target:gsub("/", "\\") }
	else
		vim.notify("Unsupported OS or xdg-open not found for opening external links.", vim.log.levels.WARN)
		return
	end

	vim.fn.jobstart(cmd_parts, { detach = true })
end

local MEDIA_EXTENSIONS = { "mp4", "mkv", "mov", "png", "jpg", "jpeg", "gif", "webp", "pdf", "epub" }

-- Files opened with the system handler instead of a buffer
local function is_media(path)
	local ext = (path:match("%.([%w]+)$") or ""):lower()
	return vim.tbl_contains(MEDIA_EXTENSIONS, ext)
end

-- =============================================================================
-- Navigation
-- =============================================================================

-- Jump to location
local function jump_to_location(location, use_target_window)
	local target_win = use_target_window and buffer.get_target_window() or vim.api.nvim_get_current_win()

	-- Load file in target window
	local bufnr = vim.fn.bufadd(location.file)
	vim.api.nvim_win_set_buf(target_win, bufnr)

	-- Set cursor position
	vim.api.nvim_win_set_cursor(target_win, { location.lnum, location.col - 1 })

	-- Center view
	vim.api.nvim_win_call(target_win, function()
		vim.cmd("normal! zz")
	end)
end

-- =============================================================================
-- Footnote Search
-- =============================================================================

-- The footnote definition "[^id]: ..." in the current buffer
local function search_footnote(ref_id)
	local prefix = "[^" .. ref_id .. "]:"
	for lnum, line in ipairs(buffer.get_lines()) do
		if line:sub(1, #prefix) == prefix then
			return { lnum = lnum, col = 1 }
		end
	end

	return nil
end

-- =============================================================================
-- Quickfix Integration
-- =============================================================================

--- Custom quickfix text function that shows only the link text,
--- hiding filename, line number, and column.
function M.quickfix_text_func(info)
	local items = vim.fn.getqflist({ id = info.id, items = 1 }).items
	local lines = {}
	for i = info.start_idx, info.end_idx do
		local item = items[i]
		if item then
			table.insert(lines, item.text or "")
		else
			table.insert(lines, "")
		end
	end
	return lines
end

--- Jump from the quickfix window to the entry under the cursor,
--- opening in the target window (or previous window as fallback).
local function quickfix_jump()
	local qf_list = vim.fn.getqflist()
	local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
	local entry = qf_list[cursor_lnum]

	if not entry or entry.bufnr == 0 then
		vim.notify("No valid quickfix entry under cursor", vim.log.levels.INFO)
		return
	end

	-- Determine target window: use zortex target window if available,
	-- otherwise fall back to the previous window
	local target_win = buffer.get_target_window()

	-- Fallback: use the previous window (the one before quickfix was focused)
	if not target_win or not vim.api.nvim_win_is_valid(target_win) then
		local qf_win = vim.api.nvim_get_current_win()
		vim.cmd("wincmd p")
		target_win = vim.api.nvim_get_current_win()
		-- If we're still in the quickfix window (no previous window), find any non-qf window
		if target_win == qf_win then
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				if win ~= qf_win then
					target_win = win
					break
				end
			end
		end
	end

	-- Load the buffer and jump
	local bufnr = entry.bufnr
	vim.api.nvim_win_set_buf(target_win, bufnr)
	vim.api.nvim_win_set_cursor(target_win, { entry.lnum, math.max(0, entry.col - 1) })
	vim.api.nvim_set_current_win(target_win)
	vim.cmd("normal! zz")
end

function M.populate_quickfix(results)
	local qf_list = {}

	for _, result in ipairs(results) do
		local link = link_mod.build_result_link(result)

		table.insert(qf_list, {
			filename = result.file,
			lnum = result.lnum,
			col = result.col,
			text = link,
			valid = 1,
		})
	end

	vim.fn.setqflist(qf_list, "r")
	if #qf_list > 0 then
		-- Set custom display: show only the link text, no file/lnum/col
		vim.o.quickfixtextfunc = "v:lua.require'zortex.features.links'.quickfix_text_func"

		vim.cmd("copen")

		-- Map <CR> in the quickfix buffer to jump via target window
		vim.api.nvim_buf_set_keymap(0, "n", "<CR>", "", {
			noremap = true,
			silent = true,
			callback = quickfix_jump,
		})
	end
end

-- =============================================================================
-- Main Link Opening Function
-- =============================================================================

-- The link under the cursor, or the next one to its right on the line.
function M.link_at_cursor()
	local line = buffer.get_current_line()
	local _, cursor_col = buffer.get_cursor_pos()
	local link_info = link_mod.at(line, cursor_col)
	if not link_info then
		for col = cursor_col + 1, #line - 1 do
			link_info = link_mod.at(line, col)
			if link_info then
				break
			end
		end
	end
	return link_info
end

M.jump_to_location = jump_to_location

-- Following a > link: the links it matched, opened directly when there is
-- one and through a picker otherwise (telescope, with a preview and <C-l> to
-- go to the link's line, when installed). Each is opened from the note it is
-- written in (relative paths, local links), up to MAX_FOLLOW links deep.
local MAX_FOLLOW = 5

-- Where a link goes, short: a URL without its scheme, a file's name, a
-- zortex link as written
local function short_target(t)
	if t.url then
		return (t.url:gsub("^%a+://", ""):gsub("^www%.", ""))
	elseif t.path then
		return vim.fn.fnamemodify(t.path, ":t")
	end
	return "[" .. (t.definition or "") .. "]"
end

-- A matched link as the picker shows it: { title, target, where, result }
local function follow_entry(result)
	local t = result.target
	local node = result.doc and result.doc:node_at(result.lnum)
	local where = node and not node:is_root() and node:get_breadcrumb(" › ")
		or vim.fn.fnamemodify(result.file, ":t")
	local target = short_target(t)
	local title = link_mod.follow_title(result.text, t)
	return { title = title ~= "" and title or target, target = target, where = where, result = result }
end
M._follow_entry = follow_entry

local function follow(results, ctx)
	local function open(entry)
		if not entry then
			return
		end
		M.open_info(entry.result.target, {
			file = entry.result.file,
			doc = entry.result.doc,
			depth = (ctx.depth or 0) + 1,
		})
	end
	local entries = vim.tbl_map(follow_entry, results)
	if #entries == 1 then
		open(entries[1])
		return
	end
	if M.use_telescope() then
		require("zortex.ui.telescope.follow").pick(entries, open, function(entry)
			jump_to_location(entry.result, true)
		end)
		return
	end
	vim.ui.select(entries, {
		prompt = "Follow link",
		format_item = function(e)
			return e.title .. " — " .. e.target .. " (" .. e.where .. ")"
		end,
	}, open)
end

-- The telescope picker when telescope is installed; vim.ui.select otherwise
function M.use_telescope()
	return (pcall(require, "telescope.pickers.entry_display"))
end

-- Open a link (as core/link.at returns it). ctx: where the link is written
-- (file, doc; the current buffer when nil) and how many > links led here.
function M.open_info(link_info, ctx)
	ctx = ctx or {}
	if (ctx.depth or 0) > MAX_FOLLOW then
		vim.notify("Too many > links in a row", vim.log.levels.WARN)
		return
	end
	local current_file = ctx.file or vim.fn.expand("%:p")
	local current_dir = vim.fn.fnamemodify(current_file, ":h")
	local in_buffer = ctx.file == nil

	-- Handle different link types
	if link_info.type == "link" or link_info.type == "live_link" then
		-- [./-Item]: relative to the parent line's link
		if link_mod.is_parent_relative(link_info.definition) then
			local lnum = ctx.lnum or (in_buffer and buffer.get_cursor_pos()) or nil
			local lines = ctx.doc and ctx.doc.lines
				or (in_buffer and vim.api.nvim_buf_get_lines(0, 0, -1, false))
				or require("zortex.utils.filesystem").read_lines(current_file)
			local abs, err = link_mod.absolute(link_info.definition, lines or {}, lnum or 0)
			if not abs then
				vim.notify(err, vim.log.levels.WARN)
				return
			end
			link_info = vim.tbl_extend("force", link_info, { definition = abs })
		end
		-- A path relative to this note ([./z/scan.pdf], [../folder]) names a file
		local rel = link_mod.relative_path(link_info.definition, current_file)
		if rel then
			if not vim.uv.fs_stat(rel) then
				vim.notify("File does not exist: " .. rel, vim.log.levels.WARN)
			elseif is_media(rel) then
				open_external(rel)
			else
				vim.api.nvim_set_current_win(buffer.get_target_window())
				vim.cmd.edit(vim.fn.fnameescape(rel))
			end
			return
		end

		-- Zortex-style link format
		local parsed = link_mod.parse(link_info.definition)
		if not parsed then
			vim.notify("Invalid link format", vim.log.levels.WARN)
			return
		end

		-- Check if this is a direct media file path before resolving as a note
		local def = link_info.definition
		if is_media(def) then
			local expanded = vim.fn.expand(def)
			if fs.file_exists(expanded) then
				open_external(expanded)
				return
			end
		end

		-- For live links in digest, just navigate normally but register for updates
		if link_info.type == "live_link" and in_buffer then
			if current_file:match(constants.FILES.DIGEST .. "$") then
				-- This is a live link in the digest
				local digest = require("zortex.services.digest")
				local lnum = buffer.get_cursor_pos()
				local link_id = table.concat(
					vim.tbl_map(function(c)
						return c.text
					end, parsed.components),
					"/"
				)
				digest.register_live_link_from_cursor(link_id, parsed, lnum)
			end
		end

		local results, err = link_mod.resolve(parsed, ctx.doc and { doc = ctx.doc } or nil)

		if #results == 0 then
			vim.notify(err or "No matches", vim.log.levels.INFO)
			return
		elseif parsed.components[#parsed.components].type == "follow" then
			-- [R/#Rust/>Book]: open what the matched links point to
			follow(results, ctx)
		elseif #results == 1 then
			-- Single result - jump directly
			jump_to_location(results[1], true)
		else
			-- Multiple results - jump to first and populate quickfix
			jump_to_location(results[1], true)
			M.populate_quickfix(results)
			vim.notify(string.format("Found %d matches. Quickfix list populated.", #results), vim.log.levels.INFO)
		end
	elseif link_info.type == "tag_search" then
		-- @[scope/tag1 + tag2]: tagged lines (core/link tag_search), minus
		-- the line the search is written on
		local source_lnum = buffer.get_cursor_pos()
		local results, err = link_mod.tag_search(link_info.display_text, ctx.doc and { doc = ctx.doc } or nil)
		results = vim.tbl_filter(function(r)
			return not (r.file == current_file and r.lnum == source_lnum and in_buffer)
		end, results)

		if #results == 0 then
			vim.notify(err or ("No tag matches found for: " .. link_info.display_text), vim.log.levels.INFO)
			return
		elseif #results == 1 then
			jump_to_location(results[1], true)
		else
			jump_to_location(results[1], true)
			M.populate_quickfix(results)
			vim.notify(string.format("Found %d tag matches. Quickfix list populated.", #results), vim.log.levels.INFO)
		end
	elseif link_info.type == "website" then
		open_external(link_info.url)
	elseif link_info.type == "filepath" then
		-- A bare path (./scan.pdf), followed through a > link
		local p = link_info.path:gsub("[%.,;:!%?]+$", "")
		local full_path = vim.fn.expand(p:match("^%.%.?/") and fs.joinpath(current_dir, p) or p)
		if not fs.file_exists(full_path) then
			vim.notify("File does not exist: " .. full_path, vim.log.levels.WARN)
		elseif is_media(full_path) then
			open_external(full_path)
		else
			vim.api.nvim_win_set_buf(buffer.get_target_window(), vim.fn.bufadd(full_path))
		end
	elseif link_info.type == "footnote" then
		-- Handle footnote reference
		local footnote_loc = search_footnote(link_info.ref_id)
		if footnote_loc then
			buffer.set_cursor_pos(footnote_loc.lnum, footnote_loc.col - 1)
			vim.cmd("normal! zz")
		else
			vim.notify("Footnote definition [^" .. link_info.ref_id .. "] not found", vim.log.levels.WARN)
		end
	elseif link_info.type == "markdown" then
		-- Handle markdown-style link
		local url = link_info.url

		-- 1. If it's a web URL, open immediately
		if url:match("^https?://") then
			open_external(url)
			return
		end

		-- 2. It is a local file. Resolve the absolute path first.
		local resolved_path = url
		if not url:match("^/") and not url:match("^[a-zA-Z]:[\\/]") then
			if url:sub(1, 2) == "./" or url:sub(1, 3) == "../" then
				-- Relative to current file
				resolved_path = fs.joinpath(current_dir, url)
			else
				-- Relative to workspace/notes (fallback)
				resolved_path = fs.get_file_path(url)
			end
		end

		-- Expand to full absolute path for the OS
		local full_path = vim.fn.expand(resolved_path)

		-- 3. Check extension to decide HOW to open (Media/PDF vs Note)
		-- Add PDF and other non-text formats here
		if is_media(full_path) then
			if fs.file_exists(full_path) then
				open_external(full_path)
			else
				vim.notify("File does not exist: " .. full_path, vim.log.levels.WARN)
			end
		else
			-- It's a text note, open in Vim
			if fs.file_exists(full_path) then
				local target_win = buffer.get_target_window()
				local bufnr = vim.fn.bufadd(full_path)
				vim.api.nvim_win_set_buf(target_win, bufnr)
			else
				-- Fallback: if we can't find it, try opening as external URL/File just in case
				open_external(url)
			end
		end
	end
end

-- Open link at cursor or search forward
function M.open_link()
	local link_info = M.link_at_cursor()
	if not link_info then
		vim.notify("No link found on current line", vim.log.levels.INFO)
		return
	end
	M.open_info(link_info)
end

-- =============================================================================
-- Navigation Helpers
-- =============================================================================

-- Navigate to next/previous section at the same or a higher structural level
-- than the section the cursor is in (or on).
function M.navigate_section(direction)
	local doc = require("zortex.core.document").from_buffer(0)
	local current_lnum = buffer.get_cursor_pos()
	local current = doc:node_at(current_lnum)
	local current_level = current:is_root() and math.huge or current.level

	local sections = doc.syntax.sections
	local target_lnum = nil
	local first, last, step = 1, #sections, 1
	if direction ~= "next" then
		first, last, step = #sections, 1, -1
	end
	for i = first, last, step do
		local sec = sections[i]
		local ahead = direction == "next" and sec.lnum > current_lnum or direction ~= "next" and sec.lnum < current_lnum
		if ahead and sec.level <= current_level then
			target_lnum = sec.lnum
			break
		end
	end

	if target_lnum then
		buffer.set_cursor_pos(target_lnum, 0)
		vim.cmd("normal! zz")
	else
		vim.notify("No " .. direction .. " section found", vim.log.levels.INFO)
	end
end

-- Navigate to parent section
function M.navigate_parent()
	local doc = require("zortex.core.document").from_buffer(0)
	local node = doc:node_at(buffer.get_cursor_pos())
	if node:is_root() then
		vim.notify("No parent section found", vim.log.levels.INFO)
	elseif node.parent and not node.parent:is_root() then
		buffer.set_cursor_pos(node.parent.start_line, 0)
		vim.cmd("normal! zz")
	else
		buffer.set_cursor_pos(1, 0)
	end
end

-- Additional navigation commands
M.next_section = function()
	M.navigate_section("next")
end
M.prev_section = function()
	M.navigate_section("previous")
end
M.parent_section = M.navigate_parent

return M
