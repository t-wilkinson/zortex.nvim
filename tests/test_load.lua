-- Every module must load without the optional plugins (pickers and
-- completion engines are required only when used).
local T = require("helpers")

local root = T.root
local files = vim.fn.globpath(root .. "/lua", "zortex/**/*.lua", false, true)
table.sort(files)
for _, file in ipairs(files) do
	local mod = file:match("lua/(zortex/.*)%.lua$"):gsub("/init$", ""):gsub("/", ".")
	T.test("require " .. mod, function()
		local ok, err = pcall(require, mod)
		T.ok(ok, tostring(err))
	end)
end
