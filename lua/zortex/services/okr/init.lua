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

-- =============================================================================
-- Seasons in the OKR note
-- =============================================================================

M.parse_season = ObjectiveModule.parse_season

-- Season words, alphabetical, so the letter moves on with the number:
-- Season 1 Aspen, Season 2 Birch, … Season 10 Juniper. xp.season.names
-- replaces them (false: numbers only).
M.SEASON_NAMES = {
	"Aspen", "Birch", "Cedar", "Dogwood", "Elm", "Fir", "Ginkgo", "Hazel",
	"Ironwood", "Juniper", "Kapok", "Larch", "Maple", "Nutmeg", "Oak", "Pine",
	"Quince", "Rowan", "Spruce", "Teak", "Walnut", "Yew", "Zelkova",
}

local function okr_lines()
	return require("zortex.core.workspace").get_lines(fs.get_okr_file())
end

--- The season headings of the OKR note (objective.season_headings).
function M.season_headings(lines)
	return ObjectiveModule.season_headings(lines or okr_lines())
end

--- The number the next season gets: one more than the highest "Season N"
--- in the OKR note, else one more than the seasons ended so far.
function M.next_season_number(lines)
	local n = 0
	for _, s in ipairs(M.season_headings(lines)) do
		n = math.max(n, tonumber(s.name:match("[Ss]eason%s+(%d+)")) or 0)
	end
	if n == 0 then
		n = math.max(#M.season_headings(lines), #require("zortex.stores.xp").season_history())
	end
	return n + 1
end

--- "Season 10 Juniper": the next number, and its word from xp.season.names.
function M.next_season_name(lines)
	local n = M.next_season_number(lines)
	local season_cfg = ((require("zortex.config").xp or {}).season or {})
	local names = season_cfg.names
	if names == nil then
		names = M.SEASON_NAMES
	end
	if type(names) == "table" and #names > 0 then
		return string.format("Season %d %s", n, names[(n - 1) % #names + 1])
	end
	return "Season " .. n
end

--- The token a season heading starts with: "2026-Q4" when the season is a
--- calendar quarter, else its start date.
function M.season_token(start_date, end_date)
	local q = ObjectiveModule.quarter(start_date)
	if q.start_date == start_date and (end_date == nil or q.end_date == end_date) then
		return (q.name:gsub("^(%d+) Q(%d)$", "%1-Q%2"))
	end
	return start_date
end

--- Add "# <token> <name>" to the OKR note for a new season, above the
--- newest season heading (or the first top-level heading), so the new
--- season's objectives go under it. Nothing when a heading for that start
--- already exists. Returns the line number of the heading, or nil, err.
function M.add_season_heading(name, start_date, end_date)
	local workspace = require("zortex.core.workspace")
	local file = fs.get_okr_file()
	if not file then
		return nil, "no OKR note"
	end
	workspace.ensure_file(file, { "@@OKR", "" })
	local lines = okr_lines()
	for _, s in ipairs(M.season_headings(lines)) do
		if s.level == 1 and s.start == start_date then
			return s.lnum
		end
	end
	local token = M.season_token(start_date, end_date)
	local heading = "# " .. token .. (name and name ~= "" and (" " .. name) or "")
	-- above the first top-level heading; at the end when there is none
	local at
	for lnum, line in ipairs(lines) do
		if line:match("^#%s") then
			at = lnum
			break
		end
	end
	local ok, err
	if at then
		ok, err = workspace.insert_lines(file, at, { heading, "" })
	else
		local add = { heading }
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(add, 1, "")
		end
		at = #lines + 1 + (#add - 1)
		ok, err = workspace.insert_lines(file, #lines + 1, add)
	end
	if not ok then
		return nil, err
	end
	return at
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
