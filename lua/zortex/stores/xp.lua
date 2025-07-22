-- stores/xp.lua - XP state persistence
local M = {}

local BaseStore = require("zortex.stores.base")
local constants = require("zortex.constants")

-- Create the singleton store
local store = BaseStore:new(constants.FILES.XP_STATE_DATA)

-- Override init_empty to set default XP structure
function store:init_empty()
	self.data = {
		area_xp = {}, -- area_path -> { xp, level }
		project_xp = {}, -- project_name -> { xp, level }
		season_xp = 0,
		season_level = 1,
		current_season = nil,

		-- Historical data
		completed_objectives = {}, -- Track completed objectives
		completed_projects = {}, -- Track completed projects
		season_history = {}, -- Past seasons
	}
	self.loaded = true
end

-- Area XP methods
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

-- Project XP methods
function M.get_project_xp(name)
	store:ensure_loaded()
	return store.data.project_xp[name] or { xp = 0, level = 1 }
end

function M.set_project_xp(name, xp, level)
	store:ensure_loaded()
	store.data.project_xp[name] = { xp = xp, level = level }
	store:save()
end

function M.add_project_xp(name, xp_amount)
	store:ensure_loaded()
	local project = store.data.project_xp[name] or { xp = 0, level = 1 }
	project.xp = project.xp + xp_amount
	store.data.project_xp[name] = project
	store:save()
	return project.xp
end

-- Season methods
function M.get_season_data()
	store:ensure_loaded()
	return {
		current_season = store.data.current_season,
		season_xp = store.data.season_xp,
		season_level = store.data.season_level,
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
	store:save()
end

function M.end_season()
	store:ensure_loaded()
	if store.data.current_season then
		-- Archive season
		local season_record = {
			name = store.data.current_season.name,
			start_date = store.data.current_season.start_date,
			end_date = os.date("%Y-%m-%d"),
			final_level = store.data.season_level,
			final_xp = store.data.season_xp,
			projects = vim.deepcopy(store.data.project_xp),
		}
		table.insert(store.data.season_history, season_record)

		-- Reset season data
		store.data.current_season = nil
		store.data.season_xp = 0
		store.data.season_level = 1
		store.data.project_xp = {}
		store:save()

		return season_record
	end
	return nil
end

-- Objective tracking
function M.mark_objective_completed(objective_id, xp_awarded)
	store:ensure_loaded()
	store.data.completed_objectives[objective_id] = {
		completed_at = os.time(),
		xp_awarded = xp_awarded,
	}
	store:save()
end

function M.is_objective_completed(objective_id)
	store:ensure_loaded()
	return store.data.completed_objectives[objective_id] ~= nil
end

-- Project tracking
function M.mark_project_completed(project_name, xp_awarded)
	store:ensure_loaded()
	store.data.completed_projects[project_name] = {
		completed_at = os.time(),
		xp_awarded = xp_awarded,
	}
	store:save()
end

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
