-- core/utils.lua

local M = {}

-- More lightweight copy
function M.clone(t)
	local c = {}
	for k, v in pairs(t) do
		c[k] = type(v) == "table" and M.clone(v) or v
	end
	return c
end

-- Deepcopy, even copies keys
function M.deepcopy(orig)
	local orig_type = type(orig)
	local copy
	if orig_type == "table" then
		copy = {}
		for orig_key, orig_value in next, orig, nil do
			copy[M.deepcopy(orig_key)] = M.deepcopy(orig_value)
		end
		setmetatable(copy, M.deepcopy(getmetatable(orig)))
	else
		copy = orig
	end
	return copy
end

function M.wrap(fn, error_msg)
	return function(...)
		local ok, result = pcall(fn, ...)
		if not ok then
			vim.notify(error_msg .. ": " .. tostring(result), vim.log.levels.ERROR, {
				title = "Zortex Error",
			})
			return nil
		end
		return result
	end
end
return M
