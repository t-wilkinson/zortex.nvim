-- tests/run.lua - Minimal headless test runner (no plugin dependencies)
--
--   nvim --headless -u NONE -l tests/run.lua            # all tests
--   nvim --headless -u NONE -l tests/run.lua links      # files matching "links"
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

-- Work on a throwaway copy of the fixture notes: stores (XP state, ...)
-- create files inside notes_dir. Config.setup is skipped on purpose.
local notes_dir = vim.fn.tempname() .. "/notes/"
vim.fn.mkdir(notes_dir, "p")
vim.fn.system({ "cp", "-r", root .. "/tests/fixtures/notes/.", notes_dir })
local Config = require("zortex.config")
Config.notes_dir = notes_dir
Config.extension = ".zortex"

local T = require("helpers")
T.root = root
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
