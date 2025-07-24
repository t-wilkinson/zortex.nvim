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
	local stop_timer = Logger.start_timer("core.init")

	-- Initialize logger with config
	Logger.setup(opts.core.logger)

	-- Set up global error handler for events
	if opts.core.logger.log_events then
		EventBus.add_middleware(function(event, data)
			Logger.debug("event", event, data)
			return true, data
		end)
	end

	-- Initialize DocumentManager
	DocumentManager.setup(opts)
	Logger.info("core", "DocumentManager initialized")

	-- Initialize buffer sync
	buffer_sync.setup()
	Logger.info("core", "Buffer sync initialized")

	-- Initialize XP system
	-- require("zortex.utils.xp.core").setup(opts.xp)
	-- require("zortex.utils.xp.distributor").init()
	-- Logger.info("core", "XP Distributor initialized")

	-- Initialize persistence manager
	PersistenceManager.setup(opts.core.persistence_manager)
	Logger.info("core", "Persistence Manager initialized")

	stop_timer()

	Logger.info("core", "All systems initialized")

	-- Emit initialization complete event
	EventBus.emit("core:initialized", {
		timestamp = os.time(),
	})
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
