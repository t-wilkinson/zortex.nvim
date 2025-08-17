-- services/xp/init.lua - Simplified XP orchestration

local M = {}

local Events = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")
local xp_calculator = require("zortex.services.xp.calculator")
local xp_store = require("zortex.stores.xp")
local Config = require("zortex.config")

function M.update_xp(context)
	local end_timer = Logger.start_timer("xp.award")
	local xp_amount = xp_calculator.calculate_xp(context)

	local distributions = xp_calculator.calculate_distributions(xp_amount, context.areas)

	local transaction = xp_calculator.build_xp_transaction(context.type, context.id, xp_amount, distributions)

	local xp_change = xp_store.record_xp_transaction(transaction)

	if xp_change > 0 then
		Events.emit("xp:awarded", {
			source = context.type,
			source_id = context.id,
			total = xp_change,
			transaction = transaction,
		})
	else
		Events.emit("xp:removed", {
			source = context.type,
			source_id = context.id,
			total = xp_change,
			transaction = transaction,
		})
	end

	end_timer()
end

-- Initialize with event handlers
function M.init()
	xp_calculator.setup(Config.xp)

	-- Task events
	Events.on("task:completed", function(data)
		M.update_xp(M.build_xp_context(data))
	end)

	Events.on("task:uncompleted", function(data)
		M.update_xp(M.build_xp_context(data))
	end)
end

-- Build XP context
-- This is a key function that provides the bulk of the necessary context for efficiently calculating xp
function M.build_xp_context(data)
	local projects_service = require("zortex.services.projects")
	local okr_service = require("zortex.services.okr")
	local areas_service = require("zortex.services.areas")

	local section = projects_service.find_project(data.doc_context.section)
	local project = projects_service.get_project(section, data.doc_context.doc)

	local id, type
	-- Extract area paths from all sources
	local key_results, objectives = {}, {}

	if project then
		type = "project"
		id = project.link
		key_results, objectives = okr_service.get_key_results(project.link)
	elseif data.task then
		type = "task"
		id = data.task.id
	else
		return nil
	end

	-- Linked key_result just increases amount of xp given to area
	local area_paths = areas_service.extract_area_paths(data.task, project, table.unpack(objectives))
	local areas = {}
	for _, area_path in ipairs(area_paths) do
		if project then
			for _, key_result in ipairs(key_results) do
				if key_result.linked_projects[project.link] then
					areas[area_path] = {
						type = "key_result",
						key_result = key_result,
					}
				end
			end
		end
		if not areas[area_path] then
			areas[area_path] = {
				type = "basic",
			}
		end
	end

	return {
		id = id,
		type = type,
		areas = areas,

		doc_context = data.doc_context,
		task = data.task,

		-- Project a task falls under
		project = project,

		-- OKR Key result that links to a project
		key_results = key_results,
		objectives = objectives,
	}
end

return M
