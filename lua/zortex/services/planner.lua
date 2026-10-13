-- services/planner.lua - What to put on today's calendar
--
-- The data behind :ZortexPlan (ui/planner.lua). Everything here is plain
-- data, so the web app can show the same lists.
--
--   candidates({ today })  -> { tasks, projects, key_results, areas }
--       each candidate: { kind, text, badges, score, file, lnum }
--       `text` is what gets written into the calendar: the item's text and
--       an explicit link to it ("Improve website [P/#1 Programming/#1.4 - zortex/-Improve website]")
--   template(date)          -> template lines for a new calendar day
--   put(line, col, text)    -> the line with `text` put at the cursor
--
-- Ranking: signals add up, so a TODO with a high priority that is also due
-- beats any one of those alone (weights in M.weights). Alignment counts
-- most: work on a key result ranks above work that only has an area, which
-- ranks above work with neither, and a key result that is behind schedule
-- (its objective's time passing faster than its progress) pushes its
-- projects' tasks up further.
local M = {}

local function Config()
	return require("zortex.config")
end

local function cfg()
	local ui = Config().ui or {}
	return ui.planner or {}
end

local datetime = require("zortex.utils.datetime")

M.weights = {
	todo = 3, -- task in the TODO project (ui.planner.todo_link)
	priority = { ["1"] = 3, ["2"] = 2, ["3"] = 1 }, -- @p
	importance = { ["1"] = 2, ["2"] = 1 }, -- @i
	overdue = 4,
	due_today = 3,
	due_3d = 2,
	due_7d = 1,
	okr = 2, -- project linked from an open key result
	kr_behind = 4, -- more, up to this, the further behind its key result is
	kr_behind_full = 0.25, -- ... reached at 25% behind schedule
	area = 1, -- project (or task) with an area but no key result
	project_priority = { ["1"] = 1 }, -- the project's own @p
}

-- =============================================================================
-- Helpers
-- =============================================================================

local function today(opts)
	return datetime.parse_date((opts and opts.today) or os.date("%Y-%m-%d"))
end

local function days_until(date, from)
	if type(date) ~= "table" or not date.year then
		return nil
	end
	return datetime.days_between(from, date)
end

--- Explicit link to a list item: its project's (or section's) link plus
--- "-<key or text>".
function M.item_link(base_link, line)
	local comp = require("zortex.core.link").item_component(line)
	if not base_link or not comp then
		return base_link
	end
	return base_link:sub(1, -2) .. "/" .. comp .. "]"
end

