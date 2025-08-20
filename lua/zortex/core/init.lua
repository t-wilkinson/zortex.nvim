-- core/init.lua - Initialize core systems: Events, Doc, and Services
local M = {}

local Events = require("zortex.core.event_bus")
local workspace = require("zortex.core.workspace")
local Logger = require("zortex.core.logger")

-- Services
local PersistenceManager = require("zortex.stores.persistence_manager")

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

	-- Initialize services
	require("zortex.stores.xp").setup(opts.xp)
	require("zortex.services.xp").init()
	require("zortex.services.xp.notifications").init()
	require("zortex.services.xp.calculator").setup(opts.xp)
	-- require("zortex.services.xp.distributor").setup(opts.xp.distribution_rules)
	-- require("zortex.services.xp.notifications").init()
	-- require("zortex.services.xp.commands").setup()

	-- Initialize persistence manager
	PersistenceManager.setup(opts.core.persistence_manager)

	stop_timer()
end

-- =============================================================================
-- Status and Debugging
-- =============================================================================

-- Get system status
function M.get_status()
	return {
		event_bus = Events.get_performance_report(),
		workspace = {},
		persistence = PersistenceManager.get_status(),
	}
end

-- Print status report
function M.print_status()
	local status = M.get_status()
	print(vim.inspect(status))
end

return M
