-- services/xp/init.lua - Service for XP orchestration and calculation
local M = {}

local EventBus = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local xp_calculator = require("zortex.services.xp.calculator")
local xp_store = require("zortex.stores.xp")
local xp_distributor = require("zortex.services.xp.distributor")

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
	M.check_level_ups()

	return distribution
end

-- Reverse XP for task uncomplete
local function reverse_task_xp(task_id, xp_context)
	local task = require("zortex.stores.tasks").get_task(task_id)
	if not task or not task.xp_awarded or task.xp_awarded <= 0 then
		return nil
	end

	local xp_to_remove = task.xp_awarded

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
		local area_service = require("zortex.services.area")
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

	EventBus.emit("xp:reversed", {
		source = "task",
		task_id = task_id,
		amount = xp_to_remove,
	})

	return xp_to_remove
end

-- Get XP statistics
function M.get_stats()
	local season_status = M.get_season_status()
	local area_stats = require("zortex.services.area").get_area_stats()
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
	EventBus.on("task:completed", function(data)
		local xp_amount = xp_calculator.calculate_task_xp(data.xp_context)
		award_task_xp(data.task.attributes.id, xp_amount, data.xp_context)
	end, {
		priority = 70,
		name = "xp_service.complete_handler",
	})

	-- Listen for task uncomplete
	EventBus.on("task:uncompleted", function(data)
		reverse_task_xp(data.task.attributes.id, data.xp_context)
	end, {
		priority = 70,
		name = "xp_service.uncomplete_handler",
	})

	Logger.info("xp_service", "XP Service initialized")
end

-- Private helpers
function M.check_level_ups()
	-- Check for season level up
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		local old_level = season_data.season_level
		local new_level = xp_calculator.calculate_season_level(season_data.season_xp)

		if new_level > old_level then
			EventBus.emit("season:leveled_up", {
				old_level = old_level,
				new_level = new_level,
				tier_info = xp_calculator.get_season_tier(new_level),
			})
		end
	end
end

return M
