-- Every module must load (telescope is stubbed; it's an optional dependency).
local T = require("helpers")

local stub = setmetatable({}, {
	__index = function(t, k)
		return function() end
	end,
})
for _, name in ipairs({
	"telescope",
	"telescope.pickers",
	"telescope.finders",
	"telescope.config",
	"telescope.actions",
	"telescope.actions.state",
	"telescope.previewers",
	"telescope.sorters",
	"telescope.themes",
	"telescope.make_entry",
	"telescope.pickers.entry_display",
}) do
	package.preload[name] = package.preload[name] or function()
		return setmetatable({ values = stub }, { __index = stub })
	end
end

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
