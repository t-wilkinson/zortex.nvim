-- core/state.lua - Everything Zortex keeps in notes_dir/.z, one way
--
-- Each piece of state is one JSON file in notes_dir/.z with a version number:
--
--   local State = require("zortex.core.state")
--   local history = State.open("search_history", {
--     version = 1,
--     default = function() return { files = {}, sections = {} } end,
--   })
--   history:get()        -- the data table (loaded on first use)
--   history:save()       -- atomic write (temp file + rename)
--   history:reset()      -- back to default() and save
--   history:reload()     -- forget the in-memory copy
--
-- Loading never fails: a missing file gives default(); a file that is not
-- valid JSON is kept as <name>.json.corrupt-<time> and replaced by default();
-- a file with another version is replaced by default() (bump the version
-- when the shape of the data changes).
--
-- Files: link_index, search_history, xp_state, notifications_state.
local M = {}

local function notes_dir()
	return require("zortex.config").notes_dir or ""
end

--- Absolute path of a state file ("search_history" -> notes_dir/.z/search_history.json).
function M.path(name)
	local dir = notes_dir()
	if dir ~= "" and dir:sub(-1) ~= "/" then
		dir = dir .. "/"
	end
	return dir .. ".z/" .. name .. ".json"
end

local function read(path)
	local f = io.open(path, "r")
	if not f then
		return nil, "missing"
	end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
	if not ok or type(data) ~= "table" then
		return nil, "corrupt"
	end
	return data
end

local function write(path, data)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local ok, json = pcall(vim.json.encode, data)
	if not ok then
		return false, json
	end
	local tmp = path .. ".tmp." .. vim.uv.getpid()
	local f = io.open(tmp, "w")
	if not f then
		return false, "cannot write " .. tmp
	end
	f:write(json)
	f:close()
	local renamed, err = vim.uv.fs_rename(tmp, path)
	if not renamed then
		os.remove(tmp)
		return false, err
	end
	return true
end

local State = {}
State.__index = State

--- A state file handle. Handles are cached by name.
local handles = {}

function M.open(name, spec)
	if handles[name] then
		return handles[name]
	end
	local s = setmetatable({
		name = name,
		version = spec.version or 1,
		default = spec.default or function()
			return {}
		end,
		data = nil,
	}, State)
	handles[name] = s
	return s
end

function State:path()
	return M.path(self.name)
end

function State:get()
	if self.data then
		return self.data
	end
	local path = self:path()
	local data, err = read(path)
	if err == "corrupt" then
		os.rename(path, path .. ".corrupt-" .. os.time())
	end
	if data and data.version ~= self.version then
		data = nil
	end
	if not data then
		data = self.default()
	end
	data.version = self.version
	self.data = data
	return data
end

function State:save()
	return write(self:path(), self:get())
end

function State:reset()
	self.data = self.default()
	self.data.version = self.version
	return self:save()
end

function State:reload()
	self.data = nil
end

--- Drop every in-memory copy (notes_dir changed, tests).
function M.reload_all()
	for _, s in pairs(handles) do
		s.data = nil
	end
end

return M
