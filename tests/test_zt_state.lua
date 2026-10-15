local T = require("helpers")
local State = require("zortex.core.state")

T.test("state files: default, save, reload, versions, corrupt files", function()
	local s = State.open("test_state", {
		version = 2,
		default = function()
			return { n = 0 }
		end,
	})
	local path = s:path()
	T.ok(path:match("/%.z/test_state%.json$"), path)
	os.remove(path)
	s:reload()
	T.eq(s:get().n, 0)
	s:get().n = 5
	s:save()
	s:reload()
	T.eq(s:get(), { n = 5, version = 2 })

	-- another version (or none) is replaced by the default
	vim.fn.writefile({ '{"n": 4, "version": 1}' }, path)
	s:reload()
	T.eq(s:get(), { n = 0, version = 2 })
	vim.fn.writefile({ '{"n": 4}' }, path)
	s:reload()
	T.eq(s:get().n, 0)

	-- corrupt files are kept aside and replaced by the default
	vim.fn.writefile({ "{not json" }, path)
	s:reload()
	T.eq(s:get().n, 0)
	T.ok(#vim.fn.glob(path .. ".corrupt-*", false, true) == 1, "corrupt copy kept")
	for _, f in ipairs(vim.fn.glob(path .. "*", false, true)) do
		os.remove(f)
	end
end)
