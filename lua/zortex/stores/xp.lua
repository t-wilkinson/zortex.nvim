-- stores/xp.lua - XP state persistence with source tracking
local M = {}

local Events = require("zortex.core.event_bus")
local BaseStore = require("zortex.stores.base")
local constants = require("zortex.constants")

-- Create the singleton store
local store = BaseStore:new(constants.FILES.XP_STATE_DATA)
local cfg = {} -- Config.xp

-- Add to init_empty function:
function store:init_empty()
	self.data = {
		-- Simple XP totals
		season_xp = 0,
		season_level = 1,
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

-- =============================================================================
-- XP Transactions
-- =============================================================================

function M.build_xp_transaction(entity_type, entity_id, xp_amount, distributions)
	local transaction = {
		type = entity_type,
		id = entity_id,
		timestamp = os.time(),
		base_xp = xp_amount,
		season_xp = 0,
		area_xp = {}, -- area path -> xp
		-- project_xp = {}, -- project id -> xp
	}

	-- Group distributions by target
	for _, dist in ipairs(distributions) do
		if dist.target == "season" then
			transaction.season_xp = transaction.season_xp + dist.amount
		elseif dist.target == "area" then
			transaction.area_xp[dist.path] = dist.amount
			-- elseif dist.target == "project" then
			--   transaction.project_xp[dist.path] = dist.amount
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
		xp_change = xp_change - M.remove_xp_transaction(transaction.id).base_xp
	end

	-- Add the new transaction if it adds xp, calculating the change in xp
	if transaction.base_xp == 0 then
		return xp_change
	end
	store.data.xp_transactions[transaction.id] = transaction
	xp_change = xp_change + transaction.base_xp

	-- Update store total season xp and area xp
	if store.data.current_season then
		store.data.season_xp = store.data.season_xp + transaction.season_xp
		M.update_season_level()
	end

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

	if store.data.current_season then
		local new_season_xp = store.data.season_xp - transaction.season_xp
		store.data.season_xp = math.max(new_season_xp, 0)
	end

	for area_path, area_xp in pairs(transaction.area_xp) do
		local new_area_xp = (store.data.area_xp[area_path] or 0) - area_xp
		store.data.area_xp[area_path] = math.max(new_area_xp, 0)
	end

	store.data.xp_transactions[id] = nil
	store:save()

	return transaction
end

-- =============================================================================
-- Season Helpers
-- =============================================================================

-- Calculate XP required for a specific season level
function M.calculate_season_level_xp(level)
	local curve = cfg.project.season_curve
	return math.floor(curve.base * math.pow(level, curve.exponent))
end

-- Calculate level from total XP (season)
function M.calculate_season_level(xp)
	local level = 1
	while xp >= M.calculate_season_level_xp(level + 1) do
		level = level + 1
	end
	return level
end

-- Get progress towards next level
function M.get_level_progress(xp, level, level_calc_fn)
	local current_threshold = level_calc_fn(level)
	local next_threshold = level_calc_fn(level + 1)

	local progress = (xp - current_threshold) / (next_threshold - current_threshold)
	local xp_to_next = next_threshold - xp

	return {
		current_level = level,
		progress = math.max(0, math.min(1, progress)),
		xp_to_next = xp_to_next,
		current_threshold = current_threshold,
		next_threshold = next_threshold,
	}
end

-- Check for level ups
function M.update_season_level()
	if not store.data.current_season then
		return nil
	end

	-- Check for season level up
	local old_level = store.data.season_level
	local new_level = M.calculate_season_level(store.data.season_xp)

	-- Update if level-up (for now don't change if level-down)
	if new_level > old_level then
		store.data.season_level = new_level
		Events.emit("season:leveled_up", {
			old_level = old_level,
			new_level = new_level,
			tier_info = M.get_season_tier(new_level),
		})
	end
end

-- Get tier information for a season level
function M.get_season_tier(level)
	local tiers = cfg.seasons.tiers
	local current_tier = nil
	local next_tier = nil

	for i, tier in ipairs(tiers) do
		if level >= tier.required_level then
			current_tier = tier
			next_tier = tiers[i + 1]
		else
			if not next_tier then
				next_tier = tier
			end
			break
		end
	end

	return {
		current = current_tier,
		next = next_tier,
		is_max_tier = current_tier and not next_tier,
	}
end

-- =============================================================================
-- Season Methods
-- =============================================================================

function M.get_season_data()
	store:ensure_loaded()
	if not store.data.current_season then
		return nil
	end

	local xp = store.data.season_xp
	local level = M.calculate_season_level(store.data.season_xp)
	local tier_info = M.get_season_tier(level)
	local progress = M.get_level_progress(xp, level, M.calculate_season_level_xp)

	return {
		season = store.data.current_season,
		xp = xp,
		level = level,
		current_tier = tier_info.current,
		next_tier = tier_info.next,
		is_max_tier = tier_info.is_max_tier,
		progress = progress,
	}
end

function M.start_season(name, end_date)
	store:ensure_loaded()
	M.reset_season()
	store.data.current_season = {
		name = name,
		start_date = os.date("%Y-%m-%d"),
		end_date = end_date,
		start_time = os.time(),
	}
	store:save()

	Events.emit("season:started", {
		name = name,
		end_date = end_date,
	})
end

function M.end_season()
	store:ensure_loaded()
	if not store.data.current_season then
		return nil
	end

	-- Archive season with source breakdown
	local season_record = {
		name = store.data.current_season.name,
		start_date = store.data.current_season.start_date,
		end_date = os.date("%Y-%m-%d"),
		final_level = store.data.season_level,
		final_xp = store.data.season_xp,

		-- Move all transactions, include for target "area", as these were earned in this season
		xp_transactions = vim.deepcopy(store.data.xp_transactions),
	}
	table.insert(store.data.season_history, season_record)

	-- Reset season data
	M.reset_season()

	store:save()

	Events.emit("season:ended", {
		season = season_record,
	})

	return season_record
end

function M.reset_season()
	store:ensure_loaded()

	store.data.current_season = nil
	store.data.season_xp = 0
	store.data.season_level = 1
	store.data.xp_transactions = {}

	store:mark_dirty()
end
-- =============================================================================
-- Area Methods
-- =============================================================================

-- Calculate XP required for a specific area level
function M.calculate_area_level_xp(level)
	local curve = cfg.area.level_curve
	return math.floor(curve.base * math.pow(level, curve.exponent))
end

-- Calculate level from total XP (area)
function M.calculate_area_level(xp)
	local level = 1
	while xp >= M.calculate_area_level_xp(level + 1) do
		level = level + 1
	end
	return level
end

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

function M.setup(opts)
	cfg = opts
end

-- Force operations
function M.reload()
	store.loaded = false
	store:load()
end

function M.save()
	store:save()
end

return M
