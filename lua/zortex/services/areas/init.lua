-- services/areas/init.lua - Areas as first-class objects
--
--   local A = require("zortex.services.areas")
--   A.roots()                     -- the Areas article
--   A.all({ leaf = true })
--   A.get("Areas/1 Personal Foundation/1.2 Vitality")
--   A.resolve("[A/#1.2]")         -- same rules as following the link
--   A.resolve("Areas/#4.1")       -- what @a(4.1) expands to
--   A.at(bufnr_or_path, lnum)     -- area containing a line
--   A.top(5)                      -- areas by total XP
--   area:projects() / area:objectives() / area:xp_data()
local M = {}

local entity = require("zortex.core.entity")
local fs = require("zortex.utils.filesystem")
local AreaModule = require("zortex.services.areas.area")

M.Area = AreaModule.Area

local AREA_TYPES = { heading = true, bold_heading = true, label = true }

local function normalize(path)
	return vim.fn.fnamemodify(path, ":p")
end

local registry = entity.registry({
	kind = "area",
	namespace = "A",
	class = AreaModule.Area,
	keep = function(node)
		return AREA_TYPES[node.type] == true
	end,
	sources = function()
		return { fs.get_areas_file() }
	end,
	is_source = function(doc)
		return doc.filepath == normalize(fs.get_areas_file())
	end,
})

for name, fn in pairs(registry) do
	M[name] = fn
end

-- =============================================================================
-- Area links in attributes
-- =============================================================================

-- Resolve @a(...)/@area(...) attribute values to Area objects (unresolvable
-- links are skipped; see M.resolve_links for the details).
function M.from_attributes(attrs)
	local out = {}
	for _, item in ipairs(M.resolve_links(attrs)) do
		if item.area then
			out[#out + 1] = item.area
		end
	end
	return out
end

-- Resolutions of @a(...) definitions. The same few areas are named by
-- hundreds of projects and tasks, so each is resolved once per notes
-- snapshot (core/notes keeps one for a second, as link resolution does).
local memo = { idx = nil, areas = {} }

local function resolve_cached(definition)
	local idx = require("zortex.core.notes").index()
	if memo.idx ~= idx then
		memo = { idx = idx, areas = {} }
	end
	local area = memo.areas[definition]
	if area == nil then
		area = M.resolve(definition) or false
		memo.areas[definition] = area
	end
	return area or nil
end

-- Every @a(...) link with its resolution: { link, definition, area? }
function M.resolve_links(attrs)
	local out = {}
	for _, a in ipairs(attrs and attrs.area or {}) do
		out[#out + 1] = { link = a.link, definition = a.definition, area = resolve_cached(a.definition) }
	end
	return out
end

-- Unique area keys for a set of XP sources (tasks, projects, objectives).
-- Projects inherit areas from their ancestors.
function M.keys_for(...)
	local keys, seen = {}, {}
	local function add(area)
		if area and not seen[area.key] then
			seen[area.key] = true
			keys[#keys + 1] = area.key
		end
	end
	for _, source in ipairs({ ... }) do
		if type(source) == "table" then
			if source.areas and getmetatable(source) then
				for _, area in ipairs(source:areas({ inherit = true })) do
					add(area)
				end
			elseif source.attributes then
				for _, area in ipairs(M.from_attributes(source.attributes)) do
					add(area)
				end
			end
		end
	end
	return keys
end

-- Backwards-compatible name
M.extract_area_paths = M.keys_for

-- =============================================================================
-- XP views
-- =============================================================================

-- The area tree for the mastery tree UI (root = the Areas article)
function M.get_area_tree()
	return M.roots()[1]
end

-- Areas ranked by total XP (sub-areas included), highest first
function M.top(limit)
	local ranked = {}
	local l = require("zortex.services.xp.ledger").get()
	for _, area in ipairs(M.all({ include_roots = false })) do
		local data = area:xp_data(l)
		if data.total_xp > 0 then
			ranked[#ranked + 1] = { area = area, name = area.name, key = area.key, xp = data.total_xp, level = data.level }
		end
	end
	table.sort(ranked, function(a, b)
		return a.xp > b.xp
	end)
	if limit and #ranked > limit then
		ranked = vim.list_slice(ranked, 1, limit)
	end
	return ranked
end
M.get_top_areas = M.top

return M
