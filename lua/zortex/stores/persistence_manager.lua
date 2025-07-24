-- stores/persistence_manager.lua - Manages coordinated persistence of all stores
local M = {}

local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")

-- configurationn
local cfg = {}

-- State
local state = {
	dirty_stores = {}, -- store_name -> true
	save_timer = nil,
	is_saving = false,
	registered_stores = {}, -- store_name -> store_module
}

-- =============================================================================
-- Store Registration
-- =============================================================================

-- Register a store for managed persistence
function M.register_store(name, store_module)
	if not store_module.save then
		Logger.warn("persistence_manager", "Store missing save method", { store = name })
		return false
	end

	state.registered_stores[name] = store_module
	Logger.debug("persistence_manager", "Registered store", { store = name })
	return true
end

-- Register all default stores
function M.register_defaults()
	local stores_to_register = {
		{ "xp", require("zortex.stores.xp") },
		{ "tasks", require("zortex.stores.tasks") },
		{ "areas", require("zortex.stores.areas") },
		{ "calendar", require("zortex.stores.calendar") },
		{ "notifications", require("zortex.stores.notifications") },
	}

	for _, store_info in ipairs(stores_to_register) do
		local name, module = store_info[1], store_info[2]
		M.register_store(name, module)
	end
end

-- =============================================================================
-- Dirty Tracking
-- =============================================================================

-- Mark a store as dirty (needs saving)
function M.mark_dirty(store_name)
	if not state.registered_stores[store_name] then
		Logger.warn("persistence_manager", "Unknown store marked dirty", { store = store_name })
		return
	end

	state.dirty_stores[store_name] = true
	M.schedule_save()

	Logger.debug("persistence_manager", "Store marked dirty", {
		store = store_name,
		dirty_count = vim.tbl_count(state.dirty_stores),
	})
end

-- Check if any stores are dirty
function M.has_dirty_stores()
	return vim.tbl_count(state.dirty_stores) > 0
end

-- Get list of dirty stores
function M.get_dirty_stores()
	local dirty = {}
	for store_name, _ in pairs(state.dirty_stores) do
		table.insert(dirty, store_name)
	end
	return dirty
end

-- =============================================================================
-- Save Scheduling
-- =============================================================================

-- Schedule a save operation
function M.schedule_save()
	if not cfg.batch_saves then
		-- Immediate save mode
		M.save_all()
		return
	end

	-- Cancel existing timer
	if state.save_timer then
		vim.fn.timer_stop(state.save_timer)
	end

	-- Schedule new save
	state.save_timer = vim.fn.timer_start(cfg.save_interval, function()
		vim.schedule(function()
			M.save_all()
		end)
	end)

	Logger.debug("persistence_manager", "Save scheduled", {
		interval = cfg.save_interval,
	})
end

-- Cancel scheduled save
function M.cancel_scheduled_save()
	if state.save_timer then
		vim.fn.timer_stop(state.save_timer)
		state.save_timer = nil
	end
end

-- =============================================================================
-- Save Operations
-- =============================================================================

-- Save all dirty stores
function M.save_all()
	if state.is_saving then
		Logger.warn("persistence_manager", "Save already in progress")
		return { saved = {}, errors = {} }
	end

	if not M.has_dirty_stores() then
		Logger.debug("persistence_manager", "No dirty stores to save")
		return { saved = {}, errors = {} }
	end

	local stop_timer = Logger.start_timer("persistence_manager.save_all")
	state.is_saving = true

	local results = {
		saved = {},
		errors = {},
		start_time = os.time(),
	}

	-- Save each dirty store
	for store_name, _ in pairs(state.dirty_stores) do
		local store = state.registered_stores[store_name]
		if store then
			local ok, err = pcall(store.save, store)

			if ok then
				table.insert(results.saved, store_name)
				Logger.debug("persistence_manager", "Store saved", { store = store_name })
			else
				results.errors[store_name] = err
				Logger.error("persistence_manager", "Store save failed", {
					store = store_name,
					error = err,
				})
			end
		end
	end

	-- Clear dirty flags for successful saves
	for _, store_name in ipairs(results.saved) do
		state.dirty_stores[store_name] = nil
	end

	state.is_saving = false
	results.end_time = os.time()

	stop_timer({
		saved_count = #results.saved,
		error_count = vim.tbl_count(results.errors),
	})

	-- Emit save completed event
	EventBus.emit("stores:saved", results)

	-- Show notification if there were errors
	if vim.tbl_count(results.errors) > 0 then
		local error_stores = vim.tbl_keys(results.errors)
		vim.notify(string.format("Failed to save stores: %s", table.concat(error_stores, ", ")), vim.log.levels.ERROR)
	end

	return results
