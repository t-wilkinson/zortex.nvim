-- features/links.lua - Link navigation for Zortex with normalized section handling
local M = {}

local parser = require("zortex.utils.parser")
local link_resolver = require("zortex.utils.link_resolver")
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
-- Main Link Opening Function
-- =============================================================================

-- The link under the cursor, or the next one to its right on the line.
function M.link_at_cursor()
	local line = buffer.get_current_line()
	local _, cursor_col = buffer.get_cursor_pos()
	local link_info = parser.extract_link_at(line, cursor_col)
	if not link_info then
		for col = cursor_col + 1, #line - 1 do
			link_info = parser.extract_link_at(line, col)
			if link_info then
				break
			end
		end
	end
	return link_info
end

M.jump_to_location = jump_to_location

-- Open link at cursor or search forward
function M.open_link()
	local link_info = M.link_at_cursor()
	if not link_info then
		vim.notify("No link found on current line", vim.log.levels.INFO)
		return
	end

	-- Handle different link types
	if link_info.type == "link" or link_info.type == "live_link" then
		-- Zortex-style link format
		local parsed = parser.parse_link_definition(link_info.definition)
		if not parsed then
			vim.notify("Invalid link format", vim.log.levels.WARN)
			return
		end

		-- Check if this is a direct media file path before resolving as a note
		local def = link_info.definition
		if is_media(def) then
			local resolved_path = def
			-- Resolve relative paths (./ or ../) relative to the current file
			if def:sub(1, 2) == "./" or def:sub(1, 3) == "../" then
				local current_dir = vim.fn.expand("%:p:h")
				resolved_path = fs.joinpath(current_dir, def)
			end

			local expanded = vim.fn.expand(resolved_path)
			if fs.file_exists(expanded) then
				open_external(expanded)
				return
			end
		end

		-- For live links in digest, just navigate normally but register for updates
		if link_info.type == "live_link" then
			local current_file = vim.fn.expand("%:p")
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

		-- Process the link using core link resolver functionality
		local results = link_resolver.process_link(parsed)

		if #results == 0 then
			-- Already notified by process_link
			return
		elseif #results == 1 then
			-- Single result - jump directly
			jump_to_location(results[1], true)
		else
			-- Multiple results - jump to first and populate quickfix
			jump_to_location(results[1], true)
			link_resolver.populate_quickfix(results)
			vim.notify(string.format("Found %d matches. Quickfix list populated.", #results), vim.log.levels.INFO)
		end
	elseif link_info.type == "tag_search" then
		-- Handle @[tag1 + tag2] style tag search links
		local source_lnum = buffer.get_cursor_pos()
		local results = link_resolver.search_tag_query(link_info, source_lnum)

		if #results == 0 then
			vim.notify("No tag matches found for: " .. link_info.display_text, vim.log.levels.INFO)
			return
		elseif #results == 1 then
			jump_to_location(results[1], true)
		else
			jump_to_location(results[1], true)
			link_resolver.populate_quickfix(results)
			vim.notify(string.format("Found %d tag matches. Quickfix list populated.", #results), vim.log.levels.INFO)
		end
	elseif link_info.type == "website" then
		open_external(link_info.url)
	elseif link_info.type == "footnote" then
		-- Handle footnote reference
		local footnote_loc = link_resolver.search_footnote(link_info.ref_id)
		if footnote_loc then
			buffer.set_cursor_pos(footnote_loc.lnum, footnote_loc.col - 1)
			vim.cmd("normal! zz")
		else
			vim.notify("Footnote definition [^" .. link_info.ref_id .. "] not found", vim.log.levels.WARN)
		end
	elseif link_info.type == "markdown" then
		-- Handle markdown-style link
		local url = link_info.url
		local current_dir = vim.fn.expand("%:p:h")

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
