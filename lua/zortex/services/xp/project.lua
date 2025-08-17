-- services/xp/project.lua - Calculate project xp

local M = {}

-- =============================================================================
-- Project XP Curve System
-- =============================================================================

function M.calculate_curve_xp(curve, completed, total, xp)
  local completion = completed / total
  local phase_completion, phase_proportion
  for p_completion, p_proportion in pairs(curve) do
    if completion <= phase_completion then
      phase_completion = p_completion
      phase_proportion = p_proportion
      break
    end
  end

  return xp * ((phase_completion / total) + phase_proportion * completion)
end

function M.get_curve(total_tasks)
  -- { completion_percent = xp_proportion }
  -- { completed = xp_proportion }

	if total_tasks <= 3 then
    return { [0] = 1 }
	elseif total_tasks <= 7 then
    { }
		-- Small project: 2 initiation, rest execution, last is completion
		phases.initiation_end = 2
		phases.execution_end = total_tasks - 1
		phases.completion_start = total_tasks
	elseif total_tasks <= 20 then
		-- Medium project: 3 initiation, last 2 completion
		phases.initiation_end = 3
		phases.execution_end = total_tasks - 2
		phases.completion_start = total_tasks - 1
	else
		-- Large project: 15% initiation, 70% execution, 15% completion
		phases.initiation_end = math.max(3, math.floor(total_tasks * 0.15))
		phases.completion_start = total_tasks - math.max(3, math.floor(total_tasks * 0.15)) + 1
		phases.execution_end = phases.completion_start - 1
	end

end

-- Calculate project XP using a 3-phase curve system
function M.calculate_project_curve_xp(project)
	local tasks = project.tasks or {}
	local total_tasks = #tasks

	if total_tasks == 0 then
		return {
			total_xp = 0,
			earned_xp = 0,
			phase_info = nil,
			task_xp_map = {},
		}
	end

	-- Get project size multiplier
	local project_size = project.attributes and project.attributes.size or "md"
	local project_mult = M.PROJECT_SIZES[project_size] and M.PROJECT_SIZES[project_size].multiplier or 1.0

	-- Calculate phase boundaries dynamically
	local phases = M._calculate_phase_boundaries(total_tasks)

	-- Calculate base XP pool for the project
	local base_pool = M._calculate_project_base_pool(tasks, project.attributes)

	-- Apply project multipliers
	base_pool = base_pool * project_mult

	-- Distribute XP across tasks using the curve
	local task_xp_map = M._distribute_xp_on_curve(tasks, base_pool, phases)

	-- Calculate totals
	local total_xp = 0
	local earned_xp = 0

	for task_id, xp_data in pairs(task_xp_map) do
		total_xp = total_xp + xp_data.potential_xp
		if xp_data.completed then
			earned_xp = earned_xp + xp_data.earned_xp
		end
	end

	-- Add completion bonus if all tasks done
	local completed_count = 0
	for _, task in ipairs(tasks) do
		if task.completed then
			completed_count = completed_count + 1
		end
	end

	if completed_count == total_tasks and total_tasks > 0 then
		local completion_bonus = math.floor(base_pool * 0.25) -- 25% bonus
		earned_xp = earned_xp + completion_bonus
		total_xp = total_xp + completion_bonus
	end

	return {
		total_xp = math.floor(total_xp),
		earned_xp = math.floor(earned_xp),
		phase_info = phases,
		task_xp_map = task_xp_map,
		completion_percentage = total_tasks > 0 and (completed_count / total_tasks) or 0,
		completed_tasks = completed_count,
		total_tasks = total_tasks,
	}
end

-- Calculate dynamic phase boundaries based on project size
function M._calculate_phase_boundaries(total_tasks)
	local phases = {}

	if total_tasks <= 3 then
		-- Very small project: all tasks get initiation bonus
		phases.initiation_end = total_tasks
		phases.execution_end = total_tasks
		phases.completion_start = total_tasks
	elseif total_tasks <= 7 then
		-- Small project: 2 initiation, rest execution, last is completion
		phases.initiation_end = 2
		phases.execution_end = total_tasks - 1
		phases.completion_start = total_tasks
	elseif total_tasks <= 20 then
		-- Medium project: 3 initiation, last 2 completion
		phases.initiation_end = 3
		phases.execution_end = total_tasks - 2
		phases.completion_start = total_tasks - 1
	else
		-- Large project: 15% initiation, 70% execution, 15% completion
		phases.initiation_end = math.max(3, math.floor(total_tasks * 0.15))
		phases.completion_start = total_tasks - math.max(3, math.floor(total_tasks * 0.15)) + 1
		phases.execution_end = phases.completion_start - 1
	end

	-- Calculate phase multipliers based on project size
	phases.initiation_multiplier = 2.0 -- 2x XP for early momentum
	phases.execution_multiplier = 1.0 -- Standard XP
	phases.completion_multiplier = 3.0 -- 3x XP for finishing strong

	return phases
end

