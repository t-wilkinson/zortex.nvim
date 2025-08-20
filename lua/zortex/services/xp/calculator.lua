-- services/xp/calculator.lua - Core XP calculations and formulas
local M = {}

-- Configuration (will be set by setup)
local cfg = {} -- Config.xp

-- =============================================================================
-- Size Multipliers
-- =============================================================================

-- Get priority multiplier
function M.get_priority_multiplier(priority)
	local multipliers = cfg.modifiers.priority_multipliers
	return multipliers[priority] or multipliers.default
end

-- Get importance multiplier
function M.get_importance_multiplier(importance)
	local multipliers = cfg.modifiers.importance_multipliers
	return multipliers[importance] or multipliers.default
end

-- -- Get time horizon multiplier for objectives
-- function M.get_time_multiplier(time_horizon)
-- 	local multipliers = cfg.area.time_multipliers
-- 	return multipliers[time_horizon:lower()] or 1.0
-- end
--
-- -- Calculate decay factor for old objectives
-- function M.calculate_decay_factor(days_old)
-- 	local decay = cfg.area.decay_rate
-- 	local grace = cfg.area.decay_grace_days or 30
--
-- 	if days_old <= grace then
-- 		return 1.0
-- 	end
--
-- 	local days_decaying = days_old - grace
-- 	return math.max(0.5, 1.0 - (decay * days_decaying))
-- end

-- -- Calculate XP for completing an objective
-- function M.calculate_objective_xp(time_horizon, created_date)
-- 	local base_xp = cfg.area.objective_base_xp or 500
-- 	local time_mult = M.get_time_multiplier(time_horizon)
--
-- 	-- Calculate decay if objective is old
-- 	local decay_factor = 1.0
-- 	if created_date then
-- 		local days_old = math.floor((os.time() - created_date) / 86400)
-- 		decay_factor = M.calculate_decay_factor(days_old)
-- 	end
--
-- 	return math.floor(base_xp * time_mult * decay_factor)
-- end

-- =============================================================================
-- XP Curves - Define phase distributions based on project size
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

-- =============================================================================
-- Main XP Calculation
-- =============================================================================

function M.calculate_xp(context)
	-- Determine if this is a task or project
	if context.type == "project" then
		return M.calculate_project_xp(context.project)
	elseif context.type == "task" then
		return M.calculate_task_xp(context.task)
	else
		return 0
	end
end

-- Calculate task XP (standalone or within project)
function M.calculate_task_xp(task)
	local task_size = task.attributes and task.attributes.size
	local modifier = cfg.modifiers.task_sizes[task_size]
	local task_multiplier = modifier and modifier.multiplier or 1
	local base_xp = cfg.modifiers.task_sizes.base * task_multiplier

	-- Apply task modifiers
	if task.attributes then
		if task.attributes.p then
			base_xp = base_xp * M.get_priority_multiplier(task.attributes.p)
		end
		if task.attributes.i then
			base_xp = base_xp * M.get_importance_multiplier(task.attributes.i)
		end
	end

	return base_xp
end

-- Calculate project XP using curve system
function M.calculate_project_xp(project)
	local tasks = project.tasks or {}
	local total_tasks = #tasks

	if total_tasks == 0 then
		return {
			total_xp = 0,
			earned_xp = 0,
			completion_percent = 0,
		}
	end

	-- Step 1: Calculate total project XP pool
	local total_xp = M.calculate_project_total_xp(project)

	-- Step 2: Select appropriate curve
	local curve = M._select_curve(total_tasks)

	-- Step 3: Build phase map
	local phases = M._build_phase_map(curve, total_tasks)

	-- Step 4: Calculate earned XP based on completion
	local earned_xp = M._calculate_curve_xp(phases, project.completed_tasks, total_tasks, total_xp)

	return earned_xp,
		{
			total_xp = total_xp,
			earned_xp = earned_xp,
			completion_percent = (project.completed_tasks / total_tasks) * 100,
			completed_tasks = project.completed_tasks,
			total_tasks = total_tasks,
			curve_type = curve.type,
			phases = phases,
		}
end

