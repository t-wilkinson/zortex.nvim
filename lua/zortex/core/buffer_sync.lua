-- core/buffer_sync.lua
-- Buffer synchronization module - keeps buffer and document in sync
local M = {}

local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local attributes = require("zortex.utils.attributes")

-- Sync strategies
M.strategies = {
	-- Immediate sync - updates buffer right away
	IMMEDIATE = "immediate",
	-- Batched sync - collects changes and applies in batch
	BATCHED = "batched",
	-- On-save sync - only syncs when buffer is saved
	ON_SAVE = "on_save",
}

-- Default configuration
local config = {
	strategy = M.strategies.BATCHED,
	batch_delay = 500, -- ms
	max_batch_size = 50, -- max changes before forced sync
}

-- Pending changes queue
local pending_changes = {} -- bufnr -> { changes }
local sync_timers = {} -- bufnr -> timer

-- Change types
M.change_types = {
	TASK_TOGGLE = "task_toggle",
	TASK_UPDATE = "task_update",
	ATTRIBUTE_UPDATE = "attribute_update",
	SECTION_UPDATE = "section_update",
	TEXT_UPDATE = "text_update",
}

-- Create a change object
local function create_change(bufnr, change_type, data)
	return {
		bufnr = bufnr,
		type = change_type,
		timestamp = os.time(),
		data = data,
	}
end

-- Apply a single change to buffer
local function apply_change(change)
	local stop_timer = Logger.start_timer("buffer_sync.apply_change")

	local bufnr = change.bufnr
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	if change.type == M.change_types.TASK_TOGGLE then
		local lnum = change.data.lnum
		local line = lines[lnum]

		if line then
			-- Toggle task checkbox
			local new_line
			if change.data.completed then
				new_line = line:gsub("%[[ ]%]", "[x]", 1)
				-- Add done attribute
				new_line = attributes.update_done_attribute(new_line, true)
			else
				new_line = line:gsub("%[[xX]%]", "[ ]", 1)
				-- Remove done attribute
				new_line = attributes.update_done_attribute(new_line, false)
			end

			vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })

			Logger.debug("buffer_sync", "Applied task toggle", {
				lnum = lnum,
				completed = change.data.completed,
			})
		end
	elseif change.type == M.change_types.TASK_UPDATE then
		local lnum = change.data.lnum
		local line = lines[lnum]

		if line then
			local new_line = line

			-- Update each attribute
			for key, value in pairs(change.data.attributes or {}) do
				if value == nil then
					new_line = attributes.remove_attribute(new_line, key)
				else
					new_line = attributes.update_attribute(new_line, key, value)
				end
			end

			-- Update text if provided
			if change.data.text then
				local prefix = new_line:match("^(%s*%- %[.%] )")
				if prefix then
					-- Extract attributes from current line
					local _, attrs_text = attributes.strip_attributes(new_line, attributes.schemas.task)
					new_line = prefix .. change.data.text .. " " .. attrs_text
				end
			end

			vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })

			Logger.debug("buffer_sync", "Applied task update", {
				lnum = lnum,
				attributes = change.data.attributes,
			})
		end
	elseif change.type == M.change_types.ATTRIBUTE_UPDATE then
		local lnum = change.data.lnum
		local line = lines[lnum]

		if line then
			local new_line = line

			for key, value in pairs(change.data.attributes or {}) do
				if value == nil then
					new_line = attributes.remove_attribute(new_line, key)
				else
					new_line = attributes.update_attribute(new_line, key, value)
				end
			end

			vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })

			Logger.debug("buffer_sync", "Applied attribute update", {
				lnum = lnum,
				attributes = change.data.attributes,
			})
		end
	elseif change.type == M.change_types.TEXT_UPDATE then
		local start_line = change.data.start_line
		local end_line = change.data.end_line
		local new_lines = change.data.lines

		vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, new_lines)

		Logger.debug("buffer_sync", "Applied text update", {
			start_line = start_line,
			end_line = end_line,
			line_count = #new_lines,
		})
	end

	stop_timer({ change_type = change.type })
end

