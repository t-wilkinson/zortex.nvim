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

-- =============================================================================
-- Navigation
-- =============================================================================

-- Jump to location
local function jump_to_location(location, use_target_window)
	local target_win = use_target_window and buffer.get_target_window() or vim.api.nconfig.get("t_current_win")()

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

-- Open link at cursor or search forward
function M.open_link()
	local line = buffer.get_current_line()
	local _, cursor_col = buffer.get_cursor_pos()

	-- First try to extract link at cursor position
	local link_info = parser.extract_link_at(line, cursor_col)

	-- If no link at cursor, search forward on the line
	if not link_info then
		-- Search forward from cursor + 1
		for col = cursor_col + 1, #line - 1 do
			link_info = parser.extract_link_at(line, col)
			if link_info then
				break
			end
		end

		if not link_info then
			vim.notify("No link found on current line", vim.log.levels.INFO)
			return
		end
	end

	-- Handle different link types
	if link_info.type == "link" then
		-- Zortex-style link format
		local parsed = parser.parse_link_definition(link_info.definition)
		if not parsed then
			vim.notify("Invalid link format", vim.log.levels.WARN)
			return
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

		-- Check if it's a web URL
		if url:match("^https?://") then
			open_external(url)
		else
			-- It's a file path
			local current_dir = vim.fn.expand("%:p:h")
			local resolved_path = url

			-- Handle relative paths
			if not url:match("^/") and not url:match("^[a-zA-Z]:[\\/]") then
				if url:sub(1, 2) == "./" or url:sub(1, 3) == "../" then
					resolved_path = fs.joinpath(current_dir, url)
				else
					-- Try notes directory
					resolved_path = fs.get_file_path(url)
				end
			end

			-- Check if file exists
			if fs.file_exists(vim.fn.expand(resolved_path)) then
				local target_win = buffer.get_target_window()
				local bufnr = vim.fn.bufadd(resolved_path)
				vim.api.nvim_win_set_buf(target_win, bufnr)
			else
				-- If file doesn't exist, try opening as external URL
				open_external(url)
			end
		end
	elseif link_info.type == "website" then
		-- Handle direct URL
		open_external(link_info.url)
	elseif link_info.type == "filepath" then
		-- Handle file path
		local expanded_path = vim.fn.expand(link_info.path)
		if fs.file_exists(expanded_path) or fs.directory_exists(expanded_path) then
			local target_win = buffer.get_target_window()
			local bufnr = vim.fn.bufadd(expanded_path)
			vim.api.nvim_win_set_buf(target_win, bufnr)
		else
			vim.notify("File not found: " .. link_info.path, vim.log.levels.WARN)
		end
	end
end

-- =============================================================================
-- Navigation Helpers
-- =============================================================================

-- Navigate to next/previous section at same or higher level
function M.navigate_section(direction)
	local lines = buffer.get_lines()
	local current_lnum, _ = buffer.get_cursor_pos()

	-- Get current section info
	local current_section_type = parser.detect_section_type(lines[current_lnum])
	local current_heading_level = nil
	if current_section_type == constants.SECTION_TYPE.HEADING then
		current_heading_level = parser.get_heading_level(lines[current_lnum])
	end
	local current_priority = constants.SECTION_HIERARCHY.get_priority(current_section_type, current_heading_level)

	-- If we're not on a section header, find the containing section
	if current_section_type == constants.SECTION_TYPE.TEXT or current_section_type == constants.SECTION_TYPE.TAG then
		-- Build section path to current position
		local section_path = parser.build_section_path(lines, current_lnum)
		if #section_path > 0 then
			local last_section = section_path[#section_path]
			current_priority = last_section.priority
		end
	end

	-- Search for next/previous section of same or higher priority
	local target_lnum = nil
	if direction == "next" then
		for i = current_lnum + 1, #lines do
			local section_type = parser.detect_section_type(lines[i])
			if section_type ~= constants.SECTION_TYPE.TEXT and section_type ~= constants.SECTION_TYPE.TAG then
				local heading_level = nil
				if section_type == constants.SECTION_TYPE.HEADING then
					heading_level = parser.get_heading_level(lines[i])
				end
				local priority = constants.SECTION_HIERARCHY.get_priority(section_type, heading_level)
				if priority <= current_priority then
					target_lnum = i
					break
				end
			end
		end
	else -- previous
		for i = current_lnum - 1, 1, -1 do
			local section_type = parser.detect_section_type(lines[i])
			if section_type ~= constants.SECTION_TYPE.TEXT and section_type ~= constants.SECTION_TYPE.TAG then
				local heading_level = nil
				if section_type == constants.SECTION_TYPE.HEADING then
					heading_level = parser.get_heading_level(lines[i])
				end
				local priority = constants.SECTION_HIERARCHY.get_priority(section_type, heading_level)
				if priority <= current_priority then
					target_lnum = i
					break
				end
			end
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
	local lines = buffer.get_lines()
	local current_lnum, _ = buffer.get_cursor_pos()

	-- Build section path to current position
	local section_path = parser.build_section_path(lines, current_lnum)

	if #section_path > 1 then
		-- Go to parent section (second to last in path)
		local parent = section_path[#section_path - 1]
		buffer.set_cursor_pos(parent.lnum, 0)
		vim.cmd("normal! zz")
	elseif #section_path == 1 then
		-- Already at top level, go to start of file
		buffer.set_cursor_pos(1, 0)
	else
		vim.notify("No parent section found", vim.log.levels.INFO)
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
