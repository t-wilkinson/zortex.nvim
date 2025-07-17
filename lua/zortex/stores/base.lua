-- stores/base.lua - Base store class for all data persistence
local M = {}
local M_mt = { __index = M }

local fs = require("zortex.core.filesystem")

-- Create a new store instance
function M:new(filename)
	local store = {
		filename = filename,
		data = {},
		loaded = false,
	}
	setmetatable(store, M_mt)
	return store
end

-- Get the full path for this store's data file
function M:get_path()
	return fs.get_file_path(self.filename)
end

-- Load data from disk
function M:load()
	local path = self:get_path()
	if not path then
		self:init_empty()
		return false
	end

	if fs.file_exists(path) then
		local loaded = fs.read_json(path)
		if loaded then
			self.data = loaded
			self.loaded = true
			self:migrate()
			return true
		end
	end

	self:init_empty()
	return false
end

-- Save data to disk
function M:save()
	local path = self:get_path()
	if not path then
		return false
	end

	return fs.write_json(path, self.data)
end

-- Initialize with empty data (override in subclasses)
function M:init_empty()
	self.data = {}
	self.loaded = true
end

-- Migrate old data formats (override in subclasses)
function M:migrate()
	-- Override in subclasses if needed
end

-- Ensure the store is loaded
function M:ensure_loaded()
	if not self.loaded then
		self:load()
	end
end

return M

