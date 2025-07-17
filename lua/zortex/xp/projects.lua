-- xp/projects.lua - Project and Season XP management
local M = {}

local xp_core = require("zortex.xp.core")
local xp_areas = require("zortex.xp.areas")
local xp_store = require("zortex.stores.xp")

-- =============================================================================
-- Task Completion XP
-- =============================================================================

-- Award XP for completing a task
function M.complete_task(project_name, task_position, total_tasks, area_links)
	-- Calculate task XP
	local task_xp = xp_core.calculate_task_xp(task_position, total_tasks)

	-- Add to project XP
	xp_store.add_project_xp(project_name, task_xp)

	-- Add to season XP
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		local new_season_xp = season_data.season_xp + task_xp
		local new_season_level = xp_core.calculate_season_level(new_season_xp)
		xp_store.set_season_data(new_season_xp, new_season_level)
	end

	-- Transfer XP to linked areas
	if area_links and #area_links > 0 then
		local area_xp = xp_core.calculate_area_transfer(task_xp, #area_links)

		for _, area_link in ipairs(area_links) do
			local area_path = xp_areas.parse_area_path(area_link)
			if area_path then
				xp_areas.add_xp(area_path, area_xp, nil)
			end
		end
	end

	return task_xp
end

-- Remove XP for uncompleting a task
function M.uncomplete_task(project_name, xp_to_remove, area_links)
	if xp_to_remove <= 0 then
		return 0
	end

	-- Remove from project XP
	local project_data = xp_store.get_project_xp(project_name)
	local new_xp = math.max(0, project_data.xp - xp_to_remove)
	xp_store.set_project_xp(project_name, new_xp, xp_core.calculate_season_level(new_xp))

	-- Remove from season XP
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		local new_season_xp = math.max(0, season_data.season_xp - xp_to_remove)
		local new_season_level = xp_core.calculate_season_level(new_season_xp)
		xp_store.set_season_data(new_season_xp, new_season_level)
	end

	-- Remove from linked areas
	if area_links and #area_links > 0 then
		local area_xp = xp_core.calculate_area_transfer(xp_to_remove, #area_links)

		for _, area_link in ipairs(area_links) do
			local area_path = xp_areas.parse_area_path(area_link)
			if area_path then
				xp_areas.remove_xp(area_path, area_xp)
			end
		end
	end

	return -xp_to_remove
end

-- =============================================================================
-- Project Completion
-- =============================================================================

-- Mark a project as completed and handle final XP transfers
function M.complete_project(project_name, total_project_xp, area_links)
	-- Mark in store
	xp_store.mark_project_completed(project_name, total_project_xp)

	-- No additional XP transfers - they already happened per task
	-- This is just for tracking/achievements

	return total_project_xp
end

-- =============================================================================
-- Season Management
-- =============================================================================

-- Start a new season
function M.start_season(name, end_date)
	xp_store.start_season(name, end_date)

	vim.notify(string.format("🏆 Season '%s' started! Ends: %s", name, end_date), vim.log.levels.INFO)
end

-- End current season
function M.end_season()
	local season_record = xp_store.end_season()

	if season_record then
		local tier_info = xp_core.get_season_tier(season_record.final_level)
		local tier_name = tier_info.current and tier_info.current.name or "None"

		vim.notify(
			string.format(
				"🎊 Season '%s' ended!\nFinal Level: %d (%s tier)\nProjects: %d",
				season_record.name,
				season_record.final_level,
				tier_name,
				vim.tbl_count(season_record.projects)
			),
			vim.log.levels.INFO
		)

		return season_record
	else
		vim.notify("No active season to end", vim.log.levels.WARN)
		return nil
	end
end

-- Get current season status
function M.get_season_status()
	local season_data = xp_store.get_season_data()

	if not season_data.current_season then
		return nil
	end

	local tier_info = xp_core.get_season_tier(season_data.season_level)
	local progress =
		xp_core.get_level_progress(season_data.season_xp, season_data.season_level, xp_core.calculate_season_level_xp)

	return {
		season = season_data.current_season,
		level = season_data.season_level,
		xp = season_data.season_xp,
		current_tier = tier_info.current,
		next_tier = tier_info.next,
		is_max_tier = tier_info.is_max_tier,
		progress_to_next = progress.progress,
		xp_to_next = progress.xp_to_next,
	}
end

-- =============================================================================
-- Project Statistics
-- =============================================================================

-- Get stats for a specific project
function M.get_project_stats(project_name)
	local project_data = xp_store.get_project_xp(project_name)

	return {
		name = project_name,
		xp = project_data.xp,
		level = project_data.level,
		is_completed = xp_store.is_project_completed(project_name),
	}
end

-- Get all project stats
function M.get_all_project_stats()
	local all_projects = xp_store.get_all_project_xp()
	local stats = {}

	for name, data in pairs(all_projects) do
		stats[name] = {
			xp = data.xp,
			level = data.level,
			is_completed = xp_store.is_project_completed(name),
		}
	end

	return stats
end

return M

