-- utils/buffer.lua - Buffer operations for Zortex
local M = {}


function M.get_filepath(bufnr)
	return vim.api.nvim_buf_get_name(bufnr)
end

function M.get_context()
	local cursor = vim.api.nvim_win_get_cursor(0)
	return {
		bufnr = vim.api.nvim_get_current_buf(),
		lnum = cursor[1],
		col = cursor[0],
	}
end

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
