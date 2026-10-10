-- tests/run.lua - Minimal headless test runner (no plugin dependencies)
--
--   nvim --headless -u NONE -l tests/run.lua            # all tests
--   nvim --headless -u NONE -l tests/run.lua links      # files matching "links"
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

-- Point zortex at the fixture notes without running Config.setup (which
-- would create directories inside the fixtures).
local Config = require("zortex.config")
Config.notes_dir = root .. "/tests/fixtures/notes/"
Config.extension = ".zortex"

local T = require("helpers")
local filter = arg[1]
local files = vim.fn.glob(root .. "/tests/test_*.lua", false, true)
table.sort(files)
for _, file in ipairs(files) do
	if not filter or file:find(filter, 1, true) then
		T.file(vim.fn.fnamemodify(file, ":t"))
		local ok, err = pcall(dofile, file)
		if not ok then
			T.error(err)
		end
	end
end
os.exit(T.finish())
