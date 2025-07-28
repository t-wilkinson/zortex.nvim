-- core/init.lua - Initialize core systems: EventBus, DocumentManager, and Services
local M = {}

local EventBus = require("zortex.core.event_bus")
local DocumentManager = require("zortex.core.document_manager")
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
		EventBus.add_middleware(function(event, data)
			Logger.debug("event", event, data)
			return true, data
		end)
	end

	DocumentManager.init()
	buffer_sync.setup(opts.core.buffer_sync)

	-- Initialize services
	require("zortex.services.xp").init()
	require("zortex.services.xp.calculator").setup(opts.xp)
	require("zortex.services.xp.distributor").setup(opts.xp.distribution_rules)

	require("zortex.services.projects.progress").init()

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
		event_bus = EventBus.get_performance_report(),
		document_manager = {
			buffer_count = vim.tbl_count(DocumentManager._instance.buffers),
			file_count = vim.tbl_count(DocumentManager._instance.files),
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
		document_manager = DocumentManager,
		persistence = PersistenceManager,
		event_bus = EventBus,
		buffer_sync = buffer_sync,
	}
end

return M
