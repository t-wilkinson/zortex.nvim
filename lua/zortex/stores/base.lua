-- stores/base.lua - Base store class for persistence
local M = {}
M.__index = M

local Config = require("zortex.config")
local Logger = require("zortex.core.logger")

-- Create a new store instance
function M:new(filepath)
	local store = setmetatable({}, self)

	-- Build full path
	if filepath:sub(1, 1) == "/" or filepath:sub(1, 1) == "~" then
		store.filepath = vim.fn.expand(filepath)
	else
		store.filepath = Config.notes_dir .. "/" .. filepath
	end

	store.data = {}
	store.loaded = false
	store.dirty = false

	return store
end

-- Initialize empty data (override in subclasses)
function M:init_empty()
	self.data = {}
	self.loaded = true
end

-- Load data from file
function M:load()
	local stop_timer = Logger.start_timer("store.load")

	if self.loaded then
		stop_timer()
		return true
	end

	-- Check if file exists
	if vim.fn.filereadable(self.filepath) == 0 then
		Logger.debug("store", "File not found, initializing empty", {
			filepath = self.filepath,
		})
		self:init_empty()
		self:save() -- Create the file
		stop_timer()
		return true
	end

	-- Read file
	local file = io.open(self.filepath, "r")
	if not file then
		Logger.error("store", "Failed to open file", {
			filepath = self.filepath,
		})
		self:init_empty()
		stop_timer()
		return false
	end

	local content = file:read("*all")
	file:close()

	-- Parse JSON
	local ok, data = pcall(vim.json.decode, content)
	if not ok then
		Logger.error("store", "Failed to parse JSON", {
			filepath = self.filepath,
			error = data,
		})

		-- Backup corrupted file
		local backup_path = self.filepath .. ".backup." .. os.time()
		vim.fn.rename(self.filepath, backup_path)
		Logger.warn("store", "Backed up corrupted file", {
			backup = backup_path,
		})

		self:init_empty()
		self:save()
		stop_timer()
		return false
	end

	self.data = data or {}
	self.loaded = true
	self.dirty = false

	Logger.debug("store", "Loaded successfully", {
		filepath = self.filepath,
		size = #content,
	})

	stop_timer()
	return true
end

-- Save data to file
function M:save()
	local stop_timer = Logger.start_timer("store.save")

	if not self.loaded then
		Logger.warn("store", "Attempting to save unloaded store", {
			filepath = self.filepath,
		})
		stop_timer()
		return false
	end

	-- Ensure directory exists
	local dir = vim.fn.fnamemodify(self.filepath, ":h")
	vim.fn.mkdir(dir, "p")

	-- Encode to JSON
	local ok, json = pcall(vim.json.encode, self.data)
	if not ok then
		Logger.error("store", "Failed to encode JSON", {
			filepath = self.filepath,
			error = json,
		})
		stop_timer()
		return false
	end

	-- Write atomically (write to temp file then rename)
	local temp_path = self.filepath .. ".tmp." .. vim.loop.getpid()
	local file = io.open(temp_path, "w")
	if not file then
		Logger.error("store", "Failed to open temp file", {
			filepath = temp_path,
		})
		stop_timer()
		return false
	end

	file:write(json)
	file:close()

	-- Rename temp file to actual file
	local rename_ok = vim.loop.fs_rename(temp_path, self.filepath)
	if not rename_ok then
		Logger.error("store", "Failed to rename temp file", {
			temp = temp_path,
			target = self.filepath,
		})
		vim.fn.delete(temp_path)
		stop_timer()
		return false
	end

	self.dirty = false

	Logger.debug("store", "Saved successfully", {
		filepath = self.filepath,
		size = #json,
	})

	-- Emit save event
	require("zortex.core.event_bus").emit("store:saved", {
		filepath = self.filepath,
		store_type = self.store_type or "generic",
	})

	stop_timer()
	return true
end

-- Ensure store is loaded before operations
function M:ensure_loaded()
	if not self.loaded then
		self:load()
	end
end

-- Mark store as dirty (needs save)
function M:mark_dirty()
	self.dirty = true

	-- Register with persistence manager if available
	local ok, pm = pcall(require, "zortex.stores.persistence_manager")
	if ok then
		pm.mark_dirty(self.store_type or vim.fn.fnamemodify(self.filepath, ":t:r"))
	end
end

-- Get data with optional default
function M:get(key, default)
	self:ensure_loaded()
	local value = self.data[key]
	if value == nil then
		return default
	end
	return value
end

-- Set data value
function M:set(key, value)
	self:ensure_loaded()
	self.data[key] = value
	self:mark_dirty()
end

-- Update multiple values
function M:update(updates)
	self:ensure_loaded()
	for key, value in pairs(updates) do
		self.data[key] = value
	end
	self:mark_dirty()
end

-- Clear all data
function M:clear()
	self.data = {}
	self.loaded = true
	self:mark_dirty()
end

-- Get store status
function M:get_status()
	return {
		filepath = self.filepath,
		loaded = self.loaded,
		dirty = self.dirty,
		exists = vim.fn.filereadable(self.filepath) == 1,
		size = self.loaded and vim.json.encode(self.data):len() or 0,
	}
end

return M
