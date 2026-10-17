-- ui/keyhelp.lua - "?" in zortex's own buffers: their keys in a float, from
-- the one key table (zortex.keys), the same one the buffers are mapped from
-- and the docs are written from.
local M = {}

--- Lines for buffer `id`'s keys (zortex.keys.lines).
function M.lines(id)
	return require("zortex.keys").lines(id)
end

--- Show the keys of buffer `id` ("plan", "review", "calendar", ...) in a
--- float; q, <Esc> or ? closes it. Returns the window.
function M.show(id)
	local keys = require("zortex.keys")
	local lines = M.lines(id)
	if #lines == 0 then
		return
	end
	local def = keys.def(id)
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	width = math.min(width + 2, vim.o.columns - 4)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	local height = math.min(#lines, vim.o.lines - 4)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " " .. (def and def.name or "Zortex") .. " keys ",
		title_pos = "center",
	})
	vim.wo[win].wrap = false
	for _, key in ipairs({ "q", "<Esc>", "?" }) do
		vim.keymap.set("n", key, function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end, { buffer = buf, nowait = true, silent = true })
	end
	return win
end

return M
