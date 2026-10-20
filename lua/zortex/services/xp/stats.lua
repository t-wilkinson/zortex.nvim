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

--- The season's progress on its objectives (services/xp/season.status):
--- { season, progress, tier, tier_index, next_tier, objectives, value, days_left },
--- or nil without a season.
function M.season_status()
	return require("zortex.services.xp.season").status()
end

--- Start a season (stores/xp) and give it a top-level heading in the OKR
--- note ("# 2026-Q4 Season 10 Juniper"), where its objectives go. opts.heading
--- = false leaves the note alone. Returns the heading's line number, if any.
function M.start_season(name, end_date, start_date, opts)
	if type(end_date) == "number" then
		end_date = os.date("%Y-%m-%d", end_date)
	end
	name = (name and name ~= "") and name or require("zortex.services.okr").next_season_name()
	start_date = start_date or os.date("%Y-%m-%d")
	xp_store.start_season(name, end_date, start_date)
	if opts and opts.heading == false then
		return nil
	end
	local ok, lnum = pcall(require("zortex.services.okr").add_season_heading, name, start_date, end_date)
	return ok and lnum or nil
end

function M.end_season()
	local season = xp_store.started_season()
	if not season then
		return nil, "no season was started by hand; seasons follow the calendar quarter"
	end
	local status = require("zortex.services.xp.season").status(season)
	return xp_store.end_season({ progress = status and status.progress or 0, tier = status and status.tier and status.tier.name })
end

-- Interactive: ask for a name and a duration, then start the season
function M.prompt_start_season()
	local default_name = require("zortex.services.okr").next_season_name()
	vim.ui.input({ prompt = "Season name: ", default = default_name }, function(name)
		if not name or name == "" then
			return
		end
		local cfg = require("zortex.config").xp or {}
		local default_days = tostring((cfg.season and cfg.season.default_length) or 90)
		vim.ui.input({ prompt = "Season duration (days): ", default = default_days }, function(days)
			local end_date = os.date("%Y-%m-%d", os.time() + (tonumber(days) or 90) * 86400)
			M.start_season(name, end_date)
			vim.notify(
				string.format("Season '%s' started!\nEnds: %s · its objectives go under its heading in the OKR note", name, end_date),
				vim.log.levels.INFO
			)
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
				total_xp = calculator.calculate_project_total_xp(project, project:leaf_tasks()),
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

--- Mastery XP per day for the last `days` days: { { date, xp }, ... }
--- oldest first.
function M.daily(days)
	days = days or 14
	local by_day = {}
	for _, e in ipairs(ledger().between(os.date("%Y-%m-%d", os.time() - (days - 1) * 86400), nil)) do
		by_day[e.date] = (by_day[e.date] or 0) + (e.mastery or 0)
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
	local tasks = group and group.tasks or project:leaf_tasks()
	local done = 0
	for _, t in ipairs(tasks) do
		done = done + ((t.done_effective or (t.done_effective == nil and t.completed)) and 1 or 0)
	end
	local archived = #tasks - #project:leaf_tasks()
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
