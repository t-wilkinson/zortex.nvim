-- core/init.lua - Initialize core systems: Events, Doc, and Services
local M = {}

local Events = require("zortex.core.event_bus")
local Doc = require("zortex.core.document_manager")
local Logger = require("zortex.core.logger")
local buffer_sync = require("zortex.core.buffer_sync")

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

	Doc.init()
	buffer_sync.setup(opts.core.buffer_sync)

	-- Initialize services
	require("zortex.services.xp").init()
	require("zortex.services.xp.calculator").setup(opts.xp)
	require("zortex.services.xp.distributor").setup(opts.xp.distribution_rules)
	require("zortex.services.xp.notifications").init()
	require("zortex.services.areas").init()
	-- require("zortex.services.projects.progress").init() -- Let's migrate away from using progress attribute

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
		document_manager = {
			buffer_count = vim.tbl_count(Doc._instance.buffers),
			file_count = vim.tbl_count(Doc._instance.files),
		},
		buffer_sync = buffer_sync.get_status(),
		persistence = PersistenceManager.get_status(),
	}
end

-- Print status report
function M.print_status()
	local status = M.get_status()
	print(vim.inspect(status))
end

-- Get service references (for direct access)
function M.get_services()
	return {
		document_manager = Doc,
		persistence = PersistenceManager,
		event_bus = Events,
		buffer_sync = buffer_sync,
	}
end

return M
