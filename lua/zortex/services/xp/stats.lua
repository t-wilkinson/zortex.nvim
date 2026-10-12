-- services/xp/stats.lua - XP views and season actions
--
-- Read-side of the XP system for commands and UI: season status, per-project
-- and per-area XP, and season start/end. State lives in stores/xp; project and
-- area data come from services/projects and services/areas.
local M = {}

local xp_store = require("zortex.stores.xp")

-- =============================================================================
-- Season
-- =============================================================================

-- stores/xp season data plus `progress_to_next` (0..1), or nil without a season
function M.season_status()
	local data = xp_store.get_season_data()
	if not data then
		return nil
	end
	data.progress_to_next = data.progress and data.progress.progress or 0
	return data
end

function M.start_season(name, end_date)
	if type(end_date) == "number" then
		end_date = os.date("%Y-%m-%d", end_date)
	end
	xp_store.start_season(name, end_date)
end

function M.end_season()
	return xp_store.end_season()
end

-- Interactive: ask for a name and a duration, then start the season
function M.prompt_start_season()
	local quarter = math.ceil(tonumber(os.date("%m")) / 3)
	local default_name = string.format("Q%d %s", quarter, os.date("%Y"))
	vim.ui.input({ prompt = "Season name: ", default = default_name }, function(name)
		if not name or name == "" then
			return
		end
		vim.ui.input({ prompt = "Season duration (days): ", default = "90" }, function(days)
			local end_date = os.date("%Y-%m-%d", os.time() + (tonumber(days) or 90) * 86400)
			M.start_season(name, end_date)
			vim.notify(string.format("Season '%s' started!\nEnds: %s", name, end_date), vim.log.levels.INFO)
		end)
	end)
end

-- =============================================================================
-- Projects & areas
-- =============================================================================

-- Projects with tasks: { project, key, earned_xp, total_xp, done, total, completion }
function M.project_stats()
	local calculator = require("zortex.services.xp.calculator")
	local out = {}
	for _, project in ipairs(require("zortex.services.projects").all({ include_roots = false })) do
		local own = project:stats()
		if own.total > 0 then
			local ok, earned, details = pcall(calculator.calculate_project_xp, project)
			if ok and type(earned) == "table" then -- no-task shape
				earned, details = earned.earned_xp, earned
			end
			out[#out + 1] = {
				project = project,
				key = project.key,
				earned_xp = ok and earned or 0,
				total_xp = ok and details and details.total_xp or 0,
				done = own.done,
				total = own.total,
				completion = own.completion,
			}
		end
	end
	return out
end

-- { total_areas, areas_with_xp, total_xp, max_level }
function M.area_stats()
	local stats = { total_areas = 0, areas_with_xp = 0, total_xp = 0, max_level = 0 }
	for _, area in ipairs(require("zortex.services.areas").all({ include_roots = false })) do
		stats.total_areas = stats.total_areas + 1
		local data = area:xp_data()
		if data.xp > 0 then
			stats.areas_with_xp = stats.areas_with_xp + 1
			stats.total_xp = stats.total_xp + data.xp
		end
		stats.max_level = math.max(stats.max_level, data.level or 0)
	end
	return stats
end

function M.get_stats()
	return {
		season = M.season_status(),
		projects = M.project_stats(),
		areas = M.area_stats(),
	}
end

-- =============================================================================
-- Display
-- =============================================================================

function M.show_stats()
	local stats = M.get_stats()
	local lines = { "📊 XP Statistics", "" }

	if stats.season then
		table.insert(lines, "🏆 Season: " .. stats.season.season.name)
		table.insert(lines, string.format("   Level: %d", stats.season.level))
		table.insert(lines, string.format("   XP: %d", stats.season.xp))
		if stats.season.current_tier then
			table.insert(lines, "   Tier: " .. stats.season.current_tier.name)
		end
		table.insert(lines, "")
	end

	if #stats.projects > 0 then
		table.insert(lines, "📁 Projects:")
		for _, p in ipairs(stats.projects) do
			table.insert(
				lines,
				string.format("   %s: %d/%d XP (%d/%d tasks)", p.key, p.earned_xp, p.total_xp, p.done, p.total)
			)
		end
		table.insert(lines, "")
	end

	local a = stats.areas
	table.insert(lines, string.format("🏔️  Areas: %d total, %d with XP", a.total_areas, a.areas_with_xp))
	table.insert(lines, string.format("   Total XP: %d", a.total_xp))
	table.insert(lines, string.format("   Max Level: %d", a.max_level))

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "XP Stats" })
end

function M.show_area_xp(limit)
	local top = require("zortex.services.areas").top(limit or 10)
	local lines = { "🗺️ Top Areas by XP", string.rep("─", 40) }
	for i, area in ipairs(top) do
		table.insert(
			lines,
			string.format("%d. %s - Level %s (%d XP)", i, area.key, tostring(area.level or "?"), area.xp)
		)
	end
	if #top == 0 then
		table.insert(lines, "No areas with XP yet")
	end
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Area XP Rankings", timeout = 5000 })
end

return M
