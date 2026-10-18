-- features/join: J drops line-start markers and a label's colon
local T = require("helpers")
local join = require("zortex.features.join")

local function joined(lines, count, first)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "" -- keep the ftplugin out of it
	join.join(first or 1, count)
	local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	vim.api.nvim_buf_delete(buf, { force = true })
	return out
end

T.test("headings: the joined line's #s go", function()
	T.eq(joined({ "# Heading", "## more words" })[1], "# Heading more words")
end)

T.test("lists: the joined line's - (and checkbox) or number go", function()
	T.eq(joined({ "- first item", "- second item" })[1], "- first item second item")
	T.eq(joined({ "- [ ] Buy milk", "    - [x] and eggs @id(abcde)" })[1], "- [ ] Buy milk and eggs @id(abcde)")
	T.eq(joined({ "1. one", "2. two" })[1], "1. one two")
	-- a time is content, not a marker
	T.eq(joined({ "- Meet", "14:00 Lunch" })[1], "- Meet 14:00 Lunch")
end)

T.test("labels: the first line's colon goes", function()
	T.eq(joined({ "Fitness:", "- run 5k" })[1], "Fitness run 5k")
	T.eq(joined({ "*A longer label like this:*", "text" })[1], "*A longer label like this* text")
	T.eq(joined({ "**Next steps:**", "ship it" })[1], "**Next steps** ship it")
	-- not a label (four words): kept
	T.eq(joined({ "A line of four words:", "next" })[1], "A line of four words: next")
end)

T.test("quotes, counts and plain text", function()
	T.eq(joined({ "> quoted", "> more" })[1], "> quoted more")
	T.eq(joined({ "- a", "- b", "- c", "- d" }, 3), { "- a b c", "- d" })
	T.eq(joined({ "plain", "text" })[1], "plain text")
	-- the last line: nothing to join
	T.eq(joined({ "only" }), { "only" })
end)

T.test("code blocks are joined as written", function()
	T.eq(joined({ "```", "# not a heading", "- not a bullet", "```" }, 2, 2)[2], "# not a heading - not a bullet")
end)

T.test("J is one undo step and . repeats it", function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(buf)
	vim.bo[buf].undolevels = 100
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- a", "- b", "- c" })
	vim.cmd("let &undolevels = &undolevels") -- an undo point
	join.attach(buf)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.api.nvim_feedkeys("J", "xt", false)
	T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "- a b", "- c" })
	vim.api.nvim_feedkeys(".", "xt", false)
	T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "- a b c" })
	vim.cmd("silent undo")
	T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "- a b", "- c" })
	vim.api.nvim_buf_delete(buf, { force = true })
end)
