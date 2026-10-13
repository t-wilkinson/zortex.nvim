-- features/migrate: old-style bold headings
local T = require("helpers")
local migrate = require("zortex.features.migrate")

T.test("old bold headings convert; others are left alone", function()
	T.eq(migrate.convert("**Next steps**"), "**Next steps:**")
	T.eq(migrate.convert("  **Ideas**:"), "  **Ideas:**")
	T.eq(migrate.convert("**Done:**"), nil)
	T.eq(migrate.convert("**bold** and more"), nil)
	T.eq(migrate.convert("**a *b* c**"), nil)
	T.eq(migrate.convert("**:**"), nil)
end)

T.test("scan finds them outside code, apply rewrites only those", function()
	local path = vim.fn.tempname() .. ".zortex"
	vim.fn.writefile({ "@@M", "", "**Old**", "**Old style**:", "**New:**", "```", "**In code**", "```", "Text **bold**" }, path)
	local changes = migrate.scan({ path })
	T.eq(#changes, 2)
	T.eq(changes[1].new, "**Old:**")
	T.eq(migrate.apply(changes), 2)
	T.eq(vim.fn.readfile(path), { "@@M", "", "**Old:**", "**Old style:**", "**New:**", "```", "**In code**", "```", "Text **bold**" })
	T.eq(#migrate.scan({ path }), 0)
end)
