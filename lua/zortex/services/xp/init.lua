-- services/xp/init.lua - Project-centric XP orchestration
local M = {}

local Events = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local xp_calculator = require("zortex.services.xp.calculator")
local xp_store = require("zortex.stores.xp")
local xp_distributor = require("zortex.services.xp.distributor")
local xp_season = require("zortex.services.xp.season")
local Config = require("zortex.config")

-- =============================================================================
-- Project XP Calculation
-- =============================================================================

-- Recalculate and update XP for a project
function M.recalculate_project_xp(project)
	if not project or not project.name then
		Logger.warn("xp", "Invalid project data for XP calculation")
		return nil
	end

	local timer = Logger.start_timer("xp.recalculate_project")

	-- Get all tasks for the project
	local tasks = {}
	if project.section then
		local workspace = require("zortex.core.workspace")
		local doc = workspace.projects()
		if doc then
			local lines = project.section:get_lines(doc.bufnr)
			local parser = require("zortex.utils.parser")

			for _, line in ipairs(lines) do
				local task = parser.parse_task(line)
				if task then
					table.insert(tasks, task)
				end
			end
		end
	end

	-- Add tasks to project data
	project.tasks = tasks

	-- Calculate project XP
	local xp_result = xp_calculator.calculate_project_xp(project)

	-- Get previous XP to calculate delta
	local previous = xp_store.get_project_details(project.name) or { earned_xp = 0 }
	local xp_delta = xp_result.earned_xp - previous.earned_xp

	-- Update project XP in store
	xp_store.set_project_xp(
		project.name,
		xp_result.earned_xp,
		xp_calculator.calculate_season_level(xp_result.earned_xp)
	)

	-- Update project details
	xp_store.update_project_details(project.name, {
		total_xp = xp_result.total_xp,
		earned_xp = xp_result.earned_xp,
		task_count = #tasks,
		completion_percentage = xp_result.completion_percentage,
	})

	-- Distribute XP to season and areas if there's a positive delta
	if xp_delta > 0 then
		M._distribute_project_xp(project, xp_delta)

		-- Track source
		xp_store.add_xp_from_source("projects", xp_delta)
	end

	-- Check if project is completed
	if xp_result.completion_percentage >= 1.0 and not xp_store.is_project_completed(project.name) then
		xp_store.mark_project_completed(project.name, xp_result.earned_xp)

		Events.emit("project:completed", {
			project = project,
			xp_awarded = xp_result.earned_xp,
		})
	end

	timer()

	Logger.info("xp", "Recalculated project XP", {
		project = project.name,
		earned = xp_result.earned_xp,
		total = xp_result.total_xp,
		delta = xp_delta,
	})

	return xp_result
end