end

-- Force save a specific store
function M.save_store(store_name)
	local store = state.registered_stores[store_name]
	if not store then
		return false, "Store not registered: " .. store_name
	end

	local ok, err = pcall(store.save, store)
	if ok then
		state.dirty_stores[store_name] = nil
		Logger.info("persistence_manager", "Store saved", { store = store_name })
		return true
	else
		Logger.error("persistence_manager", "Store save failed", {
			store = store_name,
			error = err,
		})
		return false, err
	end
end

-- =============================================================================
-- Event Handlers
-- =============================================================================

-- Handle XP events
local function handle_xp_events(data)
	M.mark_dirty("xp")
end

-- Handle task events
local function handle_task_events(data)
	M.mark_dirty("tasks")
end

-- Handle area events
local function handle_area_events(data)
	M.mark_dirty("areas")
end

-- Handle calendar events
local function handle_calendar_events(data)
	M.mark_dirty("calendar")
end

-- =============================================================================
-- Initialization
-- =============================================================================

-- Initialize persistence manager
function M.init(opts)
	cfg = opts
	local stop_timer = Logger.start_timer("persistence_manager.init")

	-- Register default stores
	M.register_defaults()

	-- Set up event listeners if enabled
	if cfg.save_on_events then
		-- XP events
		EventBus.on("xp:awarded", handle_xp_events, {
			priority = 20,
			name = "persistence_xp_awarded",
		})
		EventBus.on("xp:distributed", handle_xp_events, {
			priority = 20,
			name = "persistence_xp_distributed",
		})

		-- Task events
		EventBus.on("task:completed", handle_task_events, {
			priority = 20,
			name = "persistence_task_completed",
		})
		EventBus.on("task:uncompleted", handle_task_events, {
			priority = 20,
			name = "persistence_task_uncompleted",
		})
		EventBus.on("task:created", handle_task_events, {
			priority = 20,
			name = "persistence_task_created",
		})
		EventBus.on("task:updated", handle_task_events, {
			priority = 20,
			name = "persistence_task_updated",
		})

		-- Area events
		EventBus.on("area:xp_added", handle_area_events, {
			priority = 20,
			name = "persistence_area_xp",
		})

		-- Calendar events
		EventBus.on("calendar:entry_added", handle_calendar_events, {
			priority = 20,
			name = "persistence_calendar_add",
		})
		EventBus.on("calendar:entry_removed", handle_calendar_events, {
			priority = 20,
			name = "persistence_calendar_remove",
		})
	end

	-- Set up exit handler if enabled
	if cfg.save_on_exit then
		vim.api.nvim_create_autocmd("VimLeavePre", {
			callback = function()
				M.cancel_scheduled_save()
				M.save_all()
			end,
			desc = "Save all dirty stores on exit",
		})
	end

	Logger.info("persistence_manager", "Initialized", {
		registered_stores = vim.tbl_keys(state.registered_stores),
		save_interval = cfg.save_interval,
		save_on_exit = cfg.save_on_exit,
		save_on_events = cfg.save_on_events,
	})

	stop_timer()
end

-- =============================================================================
-- Status and Debugging
-- =============================================================================

-- Get current status
function M.get_status()
	return {
		is_saving = state.is_saving,
		has_timer = state.save_timer ~= nil,
		dirty_stores = vim.tbl_keys(state.dirty_stores),
		registered_stores = vim.tbl_keys(state.registered_stores),
		cfg = cfg,
	}
end

-- Debug: force mark all stores dirty
function M.debug_mark_all_dirty()
	for store_name, _ in pairs(state.registered_stores) do
		state.dirty_stores[store_name] = true
	end
	Logger.debug("persistence_manager", "All stores marked dirty")
end

return M
