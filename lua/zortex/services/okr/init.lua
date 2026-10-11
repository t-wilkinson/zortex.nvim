-- services/okr/init.lua - Objectives and key results as entities
--
--   local O = require("zortex.services.okr")
--   O.objectives({ current = true })       -- Objective entities
--   O.get("Objectives/Current/3M-2026-Q1 Establish and maintain good habits/routine")
--   O.resolve("[O/#3M-2026-Q1 Establish]")
--   O.key_results()                         -- every KR
--   O.get_key_results(project)              -- KRs linking to a project (+ their objectives)
--   objective:progress() / kr:progress()    -- computed from linked projects
--
-- Links start with the O namespace: "[O/#Current/#3M-2026-Q1 Establish …]".
local M = {}

local entity = require("zortex.core.entity")
local fs = require("zortex.utils.filesystem")
local ObjectiveModule = require("zortex.services.okr.objective")

M.Objective = ObjectiveModule.Objective
M.KeyResult = ObjectiveModule.KeyResult
M.parse_objective = ObjectiveModule.parse_objective
M.parse_key_result = ObjectiveModule.parse_key_result

local function normalize(path)
	return vim.fn.fnamemodify(path, ":p")
end

local registry = entity.registry({
	kind = "okr",
	namespace = "O",
	class = ObjectiveModule.Objective,
	init = ObjectiveModule.init,
	keep = function(node)
		return node.type == "heading"
	end,
	sources = function()
		return { fs.get_okr_file() }
	end,
	is_source = function(doc)
		return doc.filepath == normalize(fs.get_okr_file())
	end,
})

for name, fn in pairs(registry) do
	M[name] = fn
end

-- Objectives in document order. opts.current: only those not marked @done.
---@param opts { current?: boolean }?
function M.objectives(opts)
	opts = opts or {}
	return M.all({
		filter = function(o)
			return o.is_objective and not (opts.current and o.completed)
		end,
	})
end

-- Backwards-compatible names
function M.get_objectives()
	return M.objectives()
end

function M.get_current_objectives()
	return M.objectives({ current = true })
end

-- Every key result, in document order. opts.open: only KRs not done.
---@param opts { open?: boolean }?
function M.key_results(opts)
	opts = opts or {}
	local out = {}
	for _, o in ipairs(M.objectives()) do
		for _, kr in ipairs(o.key_results) do
			if not (opts.open and kr:is_done()) then
				out[#out + 1] = kr
			end
		end
	end
	return out
end

-- Key results linking to a project (Project, key or link), and the objective
-- of each (index-aligned).
function M.get_key_results(project_ref)
	local project = require("zortex.services.projects").lookup(project_ref)
	if not project then
		return {}, {}
	end
	local key_results, objectives = {}, {}
	for _, kr in ipairs(M.key_results()) do
		if kr.projects[project.key] then
			key_results[#key_results + 1] = kr
			objectives[#objectives + 1] = kr.objective
		end
	end
	return key_results, objectives
end

return M