-- Distribute project XP to season and areas
function M._distribute_project_xp(project, xp_amount)
	-- Add to season
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		local new_xp = season_data.season_xp + xp_amount
		xp_store.set_season_data(new_xp, xp_calculator.calculate_season_level(new_xp))
	end

	-- Extract area links from project
	local area_links = M._extract_project_area_links(project)

	if #area_links > 0 then
		local area_xp = xp_calculator.calculate_area_transfer(xp_amount, #area_links)
		local area_service = require("zortex.services.areas")

		for _, area_link in ipairs(area_links) do
			area_service.add_area_xp(area_link, area_xp)
		end

		Logger.debug("xp", "Distributed to areas", {
			areas = area_links,
			xp_per_area = area_xp,
		})
	end
end

-- =============================================================================
-- Standalone Task XP
-- =============================================================================

-- Award XP for standalone task (not in a project)
function M.award_standalone_task_xp(task, context)
	if not task or task.completed == false then
		return nil
	end

	local xp_amount = xp_calculator.calculate_standalone_task_xp(task)

	-- Add to season
	local season_data = xp_store.get_season_data()
	if season_data.current_season then
		local new_xp = season_data.season_xp + xp_amount
		xp_store.set_season_data(new_xp, xp_calculator.calculate_season_level(new_xp))
	end

	-- Extract area links from task attributes
	local area_links = M._extract_task_area_links(task)

	if #area_links > 0 then
		local area_service = require("zortex.services.areas")
		local area_xp = math.floor(xp_amount * 0.5) -- 50% to areas for standalone
		local xp_per_area = math.floor(area_xp / #area_links)

		for _, area_link in ipairs(area_links) do
			area_service.add_area_xp(area_link, xp_per_area)
		end
	end

	-- Track source
	xp_store.add_xp_from_source("standalone_tasks", xp_amount)

	Events.emit("xp:awarded", {
		source = "standalone_task",
		task = task,
		amount = xp_amount,
	})

	Logger.info("xp", "Awarded standalone task XP", {
		task_id = task.attributes and task.attributes.id,
		xp = xp_amount,
	})

	return xp_amount
end

-- Remove XP for uncompleted standalone task
function M.remove_standalone_task_xp(task)
	-- For now, we don't remove XP from standalone tasks
	-- since we recalculate project XP holistically
	Logger.debug("xp", "Standalone task uncompleted", {
		task_id = task.attributes and task.attributes.id,
	})
end

-- =============================================================================
-- Area Link Extraction
-- =============================================================================

-- Extract area links from project
function M._extract_project_area_links(project)
	local area_links = {}

	-- Check project attributes
	if project.attributes then
		local areas = project.attributes.area or project.attributes.a
		if areas then
			-- area attribute is already parsed as a list of area link objects
			for _, area_obj in ipairs(areas) do
				-- Convert to proper area path format
				local area_path = area_obj.raw:gsub("^#", ""):gsub(":", "/")
				table.insert(area_links, area_path)
			end
		end
	end

	return area_links
end

-- Extract area links from task
function M._extract_task_area_links(task)
	local area_links = {}

	-- Check task attributes
	if task.attributes then
		local areas = task.attributes.area or task.attributes.a
		if areas then
			for _, area_obj in ipairs(areas) do
				-- Convert to proper area path format
				local area_path = area_obj.raw:gsub("^#", ""):gsub(":", "/")
				table.insert(area_links, area_path)
			end
		end
	end

	return area_links
end

-- =============================================================================
-- Task Event Handlers
-- =============================================================================

-- Handle task changes
function M.handle_task_change(xp_context)
	local xp_result = nil

	-- Check if task is part of a project
	if xp_context.project then
		xp_result = M.recalculate_project_xp(xp_context.project)
	elseif xp_context.task then
		-- Standalone task
		if xp_context.task.completed then
			xp_result = M.award_standalone_task_xp(xp_context.task, xp_context.context)
		else
			xp_result = M.remove_standalone_task_xp(xp_context.task)
		end
	end

	Events.emit("xp:changed", xp_result)
end

-- =============================================================================
-- Statistics and Status
-- =============================================================================

-- Get XP statistics
function M.get_stats()
	local stats = xp_store.get_xp_statistics()
	local season_status = M.get_season_status()
	local area_service = require("zortex.services.areas")

	return {
		season = season_status,
		areas = area_service.get_area_stats(),
		projects = xp_store.get_all_project_xp(),
		sources = stats.sources,
		source_percentages = stats.source_percentages,
		totals = {
			total_xp = stats.total_xp,
			active_projects = stats.active_projects,
			completed_projects = stats.completed_projects,
			total_areas = stats.total_areas,
			avg_area_level = stats.avg_area_level,
		},
	}
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

-- =============================================================================
-- Initialization
-- =============================================================================

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

	-- Listen for task events
	Events.on("task:completed", function(data)
		M.handle_task_change(data.xp_context)
		M.check_level_ups()
	end, {
		priority = 70,
		name = "xp_service.task_complete",
	})

	Events.on("task:uncompleted", function(data)
		M.handle_task_change(data.xp_context)
	end, {
		priority = 70,
		name = "xp_service.task_uncomplete",
	})

	Events.on("task:created", function(data)
		if data.xp_context then
			M.handle_task_change(data.xp_context)
		end
	end, {
		priority = 70,
		name = "xp_service.task_created",
	})

	Events.on("task:modified", function(data)
		if data.xp_context then
			M.handle_task_change(data.xp_context)
		end
	end, {
		priority = 70,
		name = "xp_service.task_modified",
	})

	Events.on("task:deleted", function(data)
		if data.xp_context then
			M.handle_task_change(data.xp_context)
		end
	end, {
		priority = 70,
		name = "xp_service.task_deleted",
	})

	-- Listen for project changes to recalculate
	Events.on("project:changed", function(data)
		if data.project then
			M.recalculate_project_xp(data.project)
		end
	end, {
		priority = 60,
		name = "xp_service.project_changed",
	})
end

return M
