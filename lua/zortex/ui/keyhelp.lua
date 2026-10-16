-- ui/keyhelp.lua - "?" in the plan and review buffers: their keys in a
-- float, read from the buffer's own mappings (their descriptions), so the
-- list can't drift from what the keys do.
local M = {}

--- Lines for the buffer-local normal-mode keys of `buf` whose description
--- starts with `prefix` ("Zortex plan: "), in a stable order.
function M.lines(buf, prefix)
	local rows, width = {}, 0
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		local desc = m.desc or ""
		if desc:sub(1, #prefix) == prefix then
			local lhs = m.lhs:gsub(" ", "<Space>")
			rows[#rows + 1] = { lhs, desc:sub(#prefix + 1) }
			width = math.max(width, vim.fn.strdisplaywidth(lhs))
		end
	end
	table.sort(rows, function(a, b)
		return a[1]:lower() < b[1]:lower() or (a[1]:lower() == b[1]:lower() and a[1] < b[1])
	end)
	local out = {}
	for _, r in ipairs(rows) do
		out[#out + 1] = "  " .. r[1] .. string.rep(" ", width - vim.fn.strdisplaywidth(r[1]) + 2) .. r[2]
	end
	return out
end

--- Show the keys of the current buffer in a float; q, <Esc> or ? closes it.
function M.show(prefix, title)
	local lines = M.lines(vim.api.nvim_get_current_buf(), prefix)
	if #lines == 0 then
		return
	end
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
		title = " " .. (title or "Keys") .. " ",
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
