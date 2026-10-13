-- services/projects/score.lua - Task/project scoring and project comparators
--
-- Pure functions shared by the projects picker, digest and calendar views.
local M = {}

local datetime = require("zortex.utils.datetime")

local PRIORITY_SCORE = { ["1"] = 100, ["2"] = 50, ["3"] = 25 }

-- OKR alignment: a project linked from open key results (directly or through
-- an ancestor) scores `okr` more, plus `okr_each` per extra key result.
M.weights = { okr = 80, okr_each = 20, okr_max = 140 }

-- { [project_key] = number of open KRs linking it }, rebuilt at most once a second
local okr_cache = { time = nil, counts = nil }
function M.okr_counts()
	local now = vim.uv.now()
	if okr_cache.counts and now - okr_cache.time < 1000 then
		return okr_cache.counts
	end
	local counts = {}
	local ok, krs = pcall(function()
		return require("zortex.services.okr").key_results({ open = true })
	end)
	for _, kr in ipairs(ok and krs or {}) do
		for key in pairs(kr.projects) do
			counts[key] = (counts[key] or 0) + 1
		end
	end
	okr_cache.time, okr_cache.counts = now, counts
	return counts
end

--- Open key results linking this project or one of its ancestors.
function M.okr_count(project)
	local counts = M.okr_counts()
	local n = counts[project.key] or 0
	for _, ancestor in ipairs(project:ancestors()) do
		n = n + (counts[ancestor.key] or 0)
	end
	return n
end

--- Score bonus for OKR alignment (see M.weights).
function M.okr_bonus(project)
	local n = M.okr_count(project)
	if n == 0 then
		return 0
	end
	return math.min(M.weights.okr + (n - 1) * M.weights.okr_each, M.weights.okr_max)
end

-- Days from today until a date table ({year, month, day}); nil if no date.
local function days_until(date)
	if type(date) ~= "table" or not date.year then
		return nil
	end
	return datetime.days_between(datetime.get_current_date(), date)
end
M.days_until = days_until

-- Urgency score of one task: priority + importance + due date; done tasks sink.
function M.task_score(task)
	local attrs = task.attributes or {}
	local score = (PRIORITY_SCORE[attrs.p] or 0) + (PRIORITY_SCORE[attrs.i] or 0) / 2

	local days = days_until(attrs.due)
	if days then
		if days < 0 then
			score = score + 200 -- overdue
		elseif days < 1 then
			score = score + 150 -- due today
		elseif days < 3 then
			score = score + 75
		elseif days < 7 then
			score = score + 30
		end
	end

	if task.completed then
		score = score - 100
	end
	return score
end

-- Earliest due date among the project's open tasks (own) or the project's
-- own @due(...), whichever is sooner. Returns a date table or nil.
function M.next_due(project)
	local best, best_days = nil, nil
	local function consider(date)
		local d = days_until(date)
		if d and (not best_days or d < best_days) then
			best, best_days = date, d
		end
	end
	consider(project.attributes.due)
	for _, task in ipairs(project:tasks()) do
		if not task.completed then
			consider(task.attributes and task.attributes.due)
		end
	end
	return best, best_days
end

-- Project score: project priority/importance, OKR alignment, plus the
-- average urgency of its open tasks (sub-projects included); mostly-finished
-- projects are damped.
function M.project_score(project)
	local attrs = project.attributes or {}
	local score = (PRIORITY_SCORE[attrs.p] or 0) + (PRIORITY_SCORE[attrs.i] or 0) / 2 + M.okr_bonus(project)

	local open, total = 0, 0
	for _, task in ipairs(project:all_tasks()) do
		if not task.completed then
			open = open + 1
			total = total + M.task_score(task)
		end
	end
	if open > 0 then
		score = score + total / open
	end

	local days = select(2, M.next_due(project))
	if days and days < 0 then
		score = score + 100
	end

	if project:rollup().completion > 0.8 then
		score = score * 0.5
	end
	return score
end

-- Project indicators for display: { "OKR", "P1", "DUE", "OVERDUE", ... }
function M.indicators(project)
	local out = {}
	if M.okr_count(project) > 0 then
		out[#out + 1] = "OKR"
	end
	if project.attributes.p then
		out[#out + 1] = "P" .. project.attributes.p
	end
	if project.attributes.i then
		out[#out + 1] = "I" .. project.attributes.i
	end
	local days = select(2, M.next_due(project))
	if days then
		if days < 0 then
			out[#out + 1] = "OVERDUE"
		elseif days < 1 then
			out[#out + 1] = "DUE"
		end
	end
	return out
end

-- =============================================================================
-- Comparators (a, b) -> a comes first
-- =============================================================================

local function num_or(v, default)
	return tonumber(v) or default
end

-- Memoize per sort call so expensive keys are computed once per project.
local function by_key(key_fn, ascending)
	return function()
		local cache = {}
		local function key(p)
			if cache[p] == nil then
				cache[p] = key_fn(p)
			end
			return cache[p]
		end
		return function(a, b)
			local ka, kb = key(a), key(b)
			if ka == kb then
				return a.key < b.key
			end
			if ascending then
				return ka < kb
			end
			return ka > kb
		end
	end
end

M.comparators = {
	score = by_key(M.project_score, false),
	-- OKR-linked projects first within the same priority
	priority = by_key(function(p)
		return num_or(p.attributes.p, 99) * 1000 + (M.okr_count(p) > 0 and 0 or 100) + num_or(p.attributes.i, 99)
	end, true),
	okr = by_key(function(p)
		return M.okr_count(p) * 1000 + M.project_score(p)
	end, false),
	importance = by_key(function(p)
		return num_or(p.attributes.i, 99) * 100 + num_or(p.attributes.p, 99)
	end, true),
	due = by_key(function(p)
		return select(2, M.next_due(p)) or math.huge
	end, true),
	size = by_key(function(p)
		return p:points()
	end, false),
	remaining = by_key(function(p)
		return p:rollup().points_open
	end, false),
	completion = by_key(function(p)
		return p:rollup().completion
	end, false),
	name = by_key(function(p)
		return p.name:lower()
	end, true),
	-- Document order: source order, then line number (the order of M.all()).
	path = function()
		return nil
	end,
}

-- Sort a project list in place by comparator name or function.
function M.sort(list, by, reverse)
	local cmp
	if type(by) == "function" then
		cmp = by
	else
		local factory = M.comparators[by]
		if not factory then
			error("Unknown project sort: " .. tostring(by))
		end
		cmp = factory()
	end
	if cmp then
		table.sort(list, cmp)
	end
	if reverse then
		for i = 1, math.floor(#list / 2) do
			list[i], list[#list - i + 1] = list[#list - i + 1], list[i]
		end
	end
	return list
end

return M
