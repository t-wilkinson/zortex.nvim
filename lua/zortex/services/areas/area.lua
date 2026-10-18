-- services/areas/area.lua - The Area object (PARA areas of responsibility)
--
-- Areas live in the Areas article. Headings, bold headings and labels are
-- areas; deeper ones are sub-areas:
--   # 1 Personal Foundation
--   ## 1.2 Vitality
--   Fitness:                 <- area "Areas/1 Personal Foundation/1.2 Vitality/Fitness"
--
-- Links start with the A namespace: "[A/#1 Personal Foundation/#1.2 Vitality/:Fitness]".
--
-- A "Vision:" in an area's own lines says what good looks like there
-- (area:vision()); the weekly review opens with it:
--   ## 1.1 Health
--   Vision: strong enough to carry the kids up a mountain at 60
-- Area keys are also the keys XP is recorded under.
local M = {}

local Entity = require("zortex.core.entity").Entity

local Area = Entity:extend()
M.Area = Area

local function xp_store()
	return require("zortex.stores.xp")
end

local function ledger()
	return require("zortex.services.xp.ledger")
end

-- Share of a sub-area's XP that also counts for its parent (xp.area.bubble)
local function bubble()
	local xp = require("zortex.config").xp or {}
	return (xp.area and xp.area.bubble) or 0.75
end

-- XP earned directly by this area (from the ledger, all time)
function Area:xp(l)
	return ((l or ledger().get({ cached = true })).area_xp[self.key] or 0)
end

-- This area's XP plus `bubble` (75%) of each sub-area's total, recursively:
-- progress in a sub-skill counts towards the broader one.
function Area:total_xp(l)
	l = l or ledger().get({ cached = true })
	local total = self:xp(l)
	local b = bubble()
	for _, child in ipairs(self.children) do
		total = total + b * child:total_xp(l)
	end
	return total
end

-- { xp, total_xp, level, progress } where level/progress come from total XP.
function Area:xp_data(l)
	local store = xp_store()
	l = l or ledger().get({ cached = true })
	local data = { xp = self:xp(l), total_xp = self:total_xp(l) }
	local ok, level = pcall(store.calculate_area_level, data.total_xp)
	if ok and level then
		data.level = level
		local okp, progress = pcall(store.get_level_progress, data.total_xp, level, store.calculate_area_level_xp)
		data.progress = okp and progress.progress or nil
	end
	return data
end

local function linked(area, target, descendants)
	if not target then
		return false
	end
	if descendants then
		return area:contains(target)
	end
	return target.key == area.key
end

-- Projects that belong to this area (a project's areas are inherited from its
-- nearest ancestor that declares @a(...)). opts.descendants includes projects
-- of sub-areas.
---@param opts { descendants?: boolean }?
function Area:projects(opts)
	opts = opts or {}
	local out = {}
	for _, project in ipairs(require("zortex.services.projects").all()) do
		for _, area in ipairs(project:areas({ inherit = true })) do
			if linked(self, area, opts.descendants) then
				out[#out + 1] = project
				break
			end
		end
	end
	return out
end

-- Objectives whose @a(...) points at this area (or a sub-area with
-- opts.descendants).
---@param opts { descendants?: boolean }?
function Area:objectives(opts)
	opts = opts or {}
	local areas = require("zortex.services.areas")
	local out = {}
	for _, objective in ipairs(require("zortex.services.okr").objectives()) do
		for _, area in ipairs(areas.from_attributes(objective.attributes)) do
			if linked(self, area, opts.descendants) then
				out[#out + 1] = objective
				break
			end
		end
	end
	return out
end


--- What good looks like in this area: the text of a "Vision:" line in its
--- own lines ("Vision: …", or "Vision:" with the lines under it up to a
--- blank line), or nil.
function Area:vision()
	local lines = self:lines()
	for i, line in ipairs(lines) do
		local rest = line:match("^%s*[Vv]ision:%s*(.-)%s*$")
		if rest then
			local parts = {}
			if rest ~= "" then
				parts[1] = rest
			else
				for j = i + 1, #lines do
					local l = lines[j]
					if not l:match("%S") or l:match("^#") or l:match("^%S.*:%s*$") then
						break
					end
					parts[#parts + 1] = vim.trim((l:gsub("^%s*[-*]%s+", "")))
				end
			end
			return #parts > 0 and table.concat(parts, " ") or nil
		end
	end
	return nil
end

return M
