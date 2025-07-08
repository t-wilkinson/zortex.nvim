-- xp.lua - Experience Points system for Zortex
local M = {}

-- Dependencies
local calculator = require("zortex.xp.calculator")

-- Current configuration
M.config = {}

-- Setup function to initialize the XP system
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

-- Initialize with defaults
M.config = M.defaults

return M
