-- features/xp.lua - Revamped XP System with Area and Project XP
local M = {}

local xp_config = require("zortex.features.xp_config")
local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")

-- =============================================================================
-- State Management
-- =============================================================================

local state = {
	-- Area XP data: area_path -> { xp, level }
	area_xp = {},

	-- Project XP data: project_name -> { xp, level, task_count, completed_tasks }
	project_xp = {},

	-- Season data
	current_season = nil,
	season_xp = 0,
	season_level = 1,
}

-- =============================================================================
-- Area XP System
-- =============================================================================

-- Calculate level from XP
function M.calculate_area_level(xp)
	local level = 1
	while xp >= xp_config.calculate_area_level_xp(level + 1) do
		level = level + 1
	end
	return level
end

-- Get area progress to next level
function M.get_area_progress(xp)
	local level = M.calculate_area_level(xp)
	local current_threshold = xp_config.calculate_area_level_xp(level)
	local next_threshold = xp_config.calculate_area_level_xp(level + 1)

	local progress = (xp - current_threshold) / (next_threshold - current_threshold)
	return level, progress, next_threshold - xp
end

-- Add XP to area with bubbling
function M.add_area_xp(area_path, xp_amount, parent_links)
	-- Initialize if needed
	if not state.area_xp[area_path] then
		state.area_xp[area_path] = { xp = 0, level = 1 }
	end

	-- Add XP
	local area = state.area_xp[area_path]
	local old_level = area.level
	area.xp = area.xp + xp_amount
	area.level = M.calculate_area_level(area.xp)

	-- Check for level up
	if area.level > old_level then
		vim.notify(string.format("Area Level Up! %s is now level %d", area_path, area.level), vim.log.levels.INFO)
	end

	-- Bubble XP to parent areas
	if parent_links and #parent_links > 0 then
		local bubble_amount = math.floor(xp_amount * xp_config.get("area.bubble_percentage"))

		for _, parent_link in ipairs(parent_links) do
			-- Parse the parent area link
			local parsed = parser.parse_link_definition(parent_link)
			if parsed and #parsed.components > 0 then
				-- Build parent path from components
				local parent_path = M.build_area_path(parsed.components)
				if parent_path then
					-- Recursive call without further parents to prevent infinite loops
					M.add_area_xp(parent_path, bubble_amount, nil)
				end
			end
		end
	end

	-- Save state
	M.save_state()
end

-- Build area path from link components
function M.build_area_path(components)
	local path_parts = {}

	for _, comp in ipairs(components) do
		if comp.type == "article" and (comp.text == "A" or comp.text == "Areas") then
			-- Skip the "A" or "Areas" prefix
		elseif comp.type == "heading" or comp.type == "label" then
			table.insert(path_parts, comp.text)
		end
	end

	if #path_parts > 0 then
		return table.concat(path_parts, "/")
	end

	return nil
end

-- =============================================================================
-- Project XP System
-- =============================================================================

-- Calculate season level from XP
function M.calculate_season_level(xp)
	local level = 1
	while xp >= xp_config.calculate_season_level_xp(level + 1) do
		level = level + 1
	end
	return level
end

-- Initialize project tracking
function M.init_project(project_name)
	if not state.project_xp[project_name] then
		state.project_xp[project_name] = {
			xp = 0,
			level = 1,
			task_count = 0,
			completed_tasks = 0,
		}
	end
end

