-- tests/json.lua - pretty JSON with sorted keys, so generated fixtures are
-- the same on every run (CI checks they are up to date)
local M = {}

function M.encode(value, indent)
	indent = indent or ""
	if type(value) ~= "table" then
		return vim.json.encode(value)
	end
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
			parts[#parts + 1] = inner .. M.encode(value[i], inner)
		end
		return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
	end
	local keys = vim.tbl_keys(value)
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for _, k in ipairs(keys) do
		parts[#parts + 1] = inner .. vim.json.encode(tostring(k)) .. ": " .. M.encode(value[k], inner)
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

return M
