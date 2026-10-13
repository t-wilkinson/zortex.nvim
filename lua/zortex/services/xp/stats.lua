-- services/xp/stats.lua - XP views and season actions (require("zortex").xp)
--
-- Read side of the XP system: season status, per-project and per-area XP,
-- recent awards and explanations, all from services/xp/ledger. Seasons are
-- started and ended here (stores/xp keeps them).
local M = {}

local xp_store = require("zortex.stores.xp")

local function ledger()
	return require("zortex.services.xp.ledger")
end

-- =============================================================================
-- Season
-- =============================================================================

--- { season, xp, level, current_tier, next_tier, is_max_tier, progress, progress_to_next, days_left }
--- or nil without a season.
function M.season_status()
	local season = xp_store.current_season()
	if not season then
		return nil
	end
	local xp = ledger().season_xp(season)
	local level = xp_store.calculate_season_level(xp)
	local tier = xp_store.get_season_tier(level)
	local progress = xp_store.get_level_progress(xp, level, xp_store.calculate_season_level_xp)
	local days_left
	if season.end_date then
		local y, m, d = season.end_date:match("(%d+)-(%d+)-(%d+)")
		if y then
			days_left = math.ceil((os.time({ year = y, month = m, day = d, hour = 23 }) - os.time()) / 86400)
		end
	end
	return {
		season = season,
		xp = math.floor(xp + 0.5),
		level = level,
		current_tier = tier.current,
		next_tier = tier.next,
		is_max_tier = tier.is_max_tier,
		progress = progress,
		progress_to_next = progress.progress,
		days_left = days_left,
	}
end

function M.start_season(name, end_date, start_date)
	if type(end_date) == "number" then
		end_date = os.date("%Y-%m-%d", end_date)
	end
	xp_store.start_season(name, end_date, start_date)
end

function M.end_season()
	local season = xp_store.started_season()
	if not season then
		return nil, "no season was started by hand; seasons follow the calendar quarter"
	end
	return xp_store.end_season(ledger().season_xp(season))
end

