-- core/init.lua - Initialize core systems: Events, Doc, and Services
local M = {}

local Events = require("zortex.core.event_bus")
local workspace = require("zortex.core.workspace")
local Logger = require("zortex.core.logger")

-- =============================================================================
-- System Initialization
-- =============================================================================

function M.setup(opts)
	Logger.setup(opts.core.logger)

	local stop_timer = Logger.start_timer("core.init")

	-- Set up global error handler for events
	if opts.core.logger.log_events then
		Events.add_middleware(function(event, data)
			Logger.debug("event", event, data)
			return true, data
		end)
	end

	workspace.setup()
	require("zortex.core.link_index").setup()

	-- Initialize services
	-- XP: derived from the notes (services/xp/ledger), announced on change
	require("zortex.stores.xp").setup(opts.xp)
	require("zortex.services.xp.calculator").setup(opts.xp)
	require("zortex.services.xp.core").init(opts.xp)
	require("zortex.services.xp.notifications").init()

	stop_timer()
end

return M
