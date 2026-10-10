-- tests/helpers.lua - tiny assertion helpers for tests/run.lua
local T = { passed = 0, failed = 0, current = "" }

function T.file(name)
	T.current = name
	print("\n" .. name)
end

function T.error(err)
	T.failed = T.failed + 1
	print("  ERROR " .. tostring(err))
end

function T.test(name, fn)
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		T.passed = T.passed + 1
		print("  ok   " .. name)
	else
		T.failed = T.failed + 1
		print("  FAIL " .. name .. "\n" .. tostring(err))
	end
end

function T.eq(actual, expected, msg)
	if not vim.deep_equal(actual, expected) then
		error(
			string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", vim.inspect(expected), vim.inspect(actual)),
			2
		)
	end
end

function T.ok(value, msg)
	if not value then
		error(msg or "expected truthy value", 2)
	end
end

function T.fixture(name)
	return require("zortex.config").notes_dir .. name
end

function T.finish()
	print(string.format("\n%d passed, %d failed", T.passed, T.failed))
	return T.failed == 0 and 0 or 1
end

return T
