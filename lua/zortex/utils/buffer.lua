-- utils/buffer.lua - Buffer operations for Zortex
local M = {}

-- =============================================================================
-- Buffer Reading
-- =============================================================================

function M.get_lines(bufnr, start_line, end_line)
	bufnr = bufnr or 0
	return vim.api.nvim_buf_get_lines(bufnr, start_line or 0, end_line or -1, false)
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

return M
