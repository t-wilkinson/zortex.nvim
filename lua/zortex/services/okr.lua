-- services/okr.lua - Objectives and key results
--
-- Objectives are headings whose (attribute-free) text looks like
--   "3M-2026-Q1 Establish and maintain good habits/routine"
-- Key results are list items under an objective:
--   "- KR2: [ ] Make list of habits and routines [P/#1 Personal/#Habits]"
-- Links inside a KR are resolved with the shared link resolver; links that land
-- in a project are recorded by project KEY, so "[P/#1.4 - zortex]" and
-- "[Projects/#1 Programming/#1.4 - zortex]" refer to the same project.
local M = {}

local constants = require("zortex.constants")
local parser = require("zortex.utils.parser")
local attributes = require("zortex.utils.attributes")
local Document = require("zortex.core.document")
local fs = require("zortex.utils.filesystem")

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

local function okr_file()
	return fs.get_okr_file()
end

local cache = { doc = nil, signature = nil, objectives = nil }

-- All objectives, in document order:
-- { id, name, span, year, period, title, attributes, completed, lnum, file,
--   path, section, key_results = { { id, text, completed, links, lnum,
--   objective, projects = { [project_key] = Project } } } }
function M.get_objectives()
	local doc = Document.get(okr_file())
	if not doc then
		return {}
	end
	local signature = require("zortex.services.projects").signature()
	if cache.doc == doc and cache.signature == signature then
		return cache.objectives
	end

	local projects = require("zortex.services.projects")
	local objectives = {}

	doc.tree:walk(function(node)
		if node.type ~= "heading" then
			return
		end
		local info = M.parse_objective(node.text)
		if not info then
			return
		end

		local attrs = attributes.parse_attributes(doc.lines[node.start_line] or "", OBJECTIVE_SCHEMA)
		local path = node:path_texts()
		local objective = {
			id = string.format("%s_%d_%s_%s", info.span, info.year, info.period, (info.title:gsub("[^%w]", "_"))),
			name = node.text,
			span = info.span,
			year = info.year,
			period = info.period,
			title = info.title,
			attributes = attrs,
			completed = attrs.done ~= nil,
			lnum = node.start_line,
			file = doc.filepath,
			path = path,
			section = path[#path - 1], -- e.g. "Current"
			node = node,
			key_results = {},
		}

		for lnum = node.start_line + 1, node:get_direct_end_line() do
			local kr = M.parse_key_result(doc.lines[lnum])
			if kr then
				kr.lnum = lnum
				kr.file = doc.filepath
				kr.objective = objective
				kr.projects = {}
				for _, def in ipairs(kr.links) do
					local project = projects.resolve(def)
					if project then
						kr.projects[project.key] = project
					end
				end
				table.insert(objective.key_results, kr)
			end
		end

		table.insert(objectives, objective)
	end)

	cache.doc, cache.signature, cache.objectives = doc, signature, objectives
	return objectives
end

-- Objectives that are not marked done
function M.get_current_objectives()
	return vim.tbl_filter(function(o)
		return not o.completed
	end, M.get_objectives())
end

-- Key results linking to a project (Project, key or link). Also returns the
-- objective of each key result, index-aligned.
function M.get_key_results(project_ref)
	local project = require("zortex.services.projects").lookup(project_ref)
	if not project then
		return {}, {}
	end
	local key_results, objectives = {}, {}
	for _, objective in ipairs(M.get_objectives()) do
		for _, kr in ipairs(objective.key_results) do
			if kr.projects[project.key] then
				table.insert(key_results, kr)
				table.insert(objectives, objective)
			end
		end
	end
	return key_results, objectives
end

return M
