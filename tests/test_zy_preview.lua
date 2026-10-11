local T = require("helpers")
local preview = require("zortex.features.preview")

local function open_with(line)
	vim.cmd("enew!")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

T.test("previews the section a link resolves to", function()
	open_with("see [P/#1.4 - zortex] for details")
	local win = preview.preview_link()
	T.ok(win and vim.api.nvim_win_is_valid(win), "preview window open")
	local buf = vim.api.nvim_win_get_buf(win)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	T.eq(lines[1], "## 1.4 - zortex @size(lg) @a(4.1)")
	T.eq(lines[#lines], "- [ ] Fix project search @size(sm)") -- whole section incl. sub-project
	local cfg = vim.api.nvim_win_get_config(win)
	T.ok(vim.inspect(cfg.title):find("1.4 - zortex", 1, true), vim.inspect(cfg.title))
	preview.close()
	T.ok(not vim.api.nvim_win_is_valid(win), "closed")
end)

T.test("links into a section focus the matched line", function()
	open_with("[P/#1.4 - zortex/%website]")
	local win = preview.preview_link()
	local buf = vim.api.nvim_win_get_buf(win)
	local cursor = vim.api.nvim_win_get_cursor(win)
	T.eq(vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1], "- [ ] Improve website @p1 @size(xl)")
	preview.close()
end)

T.test("<CR> in the preview opens the target", function()
	open_with("[@P/#Subaru outback]")
	local win = preview.preview_link()
	local buf = vim.api.nvim_win_get_buf(win)
	local cr
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if m.lhs == "<CR>" then
			cr = m.callback
		end
	end
	T.ok(cr, "<CR> mapped in the preview")
	vim.api.nvim_set_current_win(win)
	cr()
	T.ok(vim.api.nvim_buf_get_name(0):find("flipping.zortex", 1, true), vim.api.nvim_buf_get_name(0))
	T.eq(vim.api.nvim_win_get_cursor(0)[1], 11)
	T.ok(not vim.api.nvim_win_is_valid(win), "preview closed")
end)

T.test("unresolved links don't open a window", function()
	open_with("[P/#No such project]")
	local before = #vim.api.nvim_list_wins()
	T.eq(preview.preview_link(), nil)
	T.eq(#vim.api.nvim_list_wins(), before)
	vim.cmd("enew!")
end)

T.test("hover previews only the link under the cursor, without focus", function()
	open_with("text [P/#1.4 - zortex] more")
	vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on "text": nothing
	T.eq(preview.preview_link({ hover = true }), nil)
	local origin = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(0, { 1, 8 })
	local win = preview.preview_link({ hover = true })
	T.ok(win and vim.api.nvim_win_is_valid(win), "opened")
	T.eq(vim.api.nvim_get_current_win(), origin) -- focus stays
	T.eq(preview.preview_link({ hover = true }), win) -- same link: kept
	preview.close()

	preview.setup({ on_hover = true, pattern = "*" })
	T.eq(#vim.api.nvim_get_autocmds({ group = "ZortexLinkPreviewHover", event = "CursorHold" }), 1)
	preview.setup({ on_hover = false })
	T.eq(#vim.api.nvim_get_autocmds({ group = "ZortexLinkPreviewHover" }), 0)
end)
