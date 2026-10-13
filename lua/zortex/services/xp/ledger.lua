-- services/xp/ledger.lua - Every XP award, derived from the notes
--
-- XP is not stored: it is read off the notes. A completed task carries its
-- completion date (@done(...), added when you toggle it), objectives carry
-- @done(...) too, and projects are trees of tasks, so the whole history of
-- awards can be rebuilt at any time:
--
--   project tasks   a project's pool (@xp, @size or the sum of its tasks) is
--                   paid out over its tasks on the initiation/execution/
--                   completion curve, one award per completed task, dated by
--                   the task's @done; a project marked @done pays the rest
--   other tasks     a completed task anywhere else (calendar, any note):
--                   base × size × priority × importance
--   objectives      an objective marked @done: base × time span, to its areas
--
-- Archived projects (z/archive.*) keep counting under the same project key,
-- so archiving never takes XP away. Unchecking a task, editing a note on your
-- phone or renaming a heading all simply change the result; nothing drifts.
--
-- Seasons are date windows over the same awards (stores/xp keeps their
-- names and dates). Areas get a configured share of each award, split over
-- the areas it is linked to (most specific first).
--
--   local L = require("zortex.services.xp.ledger")
--   L.get()          -- { entries, area_xp, total, built } (cached until a note changes)
--   L.season_xp(season)
--   L.area_xp(key)
local M = {}

local constants = require("zortex.constants")
local calculator = require("zortex.services.xp.calculator")
local Item = require("zortex.core.item")

local cache = { signature = nil, ledger = nil, checked = 0 }
local CHECK_TTL_MS = 750 -- reuse the ledger without re-checking files for this long

-- =============================================================================
-- Helpers
-- =============================================================================

local function normalize(path)
	return vim.fn.fnamemodify(path, ":p")
end

--- "YYYY-MM-DD" from a date attribute (table or string), or nil.
function M.date_string(v)
	if type(v) == "table" and v.year then
		return string.format("%04d-%02d-%02d", v.year, v.month or 1, v.day or 1)
	elseif type(v) == "string" then
		local y, m, d = v:match("(%d%d%d%d)%-(%d%d?)%-(%d%d?)")
		if y then
			return string.format("%04d-%02d-%02d", tonumber(y), tonumber(m), tonumber(d))
		end
	end
	return nil
end
local date_string = M.date_string