-- Add XP for completed task
function M.complete_task(project_name, task_position, total_tasks, area_links)
	M.init_project(project_name)

	local project = state.project_xp[project_name]
	project.completed_tasks = project.completed_tasks + 1
	project.task_count = math.max(project.task_count, total_tasks)

	-- Calculate task XP
	local task_xp = xp_config.calculate_task_xp(task_position, total_tasks)
	project.xp = project.xp + task_xp

	-- Add to season XP
	if state.current_season then
		state.season_xp = state.season_xp + task_xp
		local old_level = state.season_level
		state.season_level = M.calculate_season_level(state.season_xp)

		-- Check for season level up
		if state.season_level > old_level then
			local tier = xp_config.get_season_tier(state.season_level)
			vim.notify(
				string.format("Season Level %d! Tier: %s", state.season_level, tier and tier.name or "Max"),
				vim.log.levels.INFO
			)
		end
	end

	-- Transfer 10% to linked areas
	if area_links and #area_links > 0 then
		local transfer_rate = xp_config.get("project.area_transfer_rate")
		local area_xp = math.floor(task_xp * transfer_rate)

		-- Split evenly among linked areas
		local xp_per_area = math.floor(area_xp / #area_links)
		for _, area_link in ipairs(area_links) do
			local parsed = parser.parse_link_definition(area_link)
			if parsed then
				local area_path = M.build_area_path(parsed.components)
				if area_path then
					M.add_area_xp(area_path, xp_per_area, nil)
				end
			end
		end
	end

	-- Check for project completion
	if task_position == total_tasks then
		vim.notify(string.format("Project Complete! %s earned %d XP", project_name, project.xp), vim.log.levels.INFO)
	end

	-- Save state
	M.save_state()

	return task_xp
end

-- =============================================================================
-- Objective Completion
-- =============================================================================

-- Complete an objective (awards area XP)
function M.complete_objective(objective_text, time_horizon, area_links, created_date)
	-- Calculate base XP with time multiplier
	local base_xp = 500 -- Base objective XP
	local time_mult = xp_config.get_time_multiplier(time_horizon)

	-- Calculate decay if objective is old
	local decay_factor = 1.0
	if created_date then
		local days_old = math.floor((os.time() - created_date) / 86400)
		decay_factor = xp_config.calculate_decay_factor(days_old)
	end

	local total_xp = math.floor(base_xp * time_mult * decay_factor)

	-- Award XP to linked areas
	if area_links and #area_links > 0 then
		-- Split evenly among areas
		local xp_per_area = math.floor(total_xp / #area_links)

		for _, area_link in ipairs(area_links) do
			local parsed = parser.parse_link_definition(area_link)
			if parsed then
				local area_path = M.build_area_path(parsed.components)
				if area_path then
					-- Include parent links for bubbling
					M.add_area_xp(area_path, xp_per_area, area_links)
				end
			end
		end

		vim.notify(string.format("Objective Complete! +%d Area XP", total_xp), vim.log.levels.INFO)
	end

	return total_xp
end

-- =============================================================================
-- Season Management
-- =============================================================================

-- Start a new season
function M.start_season(name, end_date)
	state.current_season = {
		name = name,
		start_date = os.date("%Y-%m-%d"),
		end_date = end_date,
		start_time = os.time(),
	}
	state.season_xp = 0
	state.season_level = 1

	M.save_state()

	vim.notify(string.format("Season '%s' started! Ends: %s", name, end_date), vim.log.levels.INFO)
end

-- End current season
function M.end_season()
	if not state.current_season then
		vim.notify("No active season", vim.log.levels.WARN)
		return
	end

	local season = state.current_season
	local final_tier = xp_config.get_season_tier(state.season_level)

	-- Archive season data
	local season_data = {
		name = season.name,
		start_date = season.start_date,
		end_date = os.date("%Y-%m-%d"),
		final_level = state.season_level,
		final_xp = state.season_xp,
		final_tier = final_tier and final_tier.name or "None",
		projects_completed = 0,
	}

	-- Count completed projects
	for _, project in pairs(state.project_xp) do
		if project.completed_tasks == project.task_count and project.task_count > 0 then
			season_data.projects_completed = season_data.projects_completed + 1
		end
	end

	-- Reset season data
	state.current_season = nil
	state.season_xp = 0
	state.season_level = 1

	-- Reset project data for new season
	state.project_xp = {}

	M.save_state()

	vim.notify(
		string.format(
			"Season '%s' ended! Final: Level %d (%s tier), %d projects completed",
			season_data.name,
			season_data.final_level,
			season_data.final_tier,
			season_data.projects_completed
		),
		vim.log.levels.INFO
	)

	return season_data
end

-- Get current season status
function M.get_season_status()
	if not state.current_season then
		return nil
	end

	local tier = xp_config.get_season_tier(state.season_level)
	local next_tier = xp_config.get_next_tier(state.season_level)
	local progress = xp_config.calculate_tier_progress(state.season_xp, state.season_level)

	return {
		season = state.current_season,
		level = state.season_level,
		xp = state.season_xp,
		current_tier = tier,
		next_tier = next_tier,
		progress_to_next = progress,
	}
end

-- =============================================================================
-- State Persistence
-- =============================================================================

function M.save_state()
	local data_file = fs.get_file_path(".zortex/xp_state.json")
	if data_file then
		fs.write_json(data_file, state)
	end
end

function M.load_state()
	local data_file = fs.get_file_path(".zortex/xp_state.json")
	if data_file then
		local loaded = fs.read_json(data_file)
		if loaded then
			state = loaded
			return true
		end
	end
	return false
end

-- =============================================================================
-- Query Functions
-- =============================================================================

-- Get all area stats
function M.get_area_stats()
	local stats = {}

	for path, data in pairs(state.area_xp) do
		local level, progress, xp_needed = M.get_area_progress(data.xp)
		stats[path] = {
			xp = data.xp,
			level = level,
			progress = progress,
			xp_to_next = xp_needed,
		}
	end

	return stats
end

-- Get project stats
function M.get_project_stats()
	local stats = {}

	for name, data in pairs(state.project_xp) do
		stats[name] = {
			xp = data.xp,
			completed_tasks = data.completed_tasks,
			total_tasks = data.task_count,
			completion_rate = data.task_count > 0 and (data.completed_tasks / data.task_count) or 0,
		}
	end

	return stats
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup(opts)
	xp_config.setup(opts)
	M.load_state()
end

return M
