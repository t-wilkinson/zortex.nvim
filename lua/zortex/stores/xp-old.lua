-- stores/xp.lua - XP state persistence with source tracking
local M = {}

local BaseStore = require("zortex.stores.base")
local constants = require("zortex.constants")

-- Create the singleton store
local store = BaseStore:new(constants.FILES.XP_STATE_DATA)

-- Override init_empty to set default XP structure
function store:init_empty()
	self.data = {
		area_xp = {}, -- area_path -> { xp, level }
		project_xp = {}, -- project_name -> { xp, level, last_calculated }
		season_xp = 0,
		task_xp = {},
		season_level = 1,
		current_season = nil,

		-- XP source tracking
		xp_sources = {
			projects = 0, -- XP from project completions
			standalone_tasks = 0, -- XP from tasks not in projects
			objectives = 0, -- XP from objective completions
			daily_reviews = 0, -- XP from daily reviews
			bonuses = 0, -- XP from various bonuses
		},

		-- Detailed project XP tracking
		project_details = {}, -- project_name -> { total_xp, earned_xp, task_count, last_updated }

		-- Historical data
		completed_objectives = {}, -- Track completed objectives
		completed_projects = {}, -- Track completed projects
		season_history = {}, -- Past seasons
	}
	self.loaded = true
end

-- =============================================================================
-- Area XP Methods
-- =============================================================================

function M.get_area_xp(path)
	store:ensure_loaded()
	return store.data.area_xp[path] or { xp = 0, level = 1 }
end

function M.set_area_xp(path, xp, level)
	store:ensure_loaded()
	store.data.area_xp[path] = { xp = xp, level = level }
	store:save()
end

function M.get_all_area_xp()
	store:ensure_loaded()
	return store.data.area_xp
end

-- =============================================================================
-- Task XP Methods
-- =============================================================================

-- Task XP tracking (by task ID)
function M.get_task_xp(task_id)
	store:ensure_loaded()
	if not store.data.task_xp then
		store.data.task_xp = {}
	end
	return store.data.task_xp[task_id]
end

function M.set_task_xp(task_id, xp)
	store:ensure_loaded()
	if not store.data.task_xp then
		store.data.task_xp = {}
	end
	store.data.task_xp[task_id] = xp
	store:save()
end

function M.remove_task_xp(task_id)
	store:ensure_loaded()
	if store.data.task_xp then
		store.data.task_xp[task_id] = nil
		store:save()
	end
end

-- Recalculate season XP from all sources
function M.recalculate_season_xp()
	store:ensure_loaded()
	local total_xp = 0

	-- Sum project XP
	for _, project_data in pairs(store.data.project_xp or {}) do
		total_xp = total_xp + (project_data.xp or 0)
	end

	-- Sum standalone task XP
	for _, task_xp in pairs(store.data.task_xp or {}) do
		total_xp = total_xp + (task_xp or 0)
	end

	-- Update season XP
	store.data.season_xp = total_xp
	store:save()

	return total_xp
end
-- =============================================================================
-- Project XP Methods (Enhanced)
-- =============================================================================

function M.get_project_xp(name)
	store:ensure_loaded()
	return store.data.project_xp[name] or { xp = 0, level = 1, last_calculated = 0 }
end

function M.set_project_xp(name, xp, level)
	store:ensure_loaded()
	store.data.project_xp[name] = {
		xp = xp,
		level = level,
		last_calculated = os.time(),
	}
	store:save()
end

-- Update project details for tracking
function M.update_project_details(name, details)
	store:ensure_loaded()
	store.data.project_details[name] = {
		total_xp = details.total_xp,
		earned_xp = details.earned_xp,
		task_count = details.task_count,
		completion_percentage = details.completion_percentage,
		last_updated = os.time(),
	}
	store:save()
end

function M.get_project_details(name)
	store:ensure_loaded()
	return store.data.project_details[name]
end

function M.get_all_project_xp()
	store:ensure_loaded()
	return store.data.project_xp
end

-- =============================================================================
-- XP Source Tracking
-- =============================================================================

function M.add_xp_from_source(source, amount)
	store:ensure_loaded()
	if store.data.xp_sources[source] then
		store.data.xp_sources[source] = store.data.xp_sources[source] + amount
		store:save()
	end
end

function M.get_xp_sources()
	store:ensure_loaded()
	return store.data.xp_sources
end

function M.reset_xp_sources()
	store:ensure_loaded()
	for key in pairs(store.data.xp_sources) do
		store.data.xp_sources[key] = 0
	end
	store:save()
end

-- =============================================================================
-- Objective Tracking
-- =============================================================================

function M.mark_objective_completed(objective_id, xp_awarded)
	store:ensure_loaded()
	store.data.completed_objectives[objective_id] = {
		completed_at = os.time(),
		xp_awarded = xp_awarded,
	}
	-- Track XP source
	M.add_xp_from_source("objectives", xp_awarded)
	store:save()
end

function M.is_objective_completed(objective_id)
	store:ensure_loaded()
	return store.data.completed_objectives[objective_id] ~= nil
end

-- =============================================================================
-- Project Tracking
-- =============================================================================

function M.mark_project_completed(project_name, xp_awarded)
	store:ensure_loaded()
	store.data.completed_projects[project_name] = {
		completed_at = os.time(),
		xp_awarded = xp_awarded,
		details = store.data.project_details[project_name], -- Store snapshot
	}
	-- Track XP source
	M.add_xp_from_source("projects", xp_awarded)
	store:save()
end

function M.is_project_completed(project_name)
	store:ensure_loaded()
	return store.data.completed_projects[project_name] ~= nil
end

-- =============================================================================
-- Utility Methods
-- =============================================================================

-- Force reload from disk
function M.reload()
	store.loaded = false
	store:load()
end

-- Force save
function M.save()
	return store:save()
end

function M.setup()
	store:load()
end

return M
