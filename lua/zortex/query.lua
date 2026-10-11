-- query.lua - Plain-data API over notes, structure and the domain
--
-- Every function returns plain tables (strings, numbers, booleans, lists and
-- maps; no functions, metatables or cycles), so results can go straight to
-- vim.json.encode, an RPC client or a file. Paths are absolute; `rel` is the
-- path relative to notes_dir. Dates are "YYYY-MM-DD" strings.
--
--   local q = require("zortex.query")
--   q.tree("z")                     folders and notes under notes_dir/z
--   q.note(path)                    header, outline and full syntax of a note
--   q.search("proj zortex")         structural search results
--   q.resolve("[P/#1.4 - zortex]")  where a link lands
--   q.backlinks(path, lnum)         links pointing into a section
--   q.agenda(from, to)              calendar, due tasks and due projects
--   q.review({ days = 7 })          weekly review findings
--   q.plan({ today })               ranked candidates for planning a day
--   q.projects() / q.areas() / q.objectives()
--   q.export(dir)                   all of the above as JSON files
local M = {}

M.VERSION = 1

local function Config()
	return require("zortex.config")
end

local function rel(path)
	local dir = Config().notes_dir or ""
	if path and dir ~= "" and path:sub(1, #dir) == dir then
		return (path:sub(#dir + 1):gsub("^/", ""))
	end
	return path
end
M.rel = rel

local function abs(path)
	if path:sub(1, 1) == "/" then
		return path
	end
	return Config().notes_dir .. path
end

-- Attribute values as JSON-friendly data: dates -> "YYYY-MM-DD" (with
-- " HH:MM" when timed), everything else as is.
local function plain_value(v)
	if type(v) ~= "table" then
		return v
	end
	if v.year and v.month and v.day then
		local s = string.format("%04d-%02d-%02d", v.year, v.month, v.day)
		if v.hour and v.min then
			s = s .. string.format(" %02d:%02d", v.hour, v.min)
		end
		return s
	end
	local out = {}
	for k, x in pairs(v) do
		if type(x) ~= "function" then
			out[k] = plain_value(x)
		end
	end
	return out
end
M.plain_value = plain_value

local function item_data(item)
	return {
		lnum = item.lnum,
		text = item.text,
		marker = item.marker,
		key = item.key,
		mark = item.mark,
		completed = item.completed or false,
		attributes = plain_value(item.attributes or {}),
	}
end

-- =============================================================================
-- Notes and folders
-- =============================================================================

local function note_summary(path, header)
	local stat = vim.loop.fs_stat(path)
	return {
		path = path,
		rel = rel(path),
		title = header.names[1] or vim.fn.fnamemodify(path, ":t:r"),
		names = header.names,
		tags = header.tags,
		archived = require("zortex.core.notes").is_archived(path, header),
		mtime = stat and stat.mtime.sec or nil,
	}
end

--- Folders and notes under notes_dir/`dir` (default: everything).
--- { name, rel, dirs = { <same shape> }, notes = { { path, rel, title, names, tags, archived, mtime } } }
function M.tree(dir)
	local idx = require("zortex.core.notes").index({ include_archived = true })
	local prefix = dir and dir ~= "" and (dir:gsub("/$", "") .. "/") or ""
	local root = { name = prefix ~= "" and prefix:gsub("/$", "") or "", rel = prefix:gsub("/$", ""), dirs = {}, notes = {} }
	local by_rel = { [root.rel] = root }

	local function folder(path_rel)
		if by_rel[path_rel] then
			return by_rel[path_rel]
		end
		local parent_rel, name = path_rel:match("^(.*)/([^/]+)$")
		if not parent_rel then
			parent_rel, name = "", path_rel
		end
		local f = { name = name, rel = path_rel, dirs = {}, notes = {} }
		by_rel[path_rel] = f
		table.insert(folder(parent_rel).dirs, f)
		return f
	end

	for _, path in ipairs(idx.files) do
		local r = rel(path)
		if r:sub(1, #prefix) == prefix then
			local parent = r:match("^(.*)/[^/]+$") or ""
			table.insert(folder(parent).notes, note_summary(path, idx.headers[path]))
		end
	end

	local function sort(f)
		table.sort(f.dirs, function(a, b)
			return a.name < b.name
		end)
		table.sort(f.notes, function(a, b)
			return a.rel < b.rel
		end)
		for _, d in ipairs(f.dirs) do
			sort(d)
		end
	end
	sort(root)
	return root
end

local function outline(node)
	local out = {
		type = node.type,
		text = node.text,
		level = node.level,
		start_line = node.start_line,
		end_line = node.end_line,
		children = {},
	}
	for _, child in ipairs(node.children) do
		out.children[#out.children + 1] = outline(child)
	end
	return out
end

--- A note: header, outline (section tree) and the full syntax with inline
--- spans (core/syntax format), plus its lines.
function M.note(path)
	path = abs(path)
	local doc = require("zortex.core.document").get(path)
	if not doc then
		return nil
	end
	local ast = require("zortex.core.syntax").parse(doc.lines, { inline = true })
	local summary = note_summary(path, doc.header)
	summary.lines = doc.lines
	summary.outline = outline(doc.tree).children
	summary.syntax = ast
	return summary
end

-- =============================================================================
-- Search and links
-- =============================================================================

--- Structural search (services/search): sections, then matching lines.
---@param opts { mode?: "section"|"article", limit?: integer }?
function M.search(prompt, opts)
	opts = opts or {}
	local out = {}
	for _, r in ipairs(require("zortex.services.search").search(prompt, opts)) do
		local entry
		if r.result_type == "section" then
			entry = {
				type = "section",
				path = r.filepath,
				rel = rel(r.filepath),
				lnum = r.node.start_line,
				section = r.node.type,
				breadcrumb = r.breadcrumb,
				text = r.node.text,
				archived = r.archived or false,
				child = r.child or nil,
			}
		else
			entry = { type = "line", path = r.filepath, rel = rel(r.filepath), lnum = r.lnum, text = r.line }
		end
		entry.score = r.score
		out[#out + 1] = entry
		if opts.limit and #out >= opts.limit then
			break
		end
	end
	return out
end

--- Where a link lands: { { path, rel, lnum, end_line, text } }, canonical first.
---@param opts { from?: string }?  source note for local links ("[/#Heading]")
function M.resolve(link, opts)
	opts = opts or {}
	local resolve_opts = opts.from and { doc = require("zortex.core.document").get(abs(opts.from)) } or nil
	local results = require("zortex.utils.link_resolver").resolve(link, resolve_opts)
	local out = {}
	for _, r in ipairs(results or {}) do
		out[#out + 1] = {
			path = r.file,
			rel = rel(r.file),
			lnum = r.lnum,
			end_line = r.end_line,
			text = r.doc and r.doc.lines[r.lnum] or r.text,
		}
	end
	return out
end

local function ref_data(ref)
	return {
		path = ref.file,
		rel = rel(ref.file),
		lnum = ref.lnum,
		col = ref.col,
		text = ref.text,
		target = ref.target and { path = ref.target.file, rel = rel(ref.target.file), lnum = ref.target.lnum } or nil,
	}
end

--- Links pointing into the section at `lnum` of `path` (or anywhere in the note).
function M.backlinks(path, lnum)
	path = abs(path)
	local idx = require("zortex.core.link_index")
	local refs
	if lnum then
		local doc = require("zortex.core.document").get(path)
		local node = doc and doc:node_at(lnum)
		local s, e = lnum, lnum
		if node and not node:is_root() then
			s, e = node.start_line, node.end_line
		end
		refs = idx.references(path, s, e)
	else
		refs = idx.references(path, 1, math.huge)
	end
	return vim.tbl_map(ref_data, refs)
end

--- Links that resolve nowhere.
function M.broken_links()
	return vim.tbl_map(ref_data, require("zortex.core.link_index").unresolved())
end

-- =============================================================================
-- Domain
-- =============================================================================

local function project_data(p)
	local areas = {}
	for _, a in ipairs(p:areas()) do
		areas[#areas + 1] = a.key
	end
	return {
		key = p.key,
		name = p.name,
		link = p.link,
		path = p.file,
		rel = rel(p.file),
		lnum = p.lnum,
		parent = p.parent and p.parent.key or nil,
		children = vim.tbl_map(function(c)
			return c.key
		end, p.children),
		attributes = plain_value(p.attributes),
		done = p:is_done(),
		stats = plain_value(p:stats()),
		rollup = plain_value(p:rollup()),
		points = p:points(),
		areas = areas,
		tasks = vim.tbl_map(item_data, p:tasks()),
	}
end

--- Every project (tree order) with stats, rollup, areas and own tasks.
function M.projects()
	return vim.tbl_map(project_data, require("zortex.services.projects").all())
end

--- Every area with its projects and objectives (keys).
function M.areas()
	local out = {}
	for _, a in ipairs(require("zortex.services.areas").all()) do
		out[#out + 1] = {
			key = a.key,
			name = a.name,
			link = a.link,
			path = a.file,
			rel = rel(a.file),
			lnum = a.lnum,
			parent = a.parent and a.parent.key or nil,
			xp = a:total_xp(),
			projects = vim.tbl_map(function(p)
				return p.key
			end, a:projects()),
			objectives = vim.tbl_map(function(o)
				return o.key
			end, a:objectives()),
		}
	end
	return out
end

--- Objectives with key results and progress.
function M.objectives()
	local out = {}
	for _, o in ipairs(require("zortex.services.okr").objectives()) do
		local krs = {}
		for _, kr in ipairs(o.key_results) do
			krs[#krs + 1] = {
				id = kr.id,
				text = kr.text,
				link = kr.link,
				lnum = kr.lnum,
				completed = kr.completed,
				progress = kr:progress(),
				projects = vim.tbl_map(function(p)
					return p.key
				end, kr:project_list()),
			}
		end
		out[#out + 1] = {
			key = o.key,
			title = o.title,
			link = o.link,
			span = o.span,
			year = o.year,
			period = o.period,
			section = o.section,
			path = o.file,
			rel = rel(o.file),
			lnum = o.lnum,
			completed = o.completed or false,
			progress = o:progress(),
			attributes = plain_value(o.attributes),
			key_results = krs,
		}
	end
	return out
end

local function agenda_item(i)
	return {
		kind = i.kind,
		date = i.date,
		time = i.time,
		text = i.text,
		done = i.done or false,
		priority = i.priority,
		project = i.project and i.project.key or nil,
		project_link = i.project and i.project.link or nil,
		path = i.file or (i.task and i.task.file),
		rel = rel(i.file or (i.task and i.task.file)),
		lnum = i.lnum or (i.task and i.task.lnum),
	}
end

--- Days from `from` to `to` (inclusive): { { date, items } } (services/agenda).
function M.agenda(from, to, opts)
	local out = {}
	for _, day in ipairs(require("zortex.services.agenda").range(from, to, opts)) do
		out[#out + 1] = { date = day.date, items = vim.tbl_map(agenda_item, day.items) }
	end
	return out
end

--- Weekly review findings (services/agenda.review) as plain data.
function M.review(opts)
	local r = require("zortex.services.agenda").review(opts)
	local keys = function(list)
		return vim.tbl_map(function(e)
			return { key = e.key, name = e.name, link = e.link, path = e.file, rel = rel(e.file), lnum = e.lnum }
		end, list)
	end
	return {
		today = r.today,
		from = r.from,
		to = r.to,
		overdue = vim.tbl_map(agenda_item, r.overdue),
		due_soon = vim.tbl_map(agenda_item, r.due_soon),
		completed = vim.tbl_map(agenda_item, r.completed),
		unscheduled = keys(r.unscheduled),
		stale = keys(r.stale),
		no_next_action = keys(r.no_next_action),
		krs_without_projects = vim.tbl_map(function(kr)
			return { id = kr.id, text = kr.text, link = kr.link, objective = kr.objective.key, path = kr.file, rel = rel(kr.file), lnum = kr.lnum }
		end, r.krs_without_projects),
		objectives_without_krs = keys(r.objectives_without_krs),
		areas_without_projects = keys(r.areas_without_projects),
		broken_links = vim.tbl_map(ref_data, r.broken_links),
	}
end

--- Candidates for planning a day (services/planner), ranked.
function M.plan(opts)
	local c = require("zortex.services.planner").candidates(opts)
	local function list(items)
		return vim.tbl_map(function(i)
			return { kind = i.kind, text = i.text, badges = i.badges, score = i.score, path = i.file, rel = rel(i.file), lnum = i.lnum }
		end, items)
	end
	return { tasks = list(c.tasks), projects = list(c.projects), key_results = list(c.key_results), areas = list(c.areas) }
end

-- =============================================================================
-- Export
-- =============================================================================

--- Write the whole model as JSON under `dir` (default notes_dir/.z/export):
---   index.json         { version, generated, tree, projects, areas, objectives, review }
---   notes/<rel>.json   M.note(path) for every note
---@return string dir, integer notes written
function M.export(dir)
	dir = dir or require("zortex.core.state").path("export"):gsub("%.json$", "")
	local function write(path, data)
		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		vim.fn.writefile({ vim.json.encode(data) }, path)
	end
	local count = 0
	for _, path in ipairs(require("zortex.core.notes").files({ include_archived = true })) do
		local note = M.note(path)
		if note then
			write(dir .. "/notes/" .. note.rel:gsub("%.[^.]+$", "") .. ".json", note)
			count = count + 1
		end
	end
	write(dir .. "/index.json", {
		version = M.VERSION,
		generated = os.date("%Y-%m-%dT%H:%M:%S"),
		tree = M.tree(),
		projects = M.projects(),
		areas = M.areas(),
		objectives = M.objectives(),
		review = M.review(),
	})
	return dir, count
end

return M