-- Apply all pending changes for a buffer
local function apply_pending_changes(bufnr)
	local changes = pending_changes[bufnr]
	if not changes or #changes == 0 then
		return
	end

	local stop_timer = Logger.start_timer("buffer_sync.apply_batch")

	Logger.info("buffer_sync", "Applying pending changes", {
		bufnr = bufnr,
		count = #changes,
	})

	-- Sort changes by line number to avoid conflicts
	table.sort(changes, function(a, b)
		local lnum_a = a.data.lnum or a.data.start_line or 0
		local lnum_b = b.data.lnum or b.data.start_line or 0
		return lnum_a < lnum_b
	end)

	-- Apply each change
	for _, change in ipairs(changes) do
		local ok, err = pcall(apply_change, change)
		if not ok then
			Logger.error("buffer_sync", "Failed to apply change", {
				change_type = change.type,
				error = err,
			})
		end
	end

	-- Clear pending changes
	pending_changes[bufnr] = {}

	-- Cancel timer
	if sync_timers[bufnr] then
		vim.fn.timer_stop(sync_timers[bufnr])
		sync_timers[bufnr] = nil
	end

	stop_timer({ change_count = #changes })

	-- Emit sync completed event
	EventBus.emit("buffer:synced", {
		bufnr = bufnr,
		change_count = #changes,
	})
end

-- Schedule a sync based on strategy
local function schedule_sync(bufnr)
	if config.strategy == M.strategies.IMMEDIATE then
		-- Apply immediately
		apply_pending_changes(bufnr)
	elseif config.strategy == M.strategies.BATCHED then
		-- Cancel existing timer
		if sync_timers[bufnr] then
			vim.fn.timer_stop(sync_timers[bufnr])
		end

		-- Schedule new sync
		sync_timers[bufnr] = vim.fn.timer_start(config.batch_delay, function()
			vim.schedule(function()
				apply_pending_changes(bufnr)
			end)
		end)

		-- Force sync if batch is too large
		if #(pending_changes[bufnr] or {}) >= config.max_batch_size then
			Logger.warn("buffer_sync", "Forcing sync due to large batch", {
				bufnr = bufnr,
				size = #pending_changes[bufnr],
			})
			apply_pending_changes(bufnr)
		end
	elseif config.strategy == M.strategies.ON_SAVE then
		-- Do nothing - will sync on save
	end
end

-- Public API

-- Queue a change for sync
function M.queue_change(bufnr, change_type, data)
	if not pending_changes[bufnr] then
		pending_changes[bufnr] = {}
	end

	local change = create_change(bufnr, change_type, data)
	table.insert(pending_changes[bufnr], change)

	Logger.debug("buffer_sync", "Queued change", {
		bufnr = bufnr,
		type = change_type,
		queue_size = #pending_changes[bufnr],
	})

	schedule_sync(bufnr)
end

-- Toggle task completion
function M.toggle_task(bufnr, lnum, completed)
	M.queue_change(bufnr, M.change_types.TASK_TOGGLE, {
		lnum = lnum,
		completed = completed,
	})
end

-- Update task attributes
function M.update_task(bufnr, lnum, attributes, text)
	M.queue_change(bufnr, M.change_types.TASK_UPDATE, {
		lnum = lnum,
		attributes = attributes,
		text = text,
	})
end

-- Update line attributes
function M.update_attributes(bufnr, lnum, attributes)
	M.queue_change(bufnr, M.change_types.ATTRIBUTE_UPDATE, {
		lnum = lnum,
		attributes = attributes,
	})
end

-- Update text lines
function M.update_text(bufnr, start_line, end_line, lines)
	M.queue_change(bufnr, M.change_types.TEXT_UPDATE, {
		start_line = start_line,
		end_line = end_line,
		lines = lines,
	})
end

-- Force sync for a buffer
function M.sync_buffer(bufnr)
	apply_pending_changes(bufnr)
end

-- Sync all buffers
function M.sync_all()
	for bufnr, _ in pairs(pending_changes) do
		apply_pending_changes(bufnr)
	end
end

-- Clear pending changes for a buffer
function M.clear_buffer(bufnr)
	pending_changes[bufnr] = nil
	if sync_timers[bufnr] then
		vim.fn.timer_stop(sync_timers[bufnr])
		sync_timers[bufnr] = nil
	end
end

-- Get pending changes for a buffer
function M.get_pending_changes(bufnr)
	return pending_changes[bufnr] or {}
end

-- Configure sync behavior
function M.configure(opts)
	config = vim.tbl_extend("force", config, opts or {})
	Logger.info("buffer_sync", "Configured", config)
end

-- Initialize module
function M.init()
	-- Listen for buffer events

	-- Sync on save if using ON_SAVE strategy
	EventBus.on("document:saved", function(data)
		if config.strategy == M.strategies.ON_SAVE then
			apply_pending_changes(data.bufnr)
		end
	end, {
		priority = 90,
		name = "buffer_sync_on_save",
	})

	-- Clear on buffer unload
	EventBus.on("document:unloaded", function(data)
		M.clear_buffer(data.bufnr)
	end, {
		priority = 90,
		name = "buffer_sync_cleanup",
	})

	-- Listen for document updates from services
	EventBus.on("task:updated", function(data)
		if data.task and data.bufnr then
			M.update_task(data.bufnr, data.task.line, data.updates.attributes, data.updates.text)
		end
	end, {
		priority = 80,
		name = "buffer_sync_task_update",
	})

	-- Setup autocmd for vim leave
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			-- Sync all buffers before exit
			M.sync_all()
		end,
	})

	Logger.info("buffer_sync", "Initialized")
end

-- Status information
function M.get_status()
	local status = {
		strategy = config.strategy,
		buffers_with_changes = vim.tbl_count(pending_changes),
		total_pending_changes = 0,
		active_timers = vim.tbl_count(sync_timers),
	}

	for _, changes in pairs(pending_changes) do
		status.total_pending_changes = status.total_pending_changes + #changes
	end

	return status
end

return M

