-- services/okr/objective.lua - Objective entities and key results
--
-- Every heading in the OKR article is an entity (so "# Current" is a
-- container); headings whose text looks like "3M-2026-Q1 Title" are
-- objectives. Key results are list items directly under an objective:
--   "- KR2: [ ] Make list of habits and routines [P/#1 Personal/#Habits]"
--
-- KR progress is computed from the projects it links to (points done / points
-- across their subtrees); a KR without project links uses its checkbox. A
-- checked KR always counts as done. Objective progress is the mean of its KRs.
local M = {}

local constants = require("zortex.constants")
local parser = require("zortex.utils.parser")
local attributes = require("zortex.utils.attributes")
local Entity = require("zortex.core.entity").Entity

local OBJECTIVE_SCHEMA = vim.tbl_extend("force", attributes.schemas.project, {
	created = { type = "date" },
})

-- Parse objective heading text -> { span, year, period, title } or nil
function M.parse_objective(text)
	local span, year, period, title = text:match(constants.PATTERNS.OBJECTIVE)
	if not span then
		span, year, period, title = text:match(constants.PATTERNS.OBJECTIVE_LEGACY)
	end
	if not span then
		return nil
	end
	return { span = span, year = tonumber(year), period = period, title = title }
end

-- Parse a key result line -> { id, text, completed, links } or nil
function M.parse_key_result(line)
	local num, rest = line:match(constants.PATTERNS.KEY_RESULT)
	if not rest then
		return nil
	end
	local mark, text = rest:match("^%[(.)%]%s*(.*)$")
	local links = {}
	for _, link in ipairs(parser.extract_all_links(rest)) do
		if link.type == "link" or link.type == "live_link" then
			links[#links + 1] = link.definition
		end
	end
	return {
		id = "KR" .. num,
		text = parser.strip_attributes(text or rest),
		completed = mark == "x" or mark == "X",
		links = links,
	}
end

-- =============================================================================
-- KeyResult
-- =============================================================================

local KeyResult = {}
KeyResult.__index = function(kr, k)
	-- `kr.projects` is computed on access (projects change independently of
	-- the OKR file), keyed by project key.
	if k == "projects" then
		return kr:linked_projects()
	end
	return KeyResult[k]
end
M.KeyResult = KeyResult

-- { [project_key] = Project } for every link on the KR's line that lands in
-- a project (via core/link_index).
function KeyResult:linked_projects()
	local projects = require("zortex.services.projects")
	local out = {}
	for _, ref in ipairs(require("zortex.core.link_index").links_from(self.file)) do
		if ref.lnum == self.lnum and ref.target then
			local p = projects.at(ref.target.file, ref.target.lnum)
			if p then
				out[p.key] = p
			end
		end
	end
	return out
end

-- Linked projects as a list, in key order
function KeyResult:project_list()
	local list = vim.tbl_values(self:linked_projects())
	table.sort(list, function(a, b)
		return a.key < b.key
	end)
	return list
end

-- 0..1: checked => 1; with linked projects => their points done / points;
-- otherwise 0.
function KeyResult:progress()
	if self.completed then
		return 1
	end
	local done, total = 0, 0
	for _, p in ipairs(self:project_list()) do
		local r = p:rollup()
		done, total = done + r.points_done, total + r.points
	end
	if total == 0 then
		return 0
	end
	return done / total
end

function KeyResult:is_done()
	return self.completed or self:progress() >= 1
end

-- =============================================================================
-- Objective
-- =============================================================================

local Objective = Entity:extend()
local base_index = Objective.__index
Objective.__index = function(o, k)
	-- key_results is parsed lazily (child entities are attached after init)
	if k == "key_results" then
		local krs = o:parse_key_results()
		rawset(o, "key_results", krs)
		return krs
	end
	return base_index[k]
end
M.Objective = Objective

function M.init(o)
	o.attributes = attributes.parse_attributes(o.doc.lines[o.lnum] or "", OBJECTIVE_SCHEMA)
	o.attributes.context = nil
	local info = o.kind == "heading" and M.parse_objective(o.name) or nil
	o.is_objective = info ~= nil
	if info then
		o.span, o.year, o.period, o.title = info.span, info.year, info.period, info.title
		o.id = string.format("%s_%d_%s_%s", info.span, info.year, info.period, (info.title:gsub("[^%w]", "_")))
		o.completed = o.attributes.done ~= nil
		o.section = o.parent and o.parent.name or nil -- e.g. "Current"
	end
end

function Objective:parse_key_results()
	local krs = {}
	if not self.is_objective then
		return krs
	end
	local s, e = self:own_range()
	for lnum = s + 1, e do
		local kr = M.parse_key_result(self.doc.lines[lnum])
		if kr then
			kr.lnum = lnum
			kr.file = self.file
			kr.objective = self
			krs[#krs + 1] = setmetatable(kr, KeyResult)
		end
	end
	return krs
end

-- Mean KR progress (1 when the objective is marked @done)
function Objective:progress()
	if self.completed then
		return 1
	end
	local krs = self.key_results
	if #krs == 0 then
		return 0
	end
	local sum = 0
	for _, kr in ipairs(krs) do
		sum = sum + kr:progress()
	end
	return sum / #krs
end

-- Areas from @a(...) (services/areas Area objects)
function Objective:areas()
	return require("zortex.services.areas").from_attributes(self.attributes)
end

-- Every project linked from this objective's KRs
function Objective:projects()
	local seen, out = {}, {}
	for _, kr in ipairs(self.key_results) do
		for _, p in ipairs(kr:project_list()) do
			if not seen[p.key] then
				seen[p.key] = true
				out[#out + 1] = p
			end
		end
	end
	return out
end

return M
