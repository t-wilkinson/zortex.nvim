-- services/xp/init.lua - XP system

local M = {}

function M.calculate_xp_distribution(xp_context)
	local distribution = {
		areas = {},
	}

	-- if only task (no project), find the task in the store
	-- Find how much xp it has contributed to area and season.
	-- Calculate its new delta and modify
	if not xp_context.project then
		if xp_context.task_areas then
			for area_link in xp_context.task_areas do
				distribution.areas[area_link] = 0
			end
		end

	-- if a project, find how much xp it currently contributes to area and season
	-- calculate its delta
	else
	end
end

-- Build XP context
function M.build_xp_context(data)
	local projects_service = require("zortex.services.projects")
	local okr_service = require("zortex.services.okr")
	local section = projects_service.find_project(data.doc_context.section)
	local project = projects_service.get_project(section, data.doc_context.doc)

	return {
		doc_context = data.doc_context,
		task = data.task,
		task_areas = M.get_area_links(data.task.attributes),

		-- Project a task falls under
		project = project,
		project_areas = project and M.get_area_links(project.attributes),

		-- OKR Key result that links to a project
		key_result = project and okr_service.get_key_result(project.link),
	}
end

function M.setup() end

return M