-- Interactive: ask for a name and a duration, then start the season
function M.prompt_start_season()
	local quarter = math.ceil(tonumber(os.date("%m")) / 3)
	local default_name = string.format("Q%d %s", quarter, os.date("%Y"))
	vim.ui.input({ prompt = "Season name: ", default = default_name }, function(name)
		if not name or name == "" then
			return
		end
		local cfg = require("zortex.config").xp or {}
		local default_days = tostring((cfg.season and cfg.season.default_length) or 90)
		vim.ui.input({ prompt = "Season duration (days): ", default = default_days }, function(days)
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
	local l = ledger().get()
	local out = {}
	for _, project in ipairs(require("zortex.services.projects").all({ include_roots = false })) do
		local own = project:stats()
		if own.total > 0 then
			local _, earned = ledger().for_project(project.key, l)
			out[#out + 1] = {
				project = project,
				key = project.key,
				earned_xp = math.floor(earned + 0.5),
				total_xp = calculator.calculate_project_total_xp(project, project:tasks()),
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
	local l = ledger().get()
	local stats = { total_areas = 0, areas_with_xp = 0, total_xp = 0, max_level = 0 }
	for _, area in ipairs(require("zortex.services.areas").all({ include_roots = false })) do
		stats.total_areas = stats.total_areas + 1
		local data = area:xp_data(l)
		if data.xp > 0 then
			stats.areas_with_xp = stats.areas_with_xp + 1
			stats.total_xp = stats.total_xp + data.xp
		end
		stats.max_level = math.max(stats.max_level, data.level or 0)
	end
	stats.total_xp = math.floor(stats.total_xp + 0.5)
	return stats
end

--- Recent awards: { date, xp, title, source, project?, file, lnum, areas }, newest first.
function M.recent(limit, days)
	local from = days and os.date("%Y-%m-%d", os.time() - days * 86400) or nil
	local list = ledger().between(from, nil)
	if limit and #list > limit then
		list = vim.list_slice(list, 1, limit)
	end
	return list
end

--- XP per day for the last `days` days: { { date, xp }, ... } oldest first.
function M.daily(days)
	days = days or 14
	local by_day = {}
	for _, e in ipairs(ledger().between(os.date("%Y-%m-%d", os.time() - (days - 1) * 86400), nil)) do
		by_day[e.date] = (by_day[e.date] or 0) + e.xp
	end
	local out = {}
	for i = days - 1, 0, -1 do
		local d = os.date("%Y-%m-%d", os.time() - i * 86400)
		out[#out + 1] = { date = d, xp = math.floor((by_day[d] or 0) + 0.5) }
	end
	return out
end

function M.get_stats()
	return {
		season = M.season_status(),
		projects = M.project_stats(),
		areas = M.area_stats(),
		recent = M.recent(10),
	}
end

-- =============================================================================
-- Display
-- =============================================================================

local function round(x)
	return math.floor(x + 0.5)
end

function M.show_stats()
	local stats = M.get_stats()
	local lines = { "📊 XP Statistics", "" }

	if stats.season then
		local s = stats.season
		table.insert(lines, "🏆 Season: " .. s.season.name .. (s.days_left and string.format(" (%d days left)", s.days_left) or ""))
		table.insert(lines, string.format("   Level %d · %d XP · %d to next", s.level, s.xp, s.progress.xp_to_next))
		if s.current_tier then
			table.insert(lines, "   Tier: " .. s.current_tier.name)
		end
		table.insert(lines, "")
	else
		table.insert(lines, "No season running (:ZortexSeasonStart)")
		table.insert(lines, "")
	end

	local active = vim.tbl_filter(function(p)
		return p.done > 0 and p.done < p.total
	end, stats.projects)
	table.sort(active, function(a, b)
		return a.earned_xp > b.earned_xp
	end)
	if #active > 0 then
		table.insert(lines, "📁 Projects in progress:")
		for i, p in ipairs(active) do
			if i > 8 then
				break
			end
			table.insert(lines, string.format("   %s: %d/%d XP (%d/%d tasks)", p.key, p.earned_xp, p.total_xp, p.done, p.total))
		end
		table.insert(lines, "")
	end

	if #stats.recent > 0 then
		table.insert(lines, "✨ Recent:")
		for _, e in ipairs(stats.recent) do
			table.insert(lines, string.format("   %s  +%-4d %s", e.date or "     ?    ", round(e.xp), e.title))
		end
		table.insert(lines, "")
	end

	local a = stats.areas
	table.insert(lines, string.format("🏔️  Areas: %d total, %d with XP · %d XP · max level %d", a.total_areas, a.areas_with_xp, a.total_xp, a.max_level))

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "XP Stats" })
end

function M.show_area_xp(limit)
	local top = require("zortex.services.areas").top(limit or 10)
	local lines = { "🗺️ Top Areas by XP", string.rep("─", 40) }
	for i, area in ipairs(top) do
		table.insert(lines, string.format("%d. %s - Level %s (%d XP)", i, area.key, tostring(area.level or "?"), round(area.xp)))
	end
	if #top == 0 then
		table.insert(lines, "No areas with XP yet")
	end
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Area XP Rankings", timeout = 5000 })
end

--- Why does the project at the cursor have the XP it has?
function M.explain_project(project)
	project = project or require("zortex.services.projects").current()
	if not project then
		vim.notify("Not in a project", vim.log.levels.WARN)
		return
	end
	local calculator = require("zortex.services.xp.calculator")
	local l = ledger().get()
	local group = l.projects[project.key]
	local tasks = group and group.tasks or project:tasks()
	local done = 0
	for _, t in ipairs(tasks) do
		done = done + (t.completed and 1 or 0)
	end
	local archived = #tasks - #project:tasks()
	local pool = calculator.calculate_project_total_xp(project, tasks)
	local entries, earned = ledger().for_project(project.key, l)
	local how = tonumber(project.attributes.xp) and "@xp" or project.attributes.size and ("@size(" .. project.attributes.size .. ")") or "sum of its tasks"
	local lines = {
		project.key,
		string.format(
			"Pool %d XP (%s) · earned %d · %d/%d tasks done%s",
			round(pool),
			how,
			round(earned),
			done,
			#tasks,
			archived > 0 and string.format(" (%d archived)", archived) or ""
		),
		"",
	}
	for _, e in ipairs(entries) do
		local areas = {}
		for key, amount in pairs(e.areas) do
			areas[#areas + 1] = string.format("%s +%.1f", key:match("[^/]+$") or key, amount)
		end
		table.sort(areas)
		lines[#lines + 1] = string.format("%s  +%-4d %s%s", e.date or "     ?    ", round(e.xp), e.title, #areas > 0 and ("  → " .. table.concat(areas, ", ")) or "")
	end
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Project XP" })
end

return M
