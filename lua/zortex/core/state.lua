-- core/state.lua - Everything Zortex keeps outside the notes, one way
--
-- Each piece of state is one JSON file with a version number, in one of two
-- places:
--
--   synced   notes_dir/.z/<name>.json: travels with the notes (Syncthing,
--            Dropbox, git). Only what every device should share and that
--            changes rarely: seasons (xp_state), the last daily review.
--   device   stdpath("state")/zortex/<notes>-<hash>/<name>.json: this
--            machine's own. Caches and bookkeeping that every Neovim
--            rewrites often (the link index, search history, what was
--            announced or sent), so two devices never write the same file.
--
--   local State = require("zortex.core.state")
--   local history = State.open("search_history", {
--     version = 1,
--     device = true,
--     default = function() return { files = {}, sections = {} } end,
--   })
--   history:get()        -- the data table (loaded on first use)
--   history:save()       -- atomic write (temp file + rename), skipped when
--                        -- the content didn't change
--   history:reset()      -- back to default() and save
--   history:reload()     -- forget the in-memory copy
--
-- Loading never fails: a missing file gives default(); a file that is not
-- valid JSON is kept as <name>.json.corrupt-<time> and replaced by default();
-- a file with another version is replaced by default() (bump the version
-- when the shape of the data changes). A device file that doesn't exist yet
-- starts from the synced copy older versions wrote (.z/<name>.json).
--
-- Sync conflicts: a synced file with spec.merge(data, other) folds the
-- conflict copies a sync tool leaves next to it (Syncthing's
-- "<name>.sync-conflict-….json", Dropbox's "conflicted copy") into the data
-- when it loads, saves the result and deletes the copies.
--
-- Files: synced xp_state, review_state; device link_index, search_history,
-- xp_seen, notifications_state, starter.
local M = {}

local function notes_dir()
	return require("zortex.config").notes_dir or ""
end

local function with_slash(dir)
	if dir ~= "" and dir:sub(-1) ~= "/" then
		dir = dir .. "/"
	end
	return dir
end

--- Absolute path of a synced state file ("xp_state" -> notes_dir/.z/xp_state.json).
function M.path(name)
	return with_slash(notes_dir()) .. ".z/" .. name .. ".json"
end

--- This machine's state folder for the notes folder in use:
--- stdpath("state")/zortex/<folder name>-<hash of its path>.
function M.device_dir()
	local dir = vim.fn.fnamemodify(notes_dir(), ":p"):gsub("/$", "")
	local base = vim.fn.fnamemodify(dir, ":t"):gsub("[^%w%-_.]", "_")
	return vim.fn.stdpath("state") .. "/zortex/" .. (base ~= "" and base or "notes") .. "-" .. vim.fn.sha256(dir):sub(1, 8)
end

--- Absolute path of a device state file.
function M.device_path(name)
	return M.device_dir() .. "/" .. name .. ".json"
end

--- A short name for this machine (its host name), used where each device
--- writes its own synced file (services/xp/publish).
function M.device_name()
	local name = (require("zortex.config").device or vim.uv.os_gethostname() or "device"):lower()
	name = name:gsub("%..*$", ""):gsub("[^%w%-]", "-")
	return name ~= "" and name or "device"
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
	return data, nil, content
end

--- Write `content` to `path` atomically (temp file + rename).
function M.write_file(path, content)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local tmp = path .. ".tmp." .. vim.uv.getpid()
	local f = io.open(tmp, "w")
	if not f then
		return false, "cannot write " .. tmp
	end
	f:write(content)
	f:close()
	local renamed, err = vim.uv.fs_rename(tmp, path)
	if not renamed then
		os.remove(tmp)
		return false, err
	end
	return true
end

--- The conflict copies a sync tool left next to `path` (Syncthing's
--- "name.sync-conflict-….json", Dropbox's "name (… conflicted copy ….json").
function M.conflict_copies(path)
	local dir, file = vim.fn.fnamemodify(path, ":h"), vim.fn.fnamemodify(path, ":t")
	local stem = file:gsub("%.json$", "")
	local out = {}
	local fs = require("zortex.utils.filesystem")
	local handle = vim.uv.fs_scandir(dir)
	while handle do
		local name, kind = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if kind == "file" and name:sub(1, #stem) == stem and name:match("%.json$") and fs.is_conflict_copy(name) then
			out[#out + 1] = dir .. "/" .. name
		end
	end
	table.sort(out)
	return out
end

local State = {}
State.__index = State

--- A state file handle. Handles are cached by name.
--- spec: { version, default(), device?, merge(data, other)? }
local handles = {}

function M.open(name, spec)
	if handles[name] then
		return handles[name]
	end
	local s = setmetatable({
		name = name,
		version = spec.version or 1,
		device = spec.device or false,
		merge = spec.merge,
		default = spec.default or function()
			return {}
		end,
		data = nil,
		written = nil, -- the JSON last read or written: an unchanged save writes nothing
	}, State)
	handles[name] = s
	return s
end

function State:path()
	return self.device and M.device_path(self.name) or M.path(self.name)
end

-- The file's data (nil when missing, corrupt or of another version)
function State:load(path)
	local data, err, content = read(path)
	if err == "corrupt" then
		os.rename(path, path .. ".corrupt-" .. os.time())
	end
	if data and data.version ~= self.version then
		return nil
	end
	return data, content
end

function State:get()
	if self.data then
		return self.data
	end
	local path = self:path()
	local data, content = self:load(path)
	if not data and self.device then
		-- written by an older version into the synced folder
		data = self:load(M.path(self.name))
		content = nil
	end
	if not data then
		data = self.default()
	end
	data.version = self.version
	self.data, self.written = data, content
	if self.merge and not self.device then
		self:merge_conflicts(path)
	end
	return data
end

--- Fold the sync tool's conflict copies of this (synced) file into the data,
--- save, and delete them. Returns how many were merged.
function State:merge_conflicts(path)
	local copies = M.conflict_copies(path or self:path())
	local merged = 0
	for _, copy in ipairs(copies) do
		local other = read(copy)
		if other and other.version == self.version then
			self.data = self.merge(self.data, other) or self.data
			self.data.version = self.version
			merged = merged + 1
		end
	end
	if #copies > 0 then
		local ok = self:save()
		if ok then
			for _, copy in ipairs(copies) do
				os.remove(copy)
			end
		end
	end
	return merged
end

function State:save()
	local data = self:get()
	local ok, json = pcall(vim.json.encode, data)
	if not ok then
		return false, json
	end
	if json == self.written then
		return true
	end
	local written, err = M.write_file(self:path(), json)
	if written then
		self.written = json
	end
	return written, err
end

function State:reset()
	self.data = self.default()
	self.data.version = self.version
	return self:save()
end

function State:reload()
	self.data, self.written = nil, nil
end

return M
