-- Runs last: full plugin setup touches global state (autocmds, commands).
local T = require("helpers")

T.test("require('zortex').setup() succeeds with user overrides", function()
	local notes_dir = require("zortex.config").notes_dir
	local ok, err = pcall(require("zortex").setup, { notes_dir = notes_dir, ui = { search = { max_results = 9 } } })
	T.ok(ok, tostring(err))
	T.eq(require("zortex.ui.telescope.search").config.max_results, 9)
	T.eq(require("zortex.ui.telescope.search").config.default_mode, "section")
end)

T.test("calendar opens and every day can be selected", function()
	local view = require("zortex.ui.calendar.view")
	local ok, err = pcall(view.open)
	T.ok(ok, tostring(err))
	-- Walk the selection across ~two months with the "next day" key, so every
	-- cell is selected, including the ones with wide icons.
	local moved_ok, moved_err = pcall(function()
		for _ = 1, 62 do
			vim.cmd("normal l")
		end
		vim.cmd("normal t") -- back to today
	end)
	T.ok(moved_ok, tostring(moved_err))
	pcall(view.close)
end)
