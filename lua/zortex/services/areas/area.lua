-- services/areas/area.lua - The Area object (PARA areas of responsibility)
--
-- Areas live in the Areas article. Headings, bold headings and labels are
-- areas; deeper ones are sub-areas:
--   # 1 Personal Foundation
--   ## 1.2 Vitality
--   Fitness:                 <- area "Areas/1 Personal Foundation/1.2 Vitality/Fitness"
--
-- Links start with the A namespace: "[A/#1 Personal Foundation/#1.2 Vitality/:Fitness]".
-- Area keys are also the keys XP is recorded under.
local M = {}

local Entity = require("zortex.core.entity").Entity

local Area = Entity:extend()
M.Area = Area

local function xp_store()
	return require("zortex.stores.xp")
end

-- XP earned directly by this area
function Area:xp()
	return xp_store().get_area_xp(self.key) or 0
end

-- XP of this area and all sub-areas
function Area:total_xp()
	local total = 0
	self:walk(function(a)
		total = total + a:xp()
	end)
	return total
end

-- { xp, total_xp, level, progress } where level/progress come from total XP.
-- level/progress are nil until the XP store is configured (stores/xp.setup).
function Area:xp_data()
	local store = xp_store()
	local data = { xp = self:xp(), total_xp = self:total_xp() }
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
	for _, objective in ipairs(require("zortex.services.okr").get_objectives()) do
		for _, area in ipairs(areas.from_attributes(objective.attributes)) do
			if linked(self, area, opts.descendants) then
				out[#out + 1] = objective
				break
			end
		end
	end
	return out
end

return M
