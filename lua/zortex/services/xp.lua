-- services/xp_service.lua - Service for XP orchestration and calculation
local M = {}

local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local xp_core = require("zortex.xp.core")
local xp_store = require("zortex.stores.xp")
local xp_distributor = require("zortex.domain.xp_distributor")

-- Calculate XP for a task completion
function M.calculate_task_xp(xp_context)
	return xp_core.calculate_task_xp(xp_context.task_position, xp_context.total_tasks)
end

-- Calculate XP for an objective completion
function M.calculate_objective_xp(time_horizon, created_date)
	return xp_core.calculate_objective_xp(time_horizon, created_date)
end

-- Award XP for task completion
function M.award_task_xp(task_id, xp_amount, xp_context)
	if xp_amount <= 0 then
		return nil
	end

	-- Create distribution
	local distribution = xp_distributor.distribute("task", task_id, xp_amount, {
		project_name = xp_context.project_name,
		area_links = xp_context.area_links,
	})

	-- Update task with XP awarded
	require("zortex.stores.tasks").update_task(task_id, {
		xp_awarded = xp_amount,
	})

	-- Emit XP awarded event
	EventBus.emit("xp:awarded", {
		source = "task",
		task_id = task_id,
		amount = xp_amount,
		distribution = distribution,
	})

	-- Check for level ups
	M._check_level_ups(distribution)

	return distribution
end

-- Reverse XP for task uncomplete
function M.reverse_task_xp(task_id, xp_context)
	local task = require("zortex.stores.tasks").get_task(task_id)
	if not task or not task.xp_awarded or task.xp_awarded <= 0 then
		return nil
	end

	local xp_to_remove = task.xp_awarded

	-- Remove from project
	if xp_context.project_name then
		local project_data = xp_store.get_project_xp(xp_context.project_name)
		local new_xp = math.max(0, project_data.xp - xp_to_remove)
		xp_store.set_project_xp(xp_context.project_name, new_xp, xp_core.calculate_season_level(new_xp))
	end

	-- Remove from season
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		local new_season_xp = math.max(0, season_data.season_xp - xp_to_remove)
		local new_season_level = xp_core.calculate_season_level(new_season_xp)
		xp_store.set_season_data(new_season_xp, new_season_level)
	end

	-- Remove from areas
	if xp_context.area_links and #xp_context.area_links > 0 then
		local area_service = require("zortex.services.area_service")
		local area_xp = xp_core.calculate_area_transfer(xp_to_remove, #xp_context.area_links)

		for _, area_link in ipairs(xp_context.area_links) do
			local area_path = area_service.parse_area_path(area_link)
			if area_path then
				local area_data = xp_store.get_area_xp(area_path)
				local new_xp = math.max(0, area_data.xp - area_xp)
				xp_store.set_area_xp(area_path, new_xp, xp_core.calculate_area_level(new_xp))
			end
		end
	end

	EventBus.emit("xp:reversed", {
		source = "task",
		task_id = task_id,
		amount = xp_to_remove,
	})

	return xp_to_remove
end

-- Season management
function M.start_season(name, end_date)
	xp_store.start_season(name, end_date)

	EventBus.emit("season:started", {
		name = name,
		end_date = end_date,
	})
end

function M.end_season()
	local season_record = xp_store.end_season()

	if season_record then
		EventBus.emit("season:ended", {
			season = season_record,
		})
	end

	return season_record
end

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
		progress = progress,
	}
end

-- Get XP statistics
function M.get_stats()
	local season_status = M.get_season_status()
	local area_stats = require("zortex.services.area_service").get_area_stats()
	local project_stats = {}

	-- Get project stats
	local all_project_xp = xp_store.get_all_project_xp()
	for name, data in pairs(all_project_xp) do
		project_stats[name] = {
			xp = data.xp,
			level = data.level,
		}
	end

	return {
		season = season_status,
		areas = area_stats,
		projects = project_stats,
	}
end

-- Initialize service
function M.init()
	-- Listen for task completion events
	EventBus.on("task:completing", function(data)
		local xp_amount = M.calculate_task_xp(data.xp_context)
		M.award_task_xp(data.task.attributes.id, xp_amount, data.xp_context)
	end, {
		priority = 70,
		name = "xp_service.task_handler",
	})

	-- Listen for task uncomplete
	EventBus.on("task:uncompleted", function(data)
		M.reverse_task_xp(data.task.attributes.id, data.xp_context)
	end, {
		priority = 70,
		name = "xp_service.uncomplete_handler",
	})

	Logger.info("xp_service", "XP Service initialized")
end

-- Private helpers
function M._check_level_ups(distribution)
	-- Check for season level up
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		local old_level = season_data.season_level
		local new_level = xp_core.calculate_season_level(season_data.season_xp)

		if new_level > old_level then
			EventBus.emit("season:leveled_up", {
				old_level = old_level,
				new_level = new_level,
				tier_info = xp_core.get_season_tier(new_level),
			})
		end
	end
end

return M