-- Calculate total project XP pool
function M.calculate_project_total_xp(project)
	local project_size = project.attributes and project.attributes.size

	local modifier = cfg.modifiers.project_sizes[project_size]
	if project_size and modifier then
		-- Use explicit project size for total XP
		local base_xp = cfg.modifiers.project_sizes.base_xp * modifier.multiplier

		-- Apply project modifiers
		if project.attributes then
			if project.attributes.p then
				base_xp = base_xp * M.get_priority_multiplier(project.attributes.p)
			end
			if project.attributes.i then
				base_xp = base_xp * M.get_importance_multiplier(project.attributes.i)
			end
		end

		return math.floor(base_xp)
	else
		-- Calculate from sum of task sizes
		local total = 0
		for _, task in ipairs(project.tasks or {}) do
			total = total + M.calculate_task_xp(task)
		end

		return total
	end
end

-- Select curve based on project size
function M._select_curve(total_tasks)
	if total_tasks <= 5 then
		return { type = "small", curve = M.XP_CURVES.small }
	elseif total_tasks <= 15 then
		return { type = "medium", curve = M.XP_CURVES.medium }
	else
		return { type = "large", curve = M.XP_CURVES.large }
	end
end

-- Build phase map from curve definition
function M._build_phase_map(curve_data, total_tasks)
	local phases = {}
	local task_count = 0

	for i, phase in ipairs(curve_data.curve) do
		local phase_tasks

		if phase.tasks < 1 then
			-- Percentage of total tasks
			phase_tasks = math.max(1, math.floor(total_tasks * phase.tasks))
		else
			-- Absolute number of tasks
			phase_tasks = math.min(phase.tasks, total_tasks - task_count)
		end

		-- Ensure we don't exceed total tasks
		phase_tasks = math.min(phase_tasks, total_tasks - task_count)

		table.insert(phases, {
			start_task = task_count + 1,
			end_task = task_count + phase_tasks,
			task_count = phase_tasks,
			xp_percent = phase.percent,
			name = i == 1 and "initiation" or i == #curve_data.curve and "completion" or "execution",
		})

		task_count = task_count + phase_tasks

		if task_count >= total_tasks then
			break
		end
	end

	return phases
end

-- Core curve XP calculation
function M._calculate_curve_xp(phases, completed_tasks, total_tasks, total_xp)
	if completed_tasks == 0 or total_tasks == 0 then
		return 0
	end

	local earned_xp = 0
	local tasks_counted = 0

	for _, phase in ipairs(phases) do
		if completed_tasks <= tasks_counted then
			-- Haven't reached this phase yet
			break
		end

		local tasks_in_phase = math.min(phase.task_count, completed_tasks - tasks_counted)

		-- Calculate phase completion ratio
		local phase_completion = tasks_in_phase / phase.task_count

		-- Award proportional XP for this phase
		earned_xp = earned_xp + (total_xp * phase.xp_percent * phase_completion)

		tasks_counted = tasks_counted + tasks_in_phase
	end

	return math.floor(earned_xp)
end

-- =============================================================================
-- XP Distribution Rules
-- =============================================================================

function M.calculate_distributions(xp_amount, areas)
	local distributions = {}

	-- Season always gets 100%
	table.insert(distributions, {
		target = "season",
		amount = xp_amount,
	})

	-- Area transference depends on linkage type
	local area_percent = 0
	local area_distribution = M._distribute_on_curve(xp_amount, #areas)
	local i = 0

	for area_path, link in pairs(areas) do
		i = i + 1

		if link.type == "basic" then
			area_percent = 0.2
		elseif link.type == "key_result" then
			area_percent = 1
		end

		table.insert(distributions, {
			target = "area",
			path = area_path,
			amount = area_distribution[i] * area_percent,
		})
	end

	return distributions
end

-- Distributes discrete values on 1/x curve
function M._distribute_on_curve(total_value, num_values)
	if num_values <= 0 then
		return {}
	end

	local weights = {}
	local total_weight = 0

	-- 1. Generate a raw weight for each position (1/1, 1/2, 1/3, etc.)
	--    This is based on the Harmonic Series.
	for i = 1, num_values do
		local weight = 1 / i
		weights[i] = weight
		total_weight = total_weight + weight
	end

	local results = {}
	local sum_of_results = 0

	-- 2. Calculate the value for all but the last position
	for i = 1, num_values - 1 do
		-- Normalize the weight to get its proportion of the total
		local proportion = weights[i] / total_weight
		local value = total_value * proportion
		results[i] = value
		sum_of_results = sum_of_results + value
	end

	-- 3. Calculate the last value by subtracting the sum of the others.
	--    This ensures the total is *exactly* correct and avoids floating-point errors.
	results[num_values] = total_value - sum_of_results

	return results
end

function M.setup(opts)
	cfg = opts
end

return M
