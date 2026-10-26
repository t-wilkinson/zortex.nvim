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

--- Start a season over `span`, a window in the objectives' format
--- ("3M-2026-Q4", "1M-2026-11"; default: the calendar quarter now), named
--- `name` (default: the next "Season N <word>"). The OKR note gets a
--- "# 3M-2026-Q4 Season 10 Juniper" heading for its objectives (opts.heading
--- = false: not). Returns the season, or nil and an error.
function M.start_season(span, name, opts)
	local okr = require("zortex.services.okr")
	local w = okr.parse_span(span or okr.quarter_span())
	if not w then
		return nil, "not a span: " .. tostring(span) .. " (like 3M-2026-Q4, 1M-2026-11 or 6M-2026-H2)"
	end
	name = (name and name ~= "") and name or okr.next_season_name()
	xp_store.start_season(name, w.end_date, w.start_date, w.span)
	if not (opts and opts.heading == false) then
		pcall(okr.add_season_heading, w.span, name)
	end
	return xp_store.started_season()
end

function M.end_season()
	local season = xp_store.started_season()
	if not season then
		return nil, "no season was started by hand; seasons follow the calendar quarter"
	end
	local status = require("zortex.services.xp.season").status(season)
	return xp_store.end_season({ progress = status and status.progress or 0, tier = status and status.tier and status.tier.name })
end

-- Interactive: ask for the span and the name, then start the season
function M.prompt_start_season()
	local okr = require("zortex.services.okr")
	vim.ui.input({ prompt = "Season (span): ", default = okr.quarter_span() }, function(span)
		if not span or span == "" then
			return
		end
		vim.ui.input({ prompt = "Name: ", default = okr.next_season_name() }, function(name)
			local season, err = M.start_season(vim.trim(span), name)
			if not season then
				return vim.notify(err, vim.log.levels.WARN, { title = "Zortex" })
			end
			vim.notify(
				string.format("%s started: %s to %s; its heading is in the OKR note", season.name, season.start_date, season.end_date),
				vim.log.levels.INFO,
				{ title = "Zortex" }
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

-- { total_areas, areas_with_xp, total_xp (every area's own XP, summed:
-- no sub-area counted twice), max_level }
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

--- XP per day for the last `days` days, oldest first: { { date, xp (area
--- XP, Mastery), season (season XP), effort (the work's XP), kr, area,
--- none (effort by how it served the plan) }, ... }, rounded.
function M.daily(days)
	days = days or 14
	local by_day = {}
	for _, e in ipairs(ledger().between(os.date("%Y-%m-%d", os.time() - (days - 1) * 86400), nil)) do
		local d = by_day[e.date] or { xp = 0, season = 0, effort = 0, kr = 0, area = 0, none = 0 }
		by_day[e.date] = d
		d.xp = d.xp + (e.mastery or 0)
		d.season = d.season + (e.season or 0)
		d.effort = d.effort + (e.xp or 0)
		local k = e.aligned == "kr" and "kr" or e.aligned == "area" and "area" or "none"
		d[k] = d[k] + (e.xp or 0)
	end
	local function r(x)
		return math.floor((x or 0) + 0.5)
	end
	local out = {}
	for i = days - 1, 0, -1 do
		local date = os.date("%Y-%m-%d", os.time() - i * 86400)
		local d = by_day[date] or {}
		out[#out + 1] = {
			date = date,
			xp = r(d.xp),
			season = r(d.season),
			effort = r(d.effort),
			kr = r(d.kr),
			area = r(d.area),
			none = r(d.none),
		}
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
