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
-- Season Methods
-- =============================================================================

function M.get_season_data()
	store:ensure_loaded()
	return {
		current_season = store.data.current_season,
		season_xp = store.data.season_xp,
		season_level = store.data.season_level,
		xp_sources = store.data.xp_sources, -- Include source breakdown
	}
end

function M.set_season_data(season_xp, season_level)
	store:ensure_loaded()
	store.data.season_xp = season_xp
	store.data.season_level = season_level
	store:save()
end

function M.start_season(name, end_date)
	store:ensure_loaded()
	store.data.current_season = {
		name = name,
		start_date = os.date("%Y-%m-%d"),
		end_date = end_date,
		start_time = os.time(),
	}
	store.data.season_xp = 0
	store.data.season_level = 1
	store.data.project_xp = {} -- Reset project XP for new season
	store.data.project_details = {} -- Reset project details
	M.reset_xp_sources() -- Reset source tracking
	store:save()
end

function M.end_season()
	store:ensure_loaded()
	if store.data.current_season then
		-- Archive season with source breakdown
		local season_record = {
			name = store.data.current_season.name,
			start_date = store.data.current_season.start_date,
			end_date = os.date("%Y-%m-%d"),
			final_level = store.data.season_level,
			final_xp = store.data.season_xp,
			projects = vim.deepcopy(store.data.project_xp),
			project_details = vim.deepcopy(store.data.project_details),
			xp_sources = vim.deepcopy(store.data.xp_sources),
		}
		table.insert(store.data.season_history, season_record)

		-- Reset season data
		store.data.current_season = nil
		store.data.season_xp = 0
		store.data.season_level = 1
		store.data.project_xp = {}
		store.data.project_details = {}
		M.reset_xp_sources()
		store:save()

		return season_record
	end
	return nil
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
-- Statistics
-- =============================================================================

function M.get_xp_statistics()
	store:ensure_loaded()

	local total_xp = 0
	for _, amount in pairs(store.data.xp_sources) do
		total_xp = total_xp + amount
	end

	local stats = {
		total_xp = total_xp,
		sources = store.data.xp_sources,
		source_percentages = {},
		active_projects = 0,
		completed_projects = 0,
		total_areas = 0,
		avg_area_level = 0,
	}

	-- Calculate percentages
	if total_xp > 0 then
		for source, amount in pairs(store.data.xp_sources) do
			stats.source_percentages[source] = (amount / total_xp) * 100
		end
	end

	-- Count projects
	for name, details in pairs(store.data.project_details) do
		if store.data.completed_projects[name] then
			stats.completed_projects = stats.completed_projects + 1
		else
			stats.active_projects = stats.active_projects + 1
		end
	end

	-- Area statistics
	local total_area_level = 0
	for _, data in pairs(store.data.area_xp) do
		stats.total_areas = stats.total_areas + 1
		total_area_level = total_area_level + data.level
	end

	if stats.total_areas > 0 then
		stats.avg_area_level = total_area_level / stats.total_areas
	end

	return stats
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
