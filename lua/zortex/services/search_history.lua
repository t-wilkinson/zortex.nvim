-- services/search_history.lua - What you open from search, with decay
--
-- Every result opened from the structural search is recorded in
-- this machine's state folder (core/state, a device file: search_history.json):
--
--   files     per note, a frecency score that decays by `access_decay_rate`
--             per day (Config.ui.search.access_decay_rate)
--   sections  per section (keyed by note + breadcrumb, so it survives edits
--             that move lines), a score that decays by history.score_decay
--             per day; ancestors receive history.propagation_decay of it per
--             level. Only the history.max_entries strongest are kept.
--
-- A score is stored as (value, time) and decayed on read:
--   value(now) = value * exp(-rate * days_since(time))
-- Recording adds 1 to the decayed value. Search adds file_boost and
-- section_boost to a result's score, so frequently and recently opened
-- places rank higher.
local M = {}

local VERSION = 1
local DAY = 86400
local FILE_WEIGHT, SECTION_WEIGHT = 50, 30 -- score points per log-unit (match quality is 100/point)

local store = require("zortex.core.state").open("search_history", {
	version = VERSION,
	device = true, -- rewritten on every pick: this machine's own
	default = function()
		return { files = {}, sections = {} }
	end,
})

local function cfg()
	local search = require("zortex.services.search")
	return (search.config or search.setup()) or {}
end

local function data()
	local d = store:get()
	d.files = d.files or {}
	d.sections = d.sections or {}
	return d
end

local function save()
	store:save()
end

local function decayed(entry, rate, now)
	if not entry then
		return 0
	end
	local days = math.max(0, (now - (entry.time or now)) / DAY)
	return (entry.value or 0) * math.exp(-(rate or 0) * days)
end

local function bump(map, key, amount, rate, now)
	map[key] = { value = decayed(map[key], rate, now) + amount, time = now }
end

local function normalize(path)
	if path:sub(1, 1) == "/" and not path:find("/%.%.?/") then
		return path -- already absolute (the common case; keeps search fast)
	end
	return vim.fn.fnamemodify(path, ":p")
end

local function section_key(path, breadcrumb)
	return normalize(path) .. "\n" .. breadcrumb
end

-- Keep only the strongest `max` sections; drop files that decayed to ~0.
local function prune(d, now)
	local c = cfg()
	local history = c.history or {}
	local max = history.max_entries or 50
	local keys = vim.tbl_keys(d.sections)
	if #keys > max then
		table.sort(keys, function(a, b)
			return decayed(d.sections[a], history.score_decay, now) > decayed(d.sections[b], history.score_decay, now)
		end)
		for i = max + 1, #keys do
			d.sections[keys[i]] = nil
		end
	end
	for path, entry in pairs(d.files) do
		if decayed(entry, c.access_decay_rate, now) < 0.01 then
			d.files[path] = nil
		end
	end
end

--- Record that a search result was opened.
---@param result table { filepath, node? (Section) }
---@param now integer? os.time() override (tests)
function M.record(result, now)
	if not result or not result.filepath then
		return
	end
	now = now or os.time()
	local c = cfg()
	local d = data()
	bump(d.files, normalize(result.filepath), 1, c.access_decay_rate, now)

	local history = c.history or {}
	if history.enabled ~= false and result.node and not result.node:is_root() then
		local weight = 1
		local node = result.node
		while node and not node:is_root() do
			bump(d.sections, section_key(result.filepath, node:get_breadcrumb(" › ")), weight, history.score_decay, now)
			weight = weight * (history.propagation_decay or 0.7)
			node = node.parent
		end
	end

	prune(d, now)
	save()
end

--- Decayed access score of a note.
function M.file_score(path, now)
	return decayed(data().files[normalize(path)], cfg().access_decay_rate, now or os.time())
end

--- Decayed history score of a section (by note + breadcrumb).
function M.section_score(path, breadcrumb, now)
	local history = cfg().history or {}
	if history.enabled == false then
		return 0
	end
	return decayed(data().sections[section_key(path, breadcrumb)], history.score_decay, now or os.time())
end

--- Score points search adds for a note (frequently/recently opened notes).
function M.file_boost(path, now)
	return FILE_WEIGHT * math.log(1 + M.file_score(path, now))
end

--- Score points search adds for a section (and, via propagation, its parents).
function M.section_boost(path, breadcrumb, now)
	return SECTION_WEIGHT * math.log(1 + M.section_score(path, breadcrumb, now))
end

--- Forget everything (memory and disk).
function M.clear()
	store:reset()
end

-- Test hook: drop the in-memory copy (next read loads from disk)
function M._reload()
	store:reload()
end

return M
