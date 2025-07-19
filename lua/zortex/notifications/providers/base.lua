-- notifications/providers/base.lua - Base provider interface
local M = {}

-- Provider interface that all providers should implement
M.interface = {
	name = "base",

	-- Setup the provider with configuration
	setup = function(config) end,

	-- Send a notification
	-- @param title string The notification title
	-- @param message string The notification message
	-- @param options table Additional options (priority, tags, etc.)
	-- @param config table Provider-specific configuration
	-- @return boolean success, string error_message
	send = function(title, message, options, config)
		error("Provider must implement send method")
	end,

	-- Test the provider
	test = function()
		return false, "Not implemented"
	end,
}

-- Helper to create a new provider
function M.create_provider(name, implementation)
	local provider = vim.tbl_deep_extend("force", M.interface, implementation)
	provider.name = name
	return provider
end

return M