-- utils/buffer.lua - Buffer operations for Zortex
local M = {}

-- =============================================================================
-- Buffer Reading
-- =============================================================================

--- Loaded buffers with unsaved changes, by file path (as given and with
--- symlinks resolved): build it once before a pass over many notes instead
--- of asking vim.fn.bufnr() for each one.
---@return table<string, integer>
function M.modified_map()
	local map = {}
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
			local name = vim.api.nvim_buf_get_name(b)
			if name ~= "" then
				map[name] = b
				map[vim.fn.fnamemodify(name, ":p")] = b
				local real = vim.uv.fs_realpath(name)
				if real then
					map[real] = b
				end
			end
		end
	end
	return map
end

--- The modified buffer holding `path`, or nil; `map` from modified_map().
function M.modified_buf(path, map)
	if map then
		return map[path]
	end
	local bufnr = vim.fn.bufnr(path)
	if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
		return bufnr
	end
end

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