-- Text without its links ("Ship it [P/#X]" -> "Ship it"): the candidate
-- gets one explicit link of its own.
local function plain(text)
	local syntax = require("zortex.core.syntax")
	local out, pos = {}, 1
	for _, span in ipairs(syntax.links(text)) do
		out[#out + 1] = text:sub(pos, span.s)
		pos = span.e + 1
	end
	out[#out + 1] = text:sub(pos)
	return vim.trim((table.concat(out):gsub("%s+", " ")))
end
M.plain = plain

local function todo_project()
	local link = cfg().todo_link
	if not link or link == "" then
		return nil
	end
	local ok, p = pcall(require("zortex.services.projects").resolve, "[" .. link:gsub("^%[", ""):gsub("%]$", "") .. "]")
	return ok and p or nil
end

local function in_subtree(project, root)
	local p = project
	while p do
		if p == root or p.key == root.key then
			return true
		end
		p = p.parent
	end
	return false
end

-- =============================================================================
-- Candidates
-- =============================================================================

-- Open key results linking a project or an ancestor: the one furthest
-- behind, and how far ({ kr, lag }), or nil.
local function kr_for(project, ctx)
	local best
	local p = project
	while p do
		for _, kr in ipairs(ctx.krs[p.key] or {}) do
			local lag = kr:lag(ctx.today_str)
			if not best or lag > best.lag then
				best = { kr = kr, lag = lag }
			end
		end
		p = p.parent
	end
	return best
end

-- Score for alignment: key result (more when behind), else area, else 0
local function alignment(project, task, ctx)
	local w = M.weights
	local link = ctx.kr_of[project]
	if link == nil then
		link = kr_for(project, ctx) or false
		ctx.kr_of[project] = link
	end
	if link then
		local behind = math.min(1, link.lag / w.kr_behind_full)
		local badge = link.kr.id
		if link.lag >= 0.05 then
			badge = string.format("%s %d%% behind", link.kr.id, math.floor(link.lag * 100 + 0.5))
		end
		return w.okr + w.kr_behind * behind, { "OKR", badge }
	end
	local has_area = (task and task.attributes and task.attributes.area) or #project:areas({ inherit = true }) > 0
	if has_area then
		return w.area, { "area" }
	end
	return 0, {}
end
M._alignment = alignment

local function score_task(task, project, ctx)
	local w, attrs = M.weights, task.attributes or {}
	local score, badges = 0, {}
	if ctx.todo and in_subtree(project, ctx.todo) then
		score = score + w.todo
		badges[#badges + 1] = "TODO"
	end
	if w.priority[attrs.p] then
		score = score + w.priority[attrs.p]
		badges[#badges + 1] = "P" .. attrs.p
	end
	if w.importance[attrs.i] then
		score = score + w.importance[attrs.i]
		badges[#badges + 1] = "I" .. attrs.i
	end
	local days = days_until(attrs.due, ctx.today)
	if days then
		if days < 0 then
			score = score + w.overdue
			badges[#badges + 1] = "overdue " .. datetime.format_datetime(attrs.due, "MM-DD")
		elseif days == 0 then
			score = score + w.due_today
			badges[#badges + 1] = "due today"
		elseif days <= 3 then
			score = score + w.due_3d
			badges[#badges + 1] = "due " .. datetime.format_datetime(attrs.due, "MM-DD")
		elseif days <= 7 then
			score = score + w.due_7d
			badges[#badges + 1] = "due " .. datetime.format_datetime(attrs.due, "MM-DD")
		end
	end
	local a, a_badges = alignment(project, task, ctx)
	score = score + a
	vim.list_extend(badges, a_badges)
	local pp = w.project_priority[project.attributes.p]
	if pp and score > 0 then
		score = score + pp
	end
	return score, badges
end

local function sort_by_score(list)
	table.sort(list, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return (a.text or "") < (b.text or "")
	end)
	return list
end

--- Everything worth considering for a day, ranked.
---@param opts { today?: string, max_tasks?: integer }?
function M.candidates(opts)
	opts = opts or {}
	local projects = require("zortex.services.projects")
	local score = require("zortex.services.projects.score")
	local ctx = { today = today(opts), todo = todo_project(), krs = {}, kr_of = {} }
	ctx.today_str = datetime.format_datetime(ctx.today, "YYYY-MM-DD")
	-- open key results by the project keys they link
	local okr_ok, open_krs = pcall(require("zortex.services.okr").key_results, { open = true })
	for _, kr in ipairs(okr_ok and open_krs or {}) do
		if not (kr.objective and kr.objective.completed) then
			for key in pairs(kr:linked_projects()) do
				ctx.krs[key] = ctx.krs[key] or {}
				table.insert(ctx.krs[key], kr)
			end
		end
	end

	-- Project tasks
	local tasks = {}
	for _, p in ipairs(projects.all()) do
		for _, task in ipairs(p:tasks()) do
			if not task.completed then
				local s, badges = score_task(task, p, ctx)
				if s > 0 then
					badges[#badges + 1] = p.name
					tasks[#tasks + 1] = {
						kind = "task",
						text = plain(task.text) .. " " .. M.item_link(p.link, task.raw_text),
						badges = badges,
						score = s,
						file = task.file,
						lnum = task.lnum,
					}
				end
			end
		end
	end

	-- Open calendar tasks from earlier days
	local ok, review = pcall(require("zortex.services.agenda").review, {
		today = datetime.format_datetime(ctx.today, "YYYY-MM-DD"),
		days = 14,
	})
	if ok then
		for _, item in ipairs(review.overdue) do
			if item.entry and item.entry.type == "task" then
				local doc = require("zortex.core.document").get(item.file)
				local node = doc and doc:node_at(item.lnum)
				local base = node and require("zortex.core.link").link_for_node(doc, node)
				tasks[#tasks + 1] = {
					kind = "task",
					text = plain(item.text) .. " " .. (M.item_link(base, item.entry.raw_text) or ""),
					badges = { "overdue " .. item.date:sub(6), "calendar" },
					score = M.weights.overdue,
					file = item.file,
					lnum = item.lnum,
				}
			end
		end
	end
	sort_by_score(tasks)
	local max = opts.max_tasks or cfg().max_tasks or 30
	if #tasks > max then
		tasks = vim.list_slice(tasks, 1, max)
	end

	-- Projects: OKR-linked or high priority/importance, with open work
	local plist = {}
	for _, p in ipairs(projects.all()) do
		local attrs = p.attributes
		local high = (tonumber(attrs.p) or 9) <= 2 or (tonumber(attrs.i) or 9) <= 2
		local r = p:rollup()
		local a, a_badges = alignment(p, nil, ctx)
		if not p:is_root() and not p:is_done() and r.open > 0 and (ctx.kr_of[p] or high) then
			local badges = score.indicators(p)
			for _, b in ipairs(a_badges) do
				if b ~= "OKR" and b ~= "area" then
					badges[#badges + 1] = b
				end
			end
			badges[#badges + 1] = string.format("%d/%d", r.done, r.total)
			for _, t in ipairs(p:tasks()) do
				if not t.completed then
					badges[#badges + 1] = "next: " .. t.text
					break
				end
			end
			plist[#plist + 1] = {
				kind = "project",
				text = p.link,
				badges = badges,
				score = score.project_score(p) + a,
				file = p.file,
				lnum = p.lnum,
			}
		end
	end
	sort_by_score(plist)

	-- Key results: open, of current objectives
	local krs = {}
	for _, o in ipairs(require("zortex.services.okr").objectives({ current = true })) do
		for _, kr in ipairs(o.key_results) do
			if not kr:is_done() then
				local progress, lag = kr:progress(), kr:lag(ctx.today_str)
				local badges = { kr.id, string.format("%d%%", progress * 100), o.title }
				if lag >= 0.05 then
					table.insert(badges, 3, string.format("%d%% behind", math.floor(lag * 100 + 0.5)))
				end
				krs[#krs + 1] = {
					kind = "key_result",
					text = plain(kr.text) .. " " .. (kr.link or o.link),
					badges = badges,
					-- furthest behind first, then least done
					score = lag * 10 + (1 - progress),
					file = kr.file,
					lnum = kr.lnum,
				}
			end
		end
	end
	sort_by_score(krs)

	-- Areas: two levels deep; areas without a current objective first (they
	-- have no key results pulling work toward them), then fewest projects
	local areas = {}
	local with_objective = {}
	for _, o in ipairs(require("zortex.services.okr").objectives({ current = true })) do
		for _, area in ipairs(o:areas()) do
			local x = area
			while x do
				with_objective[x.key] = true
				x = x.parent
			end
		end
	end
	for _, a in ipairs(require("zortex.services.areas").all({ include_roots = false })) do
		if a.depth <= 2 then
			local active = 0
			for _, p in ipairs(a:projects({ descendants = true })) do
				if not p:is_done() then
					active = active + 1
				end
			end
			local badges = { active == 0 and "no active projects" or (active .. " active") }
			if not with_objective[a.key] then
				table.insert(badges, 1, "no objective")
			end
			areas[#areas + 1] = {
				kind = "area",
				text = a.link,
				badges = badges,
				score = (with_objective[a.key] and -10 or 0) - active,
				file = a.file,
				lnum = a.lnum,
			}
		end
	end
	sort_by_score(areas)

	return { tasks = tasks, projects = plist, key_results = krs, areas = areas }
end

-- =============================================================================
-- Templates and putting text
-- =============================================================================

local WEEKDAYS = { "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" }

--- Template lines for a new day: ui.planner.templates[<weekday name>], else
--- .saturday / .sunday, else .weekday.
function M.template(date)
	local d = type(date) == "string" and datetime.parse_date(date) or date
	local wday = os.date("*t", os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })).wday
	local name = WEEKDAYS[wday]
	local templates = cfg().templates or {}
	local lines = templates[name]
	if not lines and name ~= "saturday" and name ~= "sunday" then
		lines = templates.weekday
	end
	return vim.deepcopy(lines or {})
end

--- Put `text` into `line` at the cursor (0-based byte `col`), the way `p`
--- would, with single spaces around it. Text never lands inside a list or
--- time marker ("09:00" + text -> "09:00 text"); on a blank line the text
--- becomes an entry ("- text"). Returns the new line and the 0-based column
--- of the end of the inserted text.
function M.put(line, col, text)
	text = vim.trim(text)
	if not line:find("%S") then
		local indent = line:match("^%s*")
		local new = indent .. "- " .. text
		return new, #new - 1
	end
	local at = math.min(col + 1, #line) -- after the cursor character
	local it = require("zortex.core.syntax").item(line)
	local slot = line:match("^%s*%d%d?:%d%d%s*%-%s*%d%d?:%d%d") or line:match("^%s*%d%d?:%d%d")
	local min = math.max((it and it.content_col) or 0, slot and #slot or 0)
	if at < min then
		at = min
	end
	local left, right = line:sub(1, at), line:sub(at + 1)
	if left ~= "" and not left:match("%s$") then
		left = left .. " "
	end
	if right ~= "" and not right:match("^%s") then
		text = text .. " "
	end
	local new = left .. text .. right
	return new, #left + #vim.trim(text) - 1
end

return M
