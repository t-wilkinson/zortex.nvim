-- stores/xp.lua - XP state persistence with source tracking
local M = {}

local BaseStore = require("zortex.stores.base")
local constants = require("zortex.constants")

-- Create the singleton store
local store = BaseStore:new(constants.FILES.XP_STATE_DATA)

-- Add to init_empty function:
function store:init_empty()
	self.data = {
		-- Simple XP totals
		season_xp = 0,
		area_xp = {}, -- path -> total
		-- project_xp = {}, -- name -> total

		-- Transaction log for reversibility
		xp_transactions = {}, -- id -> {type, amount, distributions, timestamp}

		-- Season management
		current_season = nil,
		season_history = {},
	}
	self.loaded = true
end

function M.build_xp_transaction(entity_type, entity_id, xp_amount, distributions)
	local transaction = {
		type = entity_type,
		id = entity_id,
		timestamp = os.time(),
		base_xp = xp_amount,
		season_xp = 0,
		area_xp = {},
	}

	-- Group distributions by target
	for _, dist in ipairs(distributions) do
		if dist.target == "season" then
			transaction.season_xp = transaction.season_xp + dist.amount
		elseif dist.target == "area" then
			transaction.area_xp[dist.path] = dist.amount
		end
	end

	return transaction
end

function M.get_xp_transaction(id)
	store:ensure_loaded()
	return store.data.xp_transactions[id]
end

-- Transaction management
function M.record_xp_transaction(transaction)
	store:ensure_loaded()
	local xp_change = 0

	-- Remove transaction if exists
	local old_transaction = store.data.xp_transactions[transaction.id]
	if old_transaction then
		xp_change = -M.remove_xp_transaction(transaction.id).base_xp
	end

	-- Add the new transaction if it adds xp, calculating the change in xp
	if transaction.base_xp == 0 then
		return xp_change
	end
	store.data.xp_transactions[transaction.id] = transaction
	xp_change = xp_change + transaction.base_xp

	-- Update store total season xp and area xp
	store.data.season_xp = store.data.season_xp + transaction.season_xp
	for area_path, area_xp in pairs(transaction.area_xp) do
		store.data.area_xp[area_path] = (store.data.area_xp[area_path] or 0) + area_xp
	end

	store:save()

	return xp_change
end

function M.remove_xp_transaction(id)
	store:ensure_loaded()
	local transaction = store.data.xp_transactions[id]

	if not transaction then
		store:save()
		return nil
	end

	local new_season_xp = store.data.season_xp - transaction.season_xp
	store.data.season_xp = math.max(new_season_xp, 0)

	for area_path, area_xp in pairs(transaction.area_xp) do
		local new_area_xp = (store.data.area_xp[area_path] or 0) - area_xp
		store.data.area_xp[area_path] = math.max(new_area_xp, 0)
	end

	store.data.xp_transactions[id] = nil
	store:save()

	return transaction
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
-- Area Methods
-- =============================================================================

function M.get_area_xp(path)
	return store.data.area_xp[path] or nil
end

-- -- Get area statistics
-- function M.get_area_stats(area_path)
-- 	if area_path then
-- 		-- Single area stats
-- 		local data = xp_store.get_area_xp(area_path)
-- 		local progress = xp_core.get_level_progress(data.xp, data.level, xp_core.calculate_area_level_xp)
--
-- 		return {
-- 			path = area_path,
-- 			xp = data.xp,
-- 			level = data.level,
-- 			progress = progress,
-- 		}
-- 	else
-- 		-- All areas
-- 		return xp_store.get_all_area_xp()
-- 	end
-- end
--
-- -- Get top areas by XP
-- function M.get_top_areas(limit)
-- 	limit = limit or 10
-- 	local all_areas = xp_store.get_all_area_xp()
-- 	local sorted = {}
--
-- 	for path, data in pairs(all_areas) do
-- 		table.insert(sorted, {
-- 			path = path,
-- 			xp = data.xp,
-- 			level = data.level,
-- 		})
-- 	end
--
-- 	table.sort(sorted, function(a, b)
-- 		return a.xp > b.xp
-- 	end)
--
-- 	-- Return top N
-- 	local result = {}
-- 	for i = 1, math.min(limit, #sorted) do
-- 		table.insert(result, sorted[i])
-- 	end
--
-- 	return result
-- end

-- =============================================================================
-- Core methods
-- =============================================================================

-- Force operations
function M.reload()
	store.loaded = false
	store:load()
end

function M.save()
	store:save()
end

return M
