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

-- Pre-existing: these require modules that are not in the repository
-- (zortex.services.calendar, zortex.services.xp).
local KNOWN_BROKEN = { ["zortex.ui.calendar"] = true, ["zortex.ui.skill_tree"] = true }

local root = require("zortex.config").notes_dir:gsub("/tests/fixtures/notes/$", "")
local files = vim.fn.globpath(root .. "/lua", "zortex/**/*.lua", false, true)
table.sort(files)
for _, file in ipairs(files) do
	local mod = file:match("lua/(zortex/.*)%.lua$"):gsub("/init$", ""):gsub("/", ".")
	if KNOWN_BROKEN[mod] then
		print("  skip require " .. mod .. " (depends on a module missing from the repo)")
		goto continue
	end
	T.test("require " .. mod, function()
		local ok, err = pcall(require, mod)
		T.ok(ok, tostring(err))
	end)
	::continue::
end