-- Ordered, unique area keys
local function area_list()
	local list, seen = {}, {}
	return list, function(area)
		if area and area.key and not seen[area.key] then
			seen[area.key] = true
			list[#list + 1] = area.key
		end
	end
end

local function task_areas(task, add)
	for _, area in ipairs(require("zortex.services.areas").from_attributes(task.attributes or {})) do
		add(area)
	end
end

-- =============================================================================
-- Inputs
-- =============================================================================

-- Project-like documents: project sources and their archives
local function is_project_doc(doc)
	local P = constants.PROJECT_TAG
	return doc:has_tag(P) or doc:has_name(P) or doc.filepath == normalize(require("zortex.utils.filesystem").get_projects_file())
end

local function excluded_files()
	local fs = require("zortex.utils.filesystem")
	local out = {}
	for _, p in ipairs({ fs.get_okr_file(), fs.get_digest_file() }) do
		if p then
			out[normalize(p)] = true
		end
	end
	return out
end

--- Every note the ledger reads (archived ones included).
local function note_files()
	return require("zortex.core.notes").files({ include_archived = true })
end

-- Modified, loaded buffers by path (their contents win over the file)
local function modified_buffers()
	local out = {}
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
			local name = vim.api.nvim_buf_get_name(b)
			if name ~= "" then
				out[normalize(name)] = b
			end
		end
	end
	return out
end

-- Signature of everything the ledger depends on
local function signature(files)
	local parts = {}
	local mod = modified_buffers()
	for _, path in ipairs(files) do
		local bufnr = mod[path]
		if bufnr then
			parts[#parts + 1] = path .. "#" .. vim.api.nvim_buf_get_changedtick(bufnr)
		else
			local st = vim.uv.fs_stat(path)
			parts[#parts + 1] = path .. ":" .. (st and (st.mtime.sec .. "." .. st.mtime.nsec .. "." .. st.size) or "-")
		end
	end
	return table.concat(parts, "|")
end

-- Completed tasks of a non-project note, without parsing the whole note:
-- only lines with a checked box are looked at.
local light_cache = {} -- path -> { key, tasks }

local function checked_tasks(path)
	local bufnr = vim.fn.bufnr(path)
	local key, lines
	if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
		key = "b" .. vim.api.nvim_buf_get_changedtick(bufnr)
		if light_cache[path] and light_cache[path].key == key then
			return light_cache[path].tasks
		end
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	else
		local st = vim.uv.fs_stat(path)
		if not st then
			return {}
		end
		key = st.mtime.sec .. "." .. st.mtime.nsec .. "." .. st.size
		if light_cache[path] and light_cache[path].key == key then
			return light_cache[path].tasks
		end
		lines = require("zortex.utils.filesystem").read_lines(path) or {}
	end
	local tasks = {}
	local in_fence = false
	for lnum, line in ipairs(lines) do
		if line:match("^%s*```") then
			in_fence = not in_fence
		elseif not in_fence and line:find("[xX]%]") then
			local task = Item.task(line, { lnum = lnum, file = path })
			if task and task.completed then
				tasks[#tasks + 1] = task
			end
		end
	end
	light_cache[path] = { key = key, tasks = tasks }
	return tasks
end

-- =============================================================================
-- Building
-- =============================================================================

local function entry(source, fields)
	fields.source = source
	return fields
end

-- Projects (live and archived) grouped by key:
-- key -> { project = the live Project (else the archived one), tasks = {...} }
local function project_groups(project_paths)
	local projects = require("zortex.services.projects")
	local Document = require("zortex.core.document")
	local notes = require("zortex.core.notes")
	local groups, order = {}, {}
	for _, path in ipairs(project_paths) do
		local doc = Document.get(path)
		local archived = notes.is_archived(path)
		for _, root in ipairs(doc and projects.for_document(doc) or {}) do
			root:walk(function(p)
				local g = groups[p.key]
				if not g then
					g = { project = p, tasks = {}, live = not archived }
					groups[p.key] = g
					order[#order + 1] = p.key
				elseif not archived and not g.live then
					g.project, g.live = p, true
				end
				vim.list_extend(g.tasks, p:tasks())
			end)
		end
	end
	return groups, order
end

-- project key -> key results linking to it (built once per ledger build)
local function key_result_index()
	local index = {}
	local ok, krs = pcall(function()
		return require("zortex.services.okr").key_results()
	end)
	if not ok then
		return index
	end
	for _, kr in ipairs(krs) do
		for key in pairs(kr:linked_projects()) do
			index[key] = index[key] or {}
			table.insert(index[key], kr)
		end
	end
	return index
end

-- Areas a project's awards go to (its own or inherited @a, then the areas
-- of objectives whose key results link to it or an ancestor), and whether
-- a key result links to it.
local function project_areas(project, kr_index)
	local list, add = area_list()
	if project.areas then
		for _, area in ipairs(project:areas({ inherit = true })) do
			add(area)
		end
	end
	local via_kr = false
	local current = project
	while current do
		for _, kr in ipairs(kr_index[current.key] or {}) do
			via_kr = true
			if kr.objective then
				for _, area in ipairs(kr.objective:areas()) do
					add(area)
				end
			end
		end
		current = current.parent
	end
	return list, via_kr
end

-- A task's own @a(...) areas first, then its project's
local function with_task_areas(task, project_list)
	local list, add = area_list()
	task_areas(task, add)
	for _, key in ipairs(project_list) do
		add({ key = key })
	end
	return list
end

local function project_entries(out, group, kr_index)
	local project, tasks = group.project, group.tasks
	if #tasks == 0 then
		return
	end
	local pool = calculator.calculate_project_total_xp(project, tasks)
	local done = {}
	for _, t in ipairs(tasks) do
		if t.completed then
			done[#done + 1] = t
		end
	end
	-- undated completions first (they are the oldest), then by date, then by line
	table.sort(done, function(a, b)
		local da, db = date_string(a.attributes.done) or "", date_string(b.attributes.done) or ""
		if da ~= db then
			return da < db
		end
		if a.file ~= b.file then
			return (a.file or "") < (b.file or "")
		end
		return (a.lnum or 0) < (b.lnum or 0)
	end)
	local steps = calculator.curve_steps(pool, #tasks, #done)
	local season_share = calculator.season_share("project")
	local paid = 0
	local p_areas, via_kr = project_areas(project, kr_index)
	for k, t in ipairs(done) do
		local xp = steps[k]
		paid = paid + xp
		local areas = with_task_areas(t, p_areas)
		out[#out + 1] = entry("project_task", {
			title = t.text,
			project = project.key,
			file = t.file,
			lnum = t.lnum,
			date = date_string(t.attributes.done),
			xp = xp,
			season_xp = xp * season_share,
			areas = calculator.area_shares(xp, areas, calculator.area_share("project", via_kr)),
		})
	end
	-- A project marked done pays what the curve hasn't yet
	local done_date = project.attributes and project.attributes.done
	if done_date and pool - paid > 0.5 then
		local xp = pool - paid
		local areas = p_areas
		out[#out + 1] = entry("project_done", {
			title = project.name .. " (completed)",
			project = project.key,
			file = project.file,
			lnum = project.lnum,
			date = date_string(done_date),
			xp = xp,
			season_xp = xp * season_share,
			areas = calculator.area_shares(xp, areas, calculator.area_share("project", via_kr)),
		})
	end
end

local function task_entries(out, path)
	local share, season_share = calculator.area_share("task", false), calculator.season_share("task")
	for _, t in ipairs(checked_tasks(path)) do
		local xp = calculator.calculate_task_xp(t)
		local areas, add = area_list()
		task_areas(t, add)
		out[#out + 1] = entry("task", {
			title = t.text,
			file = path,
			lnum = t.lnum,
			date = date_string(t.attributes.done),
			xp = xp,
			season_xp = xp * season_share,
			areas = calculator.area_shares(xp, areas, share),
		})
	end
end

local function objective_entries(out)
	local ok, objectives = pcall(function()
		return require("zortex.services.okr").objectives()
	end)
	if not ok then
		return
	end
	local season_share = calculator.season_share("objective")
	for _, o in ipairs(objectives) do
		if o.completed then
			local xp = calculator.calculate_objective_xp(o)
			local areas, add = area_list()
			for _, area in ipairs(o:areas()) do
				add(area)
			end
			out[#out + 1] = entry("objective", {
				title = o.title or o.name,
				file = o.file,
				lnum = o.lnum,
				date = date_string(o.attributes.done),
				xp = xp,
				season_xp = xp * season_share,
				areas = calculator.area_shares(xp, areas, calculator.area_share("objective", false)),
			})
		end
	end
end

--- Build the ledger now (uncached).
function M.build()
	local files = note_files()
	local excluded = excluded_files()
	local project_paths, task_paths = {}, {}
	for _, path in ipairs(files) do
		local p = normalize(path)
		if not excluded[p] then
			local header = require("zortex.core.notes").header(p)
			local doc_like = {
				filepath = p,
				has_tag = function(_, t)
					return header and require("zortex.core.syntax").list_has(header.tags, t)
				end,
				has_name = function(_, n)
					return header and require("zortex.core.syntax").list_has(header.names, n)
				end,
			}
			if is_project_doc(doc_like) then
				project_paths[#project_paths + 1] = p
			else
				task_paths[#task_paths + 1] = p
			end
		end
	end
	-- the projects file may be missing from the notes list (no header yet)
	local pf = normalize(require("zortex.utils.filesystem").get_projects_file())
	if vim.uv.fs_stat(pf) and not vim.tbl_contains(project_paths, pf) then
		table.insert(project_paths, 1, pf)
	end

	local entries = {}
	local groups, order = project_groups(project_paths)
	local kr_index = key_result_index()
	for _, key in ipairs(order) do
		project_entries(entries, groups[key], kr_index)
	end
	for _, path in ipairs(task_paths) do
		task_entries(entries, path)
	end
	objective_entries(entries)

	local area_xp, total = {}, 0
	for _, e in ipairs(entries) do
		total = total + e.xp
		for key, amount in pairs(e.areas) do
			area_xp[key] = (area_xp[key] or 0) + amount
		end
	end
	-- newest first; undated last
	table.sort(entries, function(a, b)
		local da, db = a.date or "", b.date or ""
		if da ~= db then
			return da > db
		end
		return (a.lnum or 0) < (b.lnum or 0)
	end)
	return { entries = entries, area_xp = area_xp, total = total, built = os.time(), projects = groups }
end

--- The ledger, rebuilt only when a note (or buffer) changed.
--- opts.cached: skip the check if one ran in the last 750 ms (for loops
--- that ask once per area); opts.force: rebuild regardless.
function M.get(opts)
	local now = vim.uv.hrtime() / 1e6
	if opts and opts.cached and cache.ledger and now - cache.checked < CHECK_TTL_MS then
		return cache.ledger
	end
	cache.checked = now
	local files = note_files()
	local sig = signature(files) .. "|" .. vim.inspect(calculator.config().sources or {})
	if (opts and opts.force) or cache.signature ~= sig or not cache.ledger then
		cache.ledger = M.build()
		cache.signature = sig
	end
	return cache.ledger
end

function M.invalidate()
	cache.signature, cache.ledger, cache.checked = nil, nil, 0
	light_cache = {}
end

-- =============================================================================
-- Queries
-- =============================================================================

--- XP earned directly by an area (all time).
function M.area_xp(key)
	return M.get().area_xp[key] or 0
end

--- Season XP: awards dated inside the season window.
---@param season { start_date: string, end_date?: string }?
function M.season_xp(season, ledger)
	if not season then
		return 0
	end
	ledger = ledger or M.get()
	local total = 0
	for _, e in ipairs(ledger.entries) do
		if e.date and e.date >= season.start_date and (not season.end_date or e.date <= season.end_date) then
			total = total + e.season_xp
		end
	end
	return total
end

--- Awards in a date window, newest first.
function M.between(from, to, ledger)
	ledger = ledger or M.get()
	local out = {}
	for _, e in ipairs(ledger.entries) do
		if e.date and (not from or e.date >= from) and (not to or e.date <= to) then
			out[#out + 1] = e
		end
	end
	return out
end

--- Awards of one project (by key), oldest first, and the total.
function M.for_project(key, ledger)
	ledger = ledger or M.get()
	local out, total = {}, 0
	for i = #ledger.entries, 1, -1 do
		local e = ledger.entries[i]
		if e.project == key then
			out[#out + 1] = e
			total = total + e.xp
		end
	end
	return out, total
end

return M
