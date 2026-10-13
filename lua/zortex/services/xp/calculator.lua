-- services/xp/calculator.lua - XP formulas (pure: no state, no files)
--
-- How much a task, a project and an objective are worth, how a project's
-- pool is paid out over its tasks (the initiation / execution / completion
-- curve), and how an award is shared between areas. services/xp/ledger
-- applies these to the notes.
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
local function sources()
	if cfg.sources then
		return cfg.sources
	end
	local Config = require("zortex.config")
	local xp = Config.xp or (Config.defaults or {}).xp
	return type(xp) == "table" and xp.sources or {}
end

local function source(name)
	return sources()[name] or {}
end

-- =============================================================================
-- Multipliers
-- =============================================================================

local function multiplier(map, key)
	map = map or {}
	return map[tonumber(key) or key] or map[tostring(key)] or map.default or 1
end

function M.get_priority_multiplier(priority)
	return multiplier((cfg.modifiers or {}).priority_multipliers, priority)
end

function M.get_importance_multiplier(importance)
	return multiplier((cfg.modifiers or {}).importance_multipliers, importance)
end

-- Size multiplier from xp.sources.<kind>.sizes (a number or { multiplier }).
-- No size: 1. A size the config doesn't list: 1 as well.
local function size_multiplier(kind, size)
	if not size then
		return 1
	end
	local entry = (source(kind).sizes or {})[size]
	if type(entry) == "table" then
		return entry.multiplier or 1
	elseif type(entry) == "number" then
		return entry
	end
	return 1
end
M.size_multiplier = size_multiplier

--- Effort points, in md-task units (xp.sources.task.sizes): what a task's
--- size weighs in project and key-result progress. Unsized tasks are md.
function M.task_points(size)
	return size_multiplier("task", size or constants.DEFAULT_TASK_SIZE)
end

--- An explicit project @size in the same units: the project's XP for that
--- size over a md task's (70 × 1.5 / 10 = 10.5 points for @size(lg)), or
--- nil when the config doesn't list the size.
function M.project_points(size)
	local entry = size and (source("project").sizes or {})[size]
	if entry == nil then
		return nil
	end
	local task_base = source("task").base_xp or 10
	return (source("project").base_xp or 70) * size_multiplier("project", size) / task_base
end

local function apply_modifiers(xp, attrs)
	if attrs then
		if attrs.p then
			xp = xp * M.get_priority_multiplier(attrs.p)
		end
		if attrs.i then
			xp = xp * M.get_importance_multiplier(attrs.i)
		end
	end
	return xp
end

-- =============================================================================
-- Tasks, projects, objectives
-- =============================================================================

--- XP of a task: base_xp × size × priority × importance.
function M.calculate_task_xp(task)
	local attrs = task.attributes or {}
	local xp = (source("task").base_xp or 10) * size_multiplier("task", attrs.size)
	return apply_modifiers(xp, attrs)
end

--- A project's whole pool: @xp(n) if given; else base_xp × @size(...) ×
--- priority × importance; else the sum of its tasks' XP.
---@param project table { attributes = {...} }
---@param tasks table[] the project's tasks
function M.calculate_project_total_xp(project, tasks)
	local attrs = project.attributes or {}
	if tonumber(attrs.xp) then
		return tonumber(attrs.xp)
	end
	if attrs.size and (source("project").sizes or {})[attrs.size] then
		return math.floor(apply_modifiers((source("project").base_xp or 70) * size_multiplier("project", attrs.size), attrs))
	end
	local total = 0
	for _, task in ipairs(tasks or (project.tasks and project:tasks()) or {}) do
		total = total + M.calculate_task_xp(task)
	end
	return total
end

-- Objective time span ("3M", "1Y", "Q") -> a key of sources.objective.sizes
local function span_key(span)
	local sizes = source("objective").sizes or {}
	if not span then
		return nil
	end
	if sizes[span] then
		return span
	end
	local n, unit = tostring(span):upper():match("^(%d*)([MQY])$")
	if not unit then
		return nil
	end
	local months = (tonumber(n) or 1) * ({ M = 1, Q = 3, Y = 12 })[unit]
	if months <= 1 then
		return "M"
	elseif months <= 3 then
		return "Q"
	elseif months <= 12 then
		return "Y"
	elseif months <= 60 then
		return "5Y"
	end
	return "10Y"
end

--- XP of a completed objective: base_xp × time span (3M ~ Q, 1Y, 5Y, ...) ×
--- priority × importance; @xp(n) overrides.
function M.calculate_objective_xp(objective)
	local attrs = objective.attributes or {}
	if tonumber(attrs.xp) then
		return tonumber(attrs.xp)
	end
	local key = span_key(objective.span)
	return apply_modifiers((source("objective").base_xp or 20) * size_multiplier("objective", key), attrs)
end
M.span_key = span_key

--- A key result reached (its projects done, or checked): base_xp ×
--- the objective's priority × importance (@xp on the KR line wins).
function M.calculate_key_result_xp(kr)
	local line_attrs = kr.attributes or {}
	if tonumber(line_attrs.xp) then
		return tonumber(line_attrs.xp)
	end
	local o = kr.objective
	return apply_modifiers(source("key_result").base_xp or 30, o and o.attributes or nil)
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

-- Configured fractions (with the defaults the old pipeline hard-coded)
function M.area_share(kind, via_key_result)
	local src = source(kind)
	if via_key_result then
		return src.key_result or 1.0
	end
	return src.area or ((kind == "objective" or kind == "key_result") and 1.0 or 0.2)
end

function M.season_share(kind)
	local src = source(kind)
	if src.season ~= nil then
		return src.season
	end
	return kind == "objective" and 0 or 1.0
end

return M
