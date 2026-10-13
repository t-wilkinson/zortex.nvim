-- services/xp/calculator.lua - XP formulas (pure: no state, no files)
--
-- XP is estimated effort: @size -> hours (xp.sizes) x xp.xp_per_hour x
-- priority x importance. This module says how much a task, a project and an
-- objective are worth, how a project's pool is paid out over its tasks (the
-- initiation / execution / completion curve), and how an award's Mastery
-- share is split between areas. services/xp/ledger applies it to the notes;
-- :ZortexXPGuide shows the numbers.
local M = {}

local constants = require("zortex.constants")

local cfg = {} -- Config.xp

function M.setup(opts)
	cfg = opts or {}
end

function M.config()
	return cfg
end

-- Config.xp until setup() hands it over (the projects API can run first)
local function conf()
	if next(cfg) ~= nil then
		return cfg
	end
	local Config = require("zortex.config")
	return Config.xp or (Config.defaults or {}).xp or {}
end
M.conf = conf

local function sizes(kind)
	return (conf().sizes or {})[kind] or {}
end

-- =============================================================================
-- Multipliers
-- =============================================================================

local function multiplier(map, key)
	map = map or {}
	return map[tonumber(key) or key] or map[tostring(key)] or map.default or 1
end

function M.get_priority_multiplier(priority)
	return multiplier((conf().modifiers or {}).priority_multipliers, priority)
end

function M.get_importance_multiplier(importance)
	return multiplier((conf().modifiers or {}).importance_multipliers, importance)
end

--- Priority x importance of an attribute table.
function M.modifier(attrs)
	local m = 1
	if attrs then
		if attrs.p then
			m = m * M.get_priority_multiplier(attrs.p)
		end
		if attrs.i then
			m = m * M.get_importance_multiplier(attrs.i)
		end
	end
	return m
end

local function apply_modifiers(xp, attrs)
	return xp * M.modifier(attrs)
end

function M.xp_per_hour()
	return conf().xp_per_hour or 10
end

-- =============================================================================
-- Effort: @size -> estimated hours
-- =============================================================================

--- Hours a @size stands for (kind: "task", "project", "objective"); nil when
--- the config doesn't list the size.
function M.hours(kind, size)
	if not size then
		return nil
	end
	local h = sizes(kind)[size]
	if type(h) == "table" then -- { hours = n }
		h = h.hours
	end
	return tonumber(h)
end

--- Effort points of a task, in hours: its @size (unsized and unknown sizes
--- count as md). They weigh project and key-result progress.
function M.task_points(size)
	return M.hours("task", size) or M.hours("task", constants.DEFAULT_TASK_SIZE) or 1
end

--- An explicit project @size in hours, or nil (the project is then the sum
--- of its tasks).
function M.project_points(size)
	return M.hours("project", size)
end

--- How an award's Mastery share is scaled: "key_result", "project_area",
--- "task_area" (anything else: 0).
function M.alignment(kind)
	local a = conf().alignment or {}
	local defaults = { key_result = 1.0, project_area = 0.2, task_area = 0.1 }
	local v = a[kind]
	if v == nil then
		v = defaults[kind]
	end
	return v or 0
end

function M.completion_bonus()
	return conf().completion_bonus or 0.2
end

-- =============================================================================
-- Tasks, projects, objectives
-- =============================================================================

--- XP of a task: its hours x XP per hour x priority x importance.
function M.calculate_task_xp(task)
	local attrs = task.attributes or {}
	return apply_modifiers(M.task_points(attrs.size) * M.xp_per_hour(), attrs)
end

--- A project's whole pool: @xp(n) if given; else its @size in hours x XP
--- per hour x priority x importance; else the sum of its tasks' XP.
---@param project table { attributes = {...} }
---@param tasks table[] the project's tasks
function M.calculate_project_total_xp(project, tasks)
	local attrs = project.attributes or {}
	if tonumber(attrs.xp) then
		return tonumber(attrs.xp)
	end
	local h = M.project_points(attrs.size)
	if h then
		return apply_modifiers(h * M.xp_per_hour(), attrs)
	end
	local total = 0
	for _, task in ipairs(tasks or (project.tasks and project:tasks()) or {}) do
		total = total + M.calculate_task_xp(task)
	end
	return total
