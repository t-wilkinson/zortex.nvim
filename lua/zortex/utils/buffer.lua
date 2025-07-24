-- core/buffer.lua - Buffer operations for Zortex
local M = {}

local parser = require("zortex.utils.parser")

-- =============================================================================
-- Buffer Reading
-- =============================================================================

function M.get_lines(bufnr, start_line, end_line)
	bufnr = bufnr or 0
	return vim.api.nvim_buf_get_lines(bufnr, start_line or 0, end_line or -1, false)
end

function M.set_lines(bufnr, start_line, end_line, lines)
	bufnr = bufnr or 0
	vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, lines)
end

function M.get_current_line()
	return vim.api.nvim_get_current_line()
end

function M.get_cursor_pos()
	local pos = vim.api.nvim_win_get_cursor(0)
	return pos[1], pos[2] -- line (1-indexed), col (0-indexed)
end

function M.set_cursor_pos(line, col)
	vim.api.nvim_win_set_cursor(0, { line, col })
end

-- =============================================================================
-- Navigation
-- =============================================================================

function M.find_current_project(bufnr)
	bufnr = bufnr or 0
	local current_line = vim.fn.line(".")
	local lines = M.get_lines(bufnr, 0, current_line)

	-- Search backwards for a project heading
	for i = #lines, 1, -1 do
		local heading = parser.parse_heading(lines[i])
		if heading then
			return heading.text
		end
	end

	return nil
end

function M.get_all_headings(bufnr)
	bufnr = bufnr or 0
	local lines = M.get_lines(bufnr)
	local headings = {}

	for lnum, line in ipairs(lines) do
		local heading = parser.parse_heading(line)
		if heading then
			table.insert(headings, {
				level = heading.level,
				text = heading.text,
				lnum = lnum,
			})
		end
	end

	return headings
end

-- Get the bounds of a project/section
function M.find_section_bounds(lines, start_idx)
	local start_line = lines[start_idx]
	local start_level = parser.get_heading_level(start_line)

	if start_level == 0 then
		return start_idx, start_idx + 1
	end

	-- Find where this section ends
	local end_idx = #lines + 1
	for i = start_idx + 1, #lines do
		local line_level = parser.get_heading_level(lines[i])
		if line_level > 0 and line_level <= start_level then
			end_idx = i
			break
		end
	end

	return start_idx, end_idx
end

-- =============================================================================
-- Special Buffer Detection
-- =============================================================================

function M.is_special_buffer()
	local special_articles = vim.g.zortex_special_articles or {}
	if type(special_articles) ~= "table" or #special_articles == 0 then
		return false
	end

	-- Check first 5 non-blank lines for article titles
	local lines = M.get_lines(0, 0, 20)
	local non_blank_count = 0

	for _, line in ipairs(lines) do
		if line:match("%S") then
			non_blank_count = non_blank_count + 1
			local title = line:match("^@@(.+)")
			if title then
				title = parser.trim(title):lower()
				for _, special in ipairs(special_articles) do
					if special:lower() == title then
						return true
					end
				end
			end
			if non_blank_count >= 5 then
				break
			end
		end
	end

	return false
end

-- =============================================================================
-- Window Management
-- =============================================================================

function M.get_target_window()
	local current_win = vim.api.nvim_get_current_win()
	local all_wins = vim.api.nvim_list_wins()

	-- If only one window and in special buffer, create vertical split
	if #all_wins == 1 and M.is_special_buffer() then
		vim.cmd("vsplit")
		-- Return the new window (not the current one)
		local new_wins = vim.api.nvim_list_wins()
		for _, win in ipairs(new_wins) do
			if win ~= current_win then
				return win
			end
		end
	end

	-- Otherwise use current window
	return current_win
end

-- =============================================================================
-- Buffer Search
-- =============================================================================

function M.find_in_buffer(pattern, start_line, end_line)
	local lines = M.get_lines(0, start_line, end_line)
	local results = {}

	start_line = start_line or 0

	for i, line in ipairs(lines) do
		if line:match(pattern) then
			table.insert(results, {
				lnum = start_line + i,
				line = line,
				col = line:find(pattern),
			})
		end
	end

	return results
end

-- =============================================================================
-- Buffer Modification Helpers
-- =============================================================================

function M.update_line(bufnr, lnum, new_text)
	bufnr = bufnr or 0
	vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_text })
end

function M.insert_lines(bufnr, lnum, lines)
	bufnr = bufnr or 0
	vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum - 1, false, lines)
end

function M.delete_lines(bufnr, start_lnum, end_lnum)
	bufnr = bufnr or 0
	vim.api.nvim_buf_set_lines(bufnr, start_lnum - 1, end_lnum - 1, false, {})
end

return M
