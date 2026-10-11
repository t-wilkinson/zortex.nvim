local T = require("helpers")
local archive = require("zortex.features.archive")

T.test("archiving a section merges it under the same ancestors", function()
	local path = T.fixture("archtest.zortex")
	local archive_path = T.fixture("z/archive.archtest.zortex")
	vim.fn.writefile({
		"@@Archive test",
		"",
		"# Done",
		"## First",
		"- [x] one",
		"## Second",
		"- [x] two",
		"# Keep",
	}, path)
	vim.cmd("edit! " .. vim.fn.fnameescape(path))

	vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- inside "## First"
	archive.archive_current_section()
	T.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
		"@@Archive test",
		"",
		"# Done",
		"## Second",
		"- [x] two",
		"# Keep",
	})
	T.eq(vim.fn.readfile(archive_path), { "@@Archive test", "@Archive", "", "# Done", "## First", "- [x] one" })

	-- A sibling lands under the existing "# Done"
	vim.api.nvim_win_set_cursor(0, { 5, 0 })
	archive.archive_current_section()
	T.eq(vim.fn.readfile(archive_path), {
		"@@Archive test",
		"@Archive",
		"",
		"# Done",
		"## First",
		"- [x] one",
		"## Second",
		"- [x] two",
	})

	vim.cmd("bwipeout!")
	vim.fn.delete(path)
	vim.fn.delete(archive_path)
	require("zortex.core.notes").invalidate()
end)
