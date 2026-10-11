-- tests/gen_ast.lua - Regenerate the syntax conformance fixtures
--
--   nvim --headless -u NONE -l tests/gen_ast.lua
--
-- Writes core/syntax output (with inline spans) for every fixture note to
-- tests/fixtures/ast/<name>.json. test_syntax.lua checks the parser against
-- these files; an implementation of the Zortex grammar in another language
-- (e.g. the web app) can use the same pairs as its test suite.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local syntax = require("zortex.core.syntax")

-- Pretty JSON with sorted keys, so diffs stay readable
local function encode(value, indent)
	indent = indent or ""
	local t = type(value)
	if t == "table" then
		local n = #value
		local is_array = n > 0 or next(value) == nil
		if is_array then
			for k in pairs(value) do
				if type(k) ~= "number" then
					is_array = false
					break
				end
			end
		end
		local inner = indent .. "  "
		local parts = {}
		if is_array then
			if n == 0 then
				return "[]"
			end
			for i = 1, n do
				parts[#parts + 1] = inner .. encode(value[i], inner)
			end
			return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
		end
		local keys = vim.tbl_keys(value)
		table.sort(keys)
		for _, k in ipairs(keys) do
			parts[#parts + 1] = inner .. vim.json.encode(tostring(k)) .. ": " .. encode(value[k], inner)
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
	end
	return vim.json.encode(value)
end

local M = {}

function M.sources()
	local out = {}
	for _, dir in ipairs({ "notes", "syntax" }) do
		local base = root .. "/tests/fixtures/" .. dir .. "/"
		for _, path in ipairs(vim.fn.globpath(base, "**/*.zortex", false, true)) do
			out[#out + 1] = { path = path, name = dir .. "/" .. path:sub(#base + 1):gsub("%.zortex$", "") }
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

function M.ast_path(name)
	return root .. "/tests/fixtures/ast/" .. name .. ".json"
end

function M.parse(path)
	return syntax.parse(vim.fn.readfile(path), { inline = true })
end

if not package.loaded["helpers"] then
	for _, src in ipairs(M.sources()) do
		local out = M.ast_path(src.name)
		vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
		vim.fn.writefile(vim.split(encode(M.parse(src.path)), "\n"), out)
		print("wrote " .. out)
	end
	os.exit(0)
end

return M