end

--- Estimated hours of an objective and where they come from: its @size; else
--- the projects its key results link (their @size, or their tasks); else md.
---@return number hours, string how ("size", "projects", "default")
function M.objective_hours(objective)
	local attrs = objective.attributes or {}
	local h = M.hours("objective", attrs.size)
	if h then
		return h, "size"
	end
	local total, seen = 0, {}
	for _, kr in ipairs(objective.key_results or {}) do
		local ok, projects = pcall(function()
			return kr:project_list()
		end)
		for _, p in ipairs(ok and projects or {}) do
			if not seen[p.key] then
				seen[p.key] = true
				local ok_p, ph = pcall(function()
					return p:points()
				end)
				ph = ok_p and tonumber(ph) or 0
				total = total + ph
			end
		end
	end
	if total > 0 then
		return total, "projects"
	end
	return M.hours("objective", "md") or 30, "default"
end

--- An objective's value: @xp(n), else its hours x XP per hour x priority x
--- importance. It weighs the objective in the season and sets the bonuses.
function M.objective_value(objective)
	local attrs = objective.attributes or {}
	if tonumber(attrs.xp) then
		return tonumber(attrs.xp)
	end
	return apply_modifiers(M.objective_hours(objective) * M.xp_per_hour(), attrs)
end

--- Completing an objective (@done): the completion bonus of its value.
function M.calculate_objective_xp(objective)
	return M.objective_value(objective) * M.completion_bonus()
end

