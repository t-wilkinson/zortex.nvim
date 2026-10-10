-- services/projects/relations.lua - What links to a project, and what it links to
--
-- Projects are the objects the rest of the system points at:
--   calendar entries  "14:00 [P/#1.4 - zortex]"     -> Project:schedule()
--   key results       "- KR2: [ ] ... [P/#...]"       -> Project:key_results()
--   areas             "## ... @a(4.1)"                -> Project:areas()
-- Every link is resolved with the shared link resolver and compared by project
-- key, never by link text.
local M = {}

local Document = require("zortex.core.document")
local parser = require("zortex.utils.parser")
local fs = require("zortex.utils.filesystem")
local link_resolver = require("zortex.utils.link_resolver")

local function projects()
	return require("zortex.services.projects")
end

-- =============================================================================
-- Schedule (calendar)
-- =============================================================================

local schedule_cache = { doc = nil, signature = nil, index = nil }

-- { [project_key] = { { date, time, entry, lnum, link, project }, ... } }
function M.schedule_index()
	local doc = Document.get(fs.get_calendar_file())
	if not doc then
		return {}
	end
	local signature = projects().signature()
	if schedule_cache.doc == doc and schedule_cache.signature == signature then
		return schedule_cache.index
	end

	local calendar = require("zortex.stores.calendar")
	local index = {}
	for date, entries in pairs(calendar.parse_lines(doc.lines)) do
		for _, entry in ipairs(entries) do
			for _, link in ipairs(parser.extract_all_links(entry.raw_text)) do
				if link.type == "link" or link.type == "live_link" then
					local project = projects().resolve(link.definition)
					if project then
						index[project.key] = index[project.key] or {}
						table.insert(index[project.key], {
							date = date,
							time = entry:get_time_string(), -- "HH:MM" or nil
							entry = entry,
							lnum = entry.lnum,
							file = doc.filepath,
							link = link.full_match_text,
							project = project,
						})
					end
				end
			end
		end
	end

	for _, items in pairs(index) do
		table.sort(items, function(a, b)
			if a.date ~= b.date then
				return a.date < b.date
			end
			return a.lnum < b.lnum
		end)
	end

	schedule_cache.doc, schedule_cache.signature, schedule_cache.index = doc, signature, index
	return index
end

-- Calendar entries linking to a project, sorted by date then line.
---@param opts { descendants?: boolean, from?: string, to?: string }?  dates as "YYYY-MM-DD"
function M.schedule(project, opts)
	opts = opts or {}
	local index = M.schedule_index()
	local out = {}
	local function collect(p)
		for _, item in ipairs(index[p.key] or {}) do
			if (not opts.from or item.date >= opts.from) and (not opts.to or item.date <= opts.to) then
				out[#out + 1] = item
			end
		end
	end
	if opts.descendants then
		project:walk(collect)
		table.sort(out, function(a, b)
			if a.date ~= b.date then
				return a.date < b.date
			end
			return a.lnum < b.lnum
		end)
	else
		collect(project)
	end
	return out
end

-- =============================================================================
-- Key results (OKR)
-- =============================================================================

---@param opts { inherit?: boolean }?
function M.key_results(project, opts)
	local okr = require("zortex.services.okr")
	local krs = (okr.get_key_results(project))
	if opts and opts.inherit then
		for _, ancestor in ipairs(project:ancestors()) do
			vim.list_extend(krs, (okr.get_key_results(ancestor)))
		end
	end
	return krs
end

-- =============================================================================
-- Areas (PARA)
-- =============================================================================

-- Resolve one area link -> { link, definition, resolved, name, path, key, file, lnum }
local function resolve_area(area)
	local node, result = link_resolver.resolve_node(area.definition)
	if not node then
		return { link = area.link, definition = area.definition, resolved = false }
	end
	local path = node:path_texts()
	return {
		link = area.link,
		definition = area.definition,
		resolved = true,
		name = node.text,
		path = path,
		key = table.concat(path, "/"),
		file = result.file,
		lnum = result.lnum,
	}
end

---@param opts { inherit?: boolean }?
function M.areas(project, opts)
	local current = project
	while current do
		local declared = current.attributes.area
		if declared and #declared > 0 then
			return vim.tbl_map(resolve_area, declared)
		end
		if not (opts and opts.inherit) then
			break
		end
		current = current.parent
	end
	return {}
end

return M