-- Calculate base XP pool from tasks
function M._calculate_project_base_pool(tasks, project_attrs)
	local base_pool = 0

	-- Sum up task values
	for _, task in ipairs(tasks) do
		local task_size = task.attributes and task.attributes.size or "md"
		local task_def = M.TASK_SIZES[task_size] or M.TASK_SIZES.md
		local task_base = task_def.base_xp

		-- Apply task priority/importance
		if task.attributes then
			if task.attributes.p then
				task_base = task_base * M.get_priority_multiplier(task.attributes.p)
			end
			if task.attributes.i then
				task_base = task_base * M.get_importance_multiplier(task.attributes.i)
			end
		end

		base_pool = base_pool + task_base
	end

	-- Apply project-level modifiers
	if project_attrs then
		if project_attrs.p then
			base_pool = base_pool * M.get_priority_multiplier(project_attrs.p)
		end
		if project_attrs.i then
			base_pool = base_pool * M.get_importance_multiplier(project_attrs.i)
		end
	end

	return base_pool
end

-- Distribute XP across tasks using the curve
function M._distribute_xp_on_curve(tasks, base_pool, phases)
	local task_xp_map = {}

	-- First, identify completed tasks and their order
	local completed_tasks = {}
	local uncompleted_tasks = {}

	for i, task in ipairs(tasks) do
		task.index = i -- Track original position
		if task.completed then
			-- Try to determine completion order from @done date
			local done_date = task.attributes and task.attributes.done
			task.completion_order = done_date and os.time(done_date) or i
			table.insert(completed_tasks, task)
		else
			table.insert(uncompleted_tasks, task)
		end
	end

	-- Sort completed tasks by completion order
	table.sort(completed_tasks, function(a, b)
		return a.completion_order < b.completion_order
	end)

	-- Calculate XP per task position
	local xp_per_position = M._calculate_position_xp(#tasks, base_pool, phases)

	-- Assign XP to completed tasks based on their completion order
	for order, task in ipairs(completed_tasks) do
		local task_id = task.attributes and task.attributes.id or ("task_" .. task.index)
		local position_xp = xp_per_position[order] or xp_per_position[#xp_per_position]

		task_xp_map[task_id] = {
			completed = true,
			earned_xp = position_xp,
			potential_xp = position_xp,
			phase = M._get_task_phase(order, phases),
			completion_order = order,
			task_index = task.index,
		}
	end

	-- Assign potential XP to uncompleted tasks
	local next_order = #completed_tasks + 1
	for _, task in ipairs(uncompleted_tasks) do
		local task_id = task.attributes and task.attributes.id or ("task_" .. task.index)
		local position_xp = xp_per_position[next_order] or xp_per_position[#xp_per_position]

		task_xp_map[task_id] = {
			completed = false,
			earned_xp = 0,
			potential_xp = position_xp,
			phase = M._get_task_phase(next_order, phases),
			completion_order = nil,
			task_index = task.index,
		}
		next_order = next_order + 1
	end

	return task_xp_map
end

-- Calculate XP for each position on the curve
function M._calculate_position_xp(total_tasks, base_pool, phases)
	local position_xp = {}

	-- Calculate total weight
	local total_weight = 0
	for i = 1, total_tasks do
		local phase_mult = 1.0
		if i <= phases.initiation_end then
			phase_mult = phases.initiation_multiplier
		elseif i >= phases.completion_start then
			phase_mult = phases.completion_multiplier
		else
			phase_mult = phases.execution_multiplier
		end

		-- Add progression within phase (slight increase as you progress)
		local phase_progress = M._calculate_phase_progress(i, phases)
		phase_mult = phase_mult * (1.0 + phase_progress * 0.2) -- Up to 20% bonus

		total_weight = total_weight + phase_mult
	end

	-- Distribute pool according to weights
	for i = 1, total_tasks do
		local phase_mult = 1.0
		if i <= phases.initiation_end then
			phase_mult = phases.initiation_multiplier
		elseif i >= phases.completion_start then
			phase_mult = phases.completion_multiplier
		else
			phase_mult = phases.execution_multiplier
		end

		local phase_progress = M._calculate_phase_progress(i, phases)
		phase_mult = phase_mult * (1.0 + phase_progress * 0.2)

		position_xp[i] = math.floor((base_pool * phase_mult) / total_weight)
	end

	return position_xp
end

-- Calculate progress within a phase (0 to 1)
function M._calculate_phase_progress(position, phases)
	if position <= phases.initiation_end then
		-- Initiation phase
		return (position - 1) / math.max(1, phases.initiation_end)
	elseif position >= phases.completion_start then
		-- Completion phase
		local phase_size = phases.completion_start - phases.initiation_end
		return (position - phases.completion_start) / math.max(1, phase_size)
	else
		-- Execution phase
		local phase_size = phases.execution_end - phases.initiation_end
		return (position - phases.initiation_end) / math.max(1, phase_size)
	end
end

-- Get which phase a task is in
function M._get_task_phase(position, phases)
	if position <= phases.initiation_end then
		return "initiation"
	elseif position >= phases.completion_start then
		return "completion"
	else
		return "execution"
	end
end

-- Get nice display of phase info
function M.format_phase_info(phase_info, current_position)
	if not phase_info then
		return "No phase info"
	end

	local phase = M._get_task_phase(current_position or 1, phase_info)
	local mult = 1.0

	if phase == "initiation" then
		mult = phase_info.initiation_multiplier
	elseif phase == "completion" then
		mult = phase_info.completion_multiplier
	else
		mult = phase_info.execution_multiplier
	end

	return string.format(
		"Phase: %s (%.1fx XP) | Tasks 1-%d: Initiation | %d-%d: Execution | %d+: Completion",
		phase:gsub("^%l", string.upper),
		mult,
		phase_info.initiation_end,
		phase_info.initiation_end + 1,
		phase_info.execution_end,
		phase_info.completion_start
	)
end

return M