--- A key result reached: the completion bonus of its objective's value,
--- split over the objective's key results (@xp on the KR line wins).
function M.calculate_key_result_xp(kr)
	local line_attrs = kr.attributes or {}
	if tonumber(line_attrs.xp) then
		return tonumber(line_attrs.xp)
	end
	local o = kr.objective
	if not o then
		return 0
	end
	local n = math.max(1, #(o.key_results or {}))
	return M.objective_value(o) * M.completion_bonus() / n
end

-- =============================================================================
-- Project curve: how a pool is paid out over the tasks
-- =============================================================================

M.XP_CURVES = {
	-- Small projects (1-5 tasks)
	small = {
		{ tasks = 1, percent = 0.40 }, -- First task: 40%
		{ tasks = 2, percent = 0.40 }, -- Next 2 tasks: 40%
		{ tasks = 2, percent = 0.20 }, -- Remaining: 20%
	},
	-- Medium projects (6-15 tasks)
	medium = {
		{ tasks = 3, percent = 0.25 }, -- First 3: 25% (initiation)
		{ tasks = 0.60, percent = 0.50 }, -- 60% of tasks: 50% (execution)
		{ tasks = 3, percent = 0.25 }, -- Last 3: 25% (completion)
	},
	-- Large projects (16+ tasks)
	large = {
		{ tasks = 0.15, percent = 0.20 }, -- First 15%: 20% XP
		{ tasks = 0.70, percent = 0.50 }, -- Middle 70%: 50% XP
		{ tasks = 0.15, percent = 0.30 }, -- Last 15%: 30% XP
	},
}

function M._select_curve(total_tasks)
	if total_tasks <= 5 then
		return { type = "small", curve = M.XP_CURVES.small }
	elseif total_tasks <= 15 then
		return { type = "medium", curve = M.XP_CURVES.medium }
	end
	return { type = "large", curve = M.XP_CURVES.large }
end

-- Phases for `total_tasks`. The last phase takes whatever tasks are left, so
-- every task belongs to a phase and the whole pool is paid out at 100%.
-- When there are fewer tasks than phases, the percentages of the phases
-- that got no task are folded into the last one that did.
function M._build_phase_map(curve_data, total_tasks)
	local phases = {}
	local counted = 0
	local n = #curve_data.curve
	for i, phase in ipairs(curve_data.curve) do
		local count
		if i == n then
			count = total_tasks - counted
		elseif phase.tasks < 1 then
			count = math.max(1, math.floor(total_tasks * phase.tasks))
		else
			count = phase.tasks
		end
		count = math.min(count, total_tasks - counted)
		if count > 0 then
			phases[#phases + 1] = {
				start_task = counted + 1,
				end_task = counted + count,
				task_count = count,
				xp_percent = phase.percent,
				name = i == 1 and "initiation" or i == n and "completion" or "execution",
			}
			counted = counted + count
		elseif #phases > 0 then
			phases[#phases].xp_percent = phases[#phases].xp_percent + phase.percent
		end
	end
	return phases
end

--- XP earned after `completed` of `total_tasks` tasks, from a pool of total_xp.
function M._calculate_curve_xp(phases, completed, total_tasks, total_xp)
	if completed <= 0 or total_tasks <= 0 then
		return 0
	end
	local earned, counted = 0, 0
	for _, phase in ipairs(phases) do
		if completed <= counted then
			break
		end
		local in_phase = math.min(phase.task_count, completed - counted)
		earned = earned + total_xp * phase.xp_percent * (in_phase / phase.task_count)
		counted = counted + in_phase
	end
	return earned
end

--- The marginal XP of each completion: steps[k] = XP for the k-th task done.
function M.curve_steps(total_xp, total_tasks, completed)
	local phases = M._build_phase_map(M._select_curve(total_tasks), total_tasks)
	local steps, prev = {}, 0
	for k = 1, completed do
		local now = M._calculate_curve_xp(phases, k, total_tasks, total_xp)
		steps[k] = now - prev
		prev = now
	end
	return steps, phases
end

--- { total_xp, earned_xp, completion_percent, completed_tasks, total_tasks, curve_type, phases }
--- for a Project (its own tasks).
function M.calculate_project_xp(project)
	local tasks = project:tasks()
	local stats = project:stats()
	local total_xp = M.calculate_project_total_xp(project, tasks)
	if stats.total == 0 then
		return 0, { total_xp = total_xp, earned_xp = 0, completion_percent = 0, completed_tasks = 0, total_tasks = 0 }
	end
	local curve = M._select_curve(stats.total)
	local phases = M._build_phase_map(curve, stats.total)
	local earned = M._calculate_curve_xp(phases, stats.done, stats.total, total_xp)
	if project.attributes and project.attributes.done then
		earned = total_xp -- a finished project pays out in full
	end
	earned = math.floor(earned + 0.5)
	return earned,
		{
			total_xp = total_xp,
			earned_xp = earned,
			completion_percent = (stats.done / stats.total) * 100,
			completed_tasks = stats.done,
			total_tasks = stats.total,
			curve_type = curve.type,
			phases = phases,
		}
end

-- =============================================================================
-- Sharing an award between areas
-- =============================================================================

--- Split `amount` over an ordered list of areas: the first area gets the
--- largest part (harmonic weights 1, 1/2, 1/3, ...). Returns amounts by index.
function M._distribute_on_curve(total_value, num_values)
	if num_values <= 0 then
		return {}
	end
	local weights, total_weight = {}, 0
	for i = 1, num_values do
		weights[i] = 1 / i
		total_weight = total_weight + weights[i]
	end
	local results, sum = {}, 0
	for i = 1, num_values - 1 do
		results[i] = total_value * weights[i] / total_weight
		sum = sum + results[i]
	end
	results[num_values] = total_value - sum
	return results
end

--- Area shares of an award: `share` of xp goes to the areas (ordered, most
--- relevant first) and is split between them on the harmonic curve.
--- Returns { [area_key] = amount }.
function M.area_shares(xp, area_keys, share)
	local out = {}
	local parts = M._distribute_on_curve(xp * (share or 0), #area_keys)
	for i, key in ipairs(area_keys) do
		out[key] = (out[key] or 0) + parts[i]
	end
	return out
end

return M
