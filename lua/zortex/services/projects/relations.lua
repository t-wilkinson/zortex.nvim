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
local fs = require("zortex.utils.filesystem")

local function projects()
	return require("zortex.services.projects")
end

-- =============================================================================
-- Schedule (calendar)
-- =============================================================================

local schedule_cache = { doc = nil, signature = nil, index = nil }

-- { [project_key] = { { date, time, entry, lnum, file, link, project }, ... } }
-- Built from the link index: every link in calendar.zortex whose target lies
-- in a project.
function M.schedule_index()
	local path = fs.get_calendar_file()
	local doc = Document.get(path)
	if not doc then
		return {}
	end
	local signature = projects().signature()
	if schedule_cache.doc == doc and schedule_cache.signature == signature then
		return schedule_cache.index
	end

	-- Calendar entries by line
	local entry_at = {}
	for date, entries in pairs(require("zortex.stores.calendar").parse_lines(doc.lines)) do
		for _, entry in ipairs(entries) do
			entry_at[entry.lnum] = { date = date, entry = entry }
		end
	end

	local index = {}
	for _, ref in ipairs(require("zortex.core.link_index").links_from(path)) do
		local at = entry_at[ref.lnum]
		local project = at and ref.target and projects().at(ref.target.file, ref.target.lnum)
		if project then
			index[project.key] = index[project.key] or {}
			table.insert(index[project.key], {
				date = at.date,
				time = at.entry:get_time_string(), -- "HH:MM" or nil
				entry = at.entry,
				lnum = ref.lnum,
				file = doc.filepath,
				link = ref.text,
				project = project,
			})
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

-- Areas (services/areas) declared by the project, or with opts.inherit by
-- its nearest ancestor that declares any.
---@param opts { inherit?: boolean }?
function M.areas(project, opts)
	local areas = require("zortex.services.areas")
	local current = project
	while current do
		local declared = current.attributes.area
		if declared and #declared > 0 then
			return areas.from_attributes(current.attributes)
		end
		if not (opts and opts.inherit) then
			break
		end
		current = current.parent
	end
	return {}
end

return M
