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

--- The number the next season gets: one more than the highest "Season N"
--- heading of the OKR note, else one more than the seasons ended so far.
function M.next_season_number(lines)
	local n = 0
	for _, line in ipairs(lines or okr_lines()) do
		local k = line:match("^#+%s.-[Ss]eason%s+(%d+)")
		n = math.max(n, tonumber(k) or 0)
	end
	if n == 0 then
		n = #require("zortex.stores.xp").season_history()
	end
	return n + 1
end

--- "Season 10 Juniper": the next number, and its word from xp.season.names.
function M.next_season_name(lines)
	local n = M.next_season_number(lines)
	local names = ((require("zortex.config").xp or {}).season or {}).names
	if names == nil then
		names = M.SEASON_NAMES
	end
	if type(names) == "table" and #names > 0 then
		return string.format("Season %d %s", n, names[(n - 1) % #names + 1])
	end
	return "Season " .. n
end

--- A span in the objectives' format ("3M-2026-Q4", "1M-2026-11",
--- "6M-2026-H2") -> { span, start_date, end_date }, or nil.
function M.parse_span(span)
	local length, year, period = tostring(span or ""):match("^(%d*[MQHYmqhy])%-(%d%d%d%d)%-(%w+)$")
	if not length then
		return nil
	end
	local s, e = ObjectiveModule.window(length, year, period)
	if not s then
		return nil
	end
	return { span = span:upper(), start_date = s, end_date = e }
end

--- The calendar quarter around `date` as a span: "3M-2026-Q4".
function M.quarter_span(date)
	local q = ObjectiveModule.quarter(date)
	local y, n = q.name:match("^(%d+) Q(%d)$")
	return string.format("3M-%s-Q%s", y, n)
end

--- Add "# <span> <name>" to the OKR note (above its first top-level
--- heading, so the newest season is on top), unless a top-level heading
--- already starts with the span. Only for organizing: objectives keep
--- their own windows. Returns the heading's line number, or nil, err.
function M.add_season_heading(span, name)
	local workspace = require("zortex.core.workspace")
	local file = fs.get_okr_file()
	if not file then
		return nil, "no OKR note"
	end
	workspace.ensure_file(file, { "@@Objectives", "@@OKR", "" })
	local lines = okr_lines()
	local first
	for lnum, line in ipairs(lines) do
		local text = line:match("^#%s+(.*)$")
		if text then
			if text:upper():sub(1, #span + 1) == (span:upper() .. " ") or text:upper() == span:upper() then
				return lnum
			end
			first = first or lnum
		end
	end
	local heading = "# " .. span .. (name and name ~= "" and (" " .. name) or "")
	local ok, err, at
	if first then
		at = first
		ok, err = workspace.insert_lines(file, first, { heading, "" })
	else
		local add = { heading }
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(add, 1, "")
		end
		at = #lines + #add
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
