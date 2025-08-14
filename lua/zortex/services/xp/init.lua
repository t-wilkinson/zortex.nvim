-- services/xp/init.lua - Service for XP orchestration and calculation
local M = {}

local Events = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local xp_calculator = require("zortex.services.xp.calculator")
local xp_store = require("zortex.stores.xp")
local xp_distributor = require("zortex.services.xp.distributor")
local xp_season = require("zortex.services.xp.season")
local task_service = require("zortex.services.tasks")
local Config = require("zortex.config")

-- Award XP for task completion
local function award_task_xp(task_id, xp_amount, xp_context)
	if xp_amount <= 0 then
		return nil
	end

	-- Create distribution
	local distribution = xp_distributor.distribute("task", task_id, xp_amount, {
		project_name = xp_context.project_name,
		area_links = xp_context.area_links,
	})

	-- After creating distribution, apply the XP
	for _, dist in ipairs(distribution.distributions) do
		if dist.type == "project" then
			local project_data = xp_store.get_project_xp(dist.name)
			local new_xp = project_data.xp + dist.amount
			xp_store.set_project_xp(dist.name, new_xp, xp_calculator.calculate_season_level(new_xp))
		elseif dist.type == "season" then
			local season_data = xp_store.get_season_data()
			local new_xp = season_data.season_xp + dist.amount
			xp_store.set_season_data(new_xp, xp_calculator.calculate_season_level(new_xp))
		elseif dist.type == "area" then
			require("zortex.services.areas").add_area_xp(dist.name, dist.amount)
		end
	end

	-- Update task with XP awarded using the task service
	local success = task_service.update_task_xp(task_id, xp_amount)
	if not success then
		Logger.warn("xp", "Failed to update task XP", { task_id = task_id, xp = xp_amount })
	end

	-- Emit XP awarded event
	Events.emit("xp:awarded", {
		source = "task",
		task_id = task_id,
		amount = xp_amount,
		distribution = distribution,
	})

	-- Check for level ups
	M.check_level_ups()

	return distribution
end

-- Reverse XP for task uncomplete
local function reverse_task_xp(task_id, xp_context)
	-- Get task using the task service
	local task = task_service.find_task_by_id(task_id)
	if not task or not task.attributes or not task.attributes.xp_awarded then
		return nil
	end

	local xp_to_remove = tonumber(task.attributes.xp_awarded) or 0
	if xp_to_remove <= 0 then
		return nil
	end

	-- Remove from project
	if xp_context.project_name then
		local project_data = xp_store.get_project_xp(xp_context.project_name)
		local new_xp = math.max(0, project_data.xp - xp_to_remove)
		xp_store.set_project_xp(xp_context.project_name, new_xp, xp_calculator.calculate_season_level(new_xp))
	end

	-- Remove from season
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		local new_season_xp = math.max(0, season_data.season_xp - xp_to_remove)
		local new_season_level = xp_calculator.calculate_season_level(new_season_xp)
		xp_store.set_season_data(new_season_xp, new_season_level)
	end

	-- Remove from areas
	if xp_context.area_links and #xp_context.area_links > 0 then
		local area_service = require("zortex.services.areas")
		local area_xp = xp_calculator.calculate_area_transfer(xp_to_remove, #xp_context.area_links)

		for _, area_link in ipairs(xp_context.area_links) do
			local area_path = area_service.parse_area_path(area_link)
			if area_path then
				local area_data = xp_store.get_area_xp(area_path)
				local new_xp = math.max(0, area_data.xp - area_xp)
				xp_store.set_area_xp(area_path, new_xp, xp_calculator.calculate_area_level(new_xp))
			end
		end
	end

	-- Update task - remove XP awarded
	local success = task_service.update_task_xp(task_id, 0)
	if not success then
		Logger.warn("xp", "Failed to remove task XP", { task_id = task_id })
	end

	Events.emit("xp:reversed", {
		source = "task",
		task_id = task_id,
		amount = xp_to_remove,
	})

	return xp_to_remove
end

-- Check for level ups
function M.check_level_ups()
	-- Check for season level up
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		local old_level = season_data.season_level
		local new_level = xp_calculator.calculate_season_level(season_data.season_xp)

		if new_level > old_level then
			xp_store.set_season_data(season_data.season_xp, new_level)
			Events.emit("season:leveled_up", {
				old_level = old_level,
				new_level = new_level,
				tier_info = xp_calculator.get_season_tier(new_level),
			})
		end
	end
end

-- Get XP statistics
function M.get_stats()
	local season_status = M.get_season_status()
	local area_stats = require("zortex.services.areas").get_area_stats()
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

-- Export season functions
M.start_season = xp_season.start_season
M.end_season = xp_season.end_season
M.get_season_status = xp_season.get_season_status

-- Initialize service
function M.init()
	-- Initialize calculator with config
	xp_calculator.setup(Config.xp)

	-- Initialize distributor with config
	xp_distributor.setup(Config.xp.distribution_rules)

	-- Listen for task completion events
	Events.on("task:completed", function(data)
		if not data.xp_context then
			Logger.warn("xp_service", "Task completed without XP context", { task_id = data.task_id })
			return
		end

		local xp_amount = xp_calculator.calculate_task_xp(data.xp_context.task_position, data.xp_context.total_tasks)
		local distribution = award_task_xp(data.task_id, xp_amount, data.xp_context)
		Logger.info("xp", "Awarded XP for task completion", {
			task_id = data.task_id,
			xp_amount = xp_amount,
			distribution = distribution,
		})
	end, {
		priority = 70,
		name = "xp_service.complete_handler",
	})

	-- Listen for task uncomplete
	Events.on("task:uncompleted", function(data)
		if not data.xp_context then
			Logger.warn("xp_service", "Task uncompleted without XP context", { task_id = data.task_id })
			return
		end
		reverse_task_xp(data.task_id, data.xp_context)
	end, {
		priority = 70,
		name = "xp_service.uncomplete_handler",
	})
end

return M
