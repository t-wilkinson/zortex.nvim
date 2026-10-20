-- ui/xp.lua - :ZortexXP (<leader>zxx): everything XP in one view
--
-- A float with, top to bottom:
--
--   Season         the season's objectives, its tier and the next one
--   Last 14 days   XP per day, and how much of the work done went to key
--                  results, to areas only, or to neither
--   Projects       the projects in progress, by XP earned
--   Recent         the latest awards
--   Areas          the area tree with levels and progress to the next one
--
-- XP is estimated work: 10 XP = 1 hour (xp.xp_per_hour); hours sit next to
-- it. <CR> on a project, award or area line opens where it is written; g
-- shows :ZortexXPGuide, e :ZortexXPExplain for the project on the line, r
-- refreshes, q closes, ? lists the keys. render() is pure (lines,
-- highlights, line -> location), for tests and other front ends.
local M = {}

local constants = require("zortex.constants")

local function stats()
	return require("zortex.services.xp.stats")
end

local function hours(xp)
	return require("zortex.services.xp.calculator").hours_text(xp)
end

local function bar(progress, width)
	local filled = math.floor(math.max(0, math.min(1, progress)) * width + 0.5)
	return string.rep("█", filled) .. string.rep("░", width - filled)
end

local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local function sparkline(values)
	local max = 0
	for _, v in ipairs(values) do
		max = math.max(max, v)
	end
	local out = {}
	for _, v in ipairs(values) do
		out[#out + 1] = (max == 0 or v == 0) and "·" or SPARK[math.max(1, math.ceil(v / max * #SPARK))]
	end
	return table.concat(out)
end

local function round(x)
	return math.floor(x + 0.5)
end

local function level_group(level)
	if level <= 3 then
		return constants.HIGHLIGHTS.MASTERY_LEVEL_1_3
	elseif level <= 6 then
		return constants.HIGHLIGHTS.MASTERY_LEVEL_4_6
	elseif level <= 9 then
		return constants.HIGHLIGHTS.MASTERY_LEVEL_7_9
	end
	return constants.HIGHLIGHTS.MASTERY_LEVEL_10_PLUS
end

--- The work done in the last `days` days, from the ledger: XP and Mastery
--- XP per day (oldest first), and how it served the plan by the awards'
--- `aligned`: { days = { { date, xp, mastery } }, kr, area, none, total }.
function M.recent_work(days)
	days = days or 14
	local out = { days = {}, kr = 0, area = 0, none = 0, total = 0, mastery = 0 }
	local by = {}
	for i = days - 1, 0, -1 do
		local d = os.date("%Y-%m-%d", os.time() - i * 86400)
		by[d] = { date = d, xp = 0, mastery = 0 }
		out.days[#out.days + 1] = by[d]
	end
	for _, e in ipairs(require("zortex.services.xp.ledger").between(out.days[1].date, nil)) do
		local day = by[e.date]
		if day then
			local xp = e.xp or 0
			day.xp = day.xp + xp
			day.mastery = day.mastery + (e.mastery or 0)
			local k = e.aligned == "kr" and "kr" or e.aligned == "area" and "area" or "none"
			out[k] = out[k] + xp
			out.total = out.total + xp
			out.mastery = out.mastery + (e.mastery or 0)
		end
	end
	return out
end

--- Lines, highlights ({ line (1-based), col, end_col, group }) and
--- line -> { file, lnum, project? } for the view.
---@param data table? defaults to the live data (stats.get_stats etc.)
function M.render(data)
	data = data or {}
	local season = data.season
	if data.season == nil then
		season = stats().season_status()
	end
	local work = data.work or M.recent_work(14)
	local projects = data.projects or stats().project_stats()
	local recent = data.recent or stats().recent(10)
	local tree = data.tree
	if tree == nil then
		local ok, t = pcall(require("zortex.services.areas").get_area_tree)
		tree = ok and t or false
	end

	local lines, hls, where = {}, {}, {}
	local function add(text, loc)
		lines[#lines + 1] = text
		where[#lines] = loc
		return #lines
	end
	local function hl(line, col, end_col, group)
		hls[#hls + 1] = { line = line, col = col, end_col = end_col, group = group }
	end
	local function section(title)
		add("")
		add("## " .. title)
	end

	add("@@XP")
	add("10 XP = 1 hour of estimated work · g guide · ? keys")

	-- Season
	if season then
		section(string.format(
			"%s · %s to %s%s",
			require("zortex.services.xp.season").label(season.season),
			season.season.start_date or "?",
			season.season.end_date or "?",
			season.days_left and string.format(" · %d days left", season.days_left) or ""
		))
		local b = bar(season.progress, 24)
		local l = add(string.format(
			"%s %3.0f%%  %s%s",
			b,
			season.progress * 100,
			season.tier and season.tier.name or "no tier yet",
			season.next_tier and string.format(" · %s at %.0f%%", season.next_tier.name, season.next_tier.at * 100) or " · every objective done"
		))
		hl(l, 0, #b, constants.HIGHLIGHTS.PROGRESS_BAR)
		if #season.objectives == 0 then
			add("No objectives in this season: add one under its heading in okr.zortex (## Title @a(…)).")
		end
		for _, x in ipairs(season.objectives) do
			local o = x.objective
			add(
				string.format("  %3.0f%%  %s  (%.0f%% of the season)", x.progress * 100, o.title or o.name, x.share * 100),
				o.file and { file = o.file, lnum = o.lnum } or nil
			)
		end
	else
		section("Season")
		add("No season: xp.season.follow_quarter is off. :ZortexSeason start begins one.")
	end

	-- Last 14 days
	section("Last 14 days")
	local values, week = {}, 0
	for i, d in ipairs(work.days) do
		values[#values + 1] = d.xp
		if i > #work.days - 7 then
			week = week + d.xp
		end
	end
	local today = work.days[#work.days] and work.days[#work.days].xp or 0
	add(string.format(
		"XP %s  %d (%s) · 7 days %d · today %d · Mastery %d",
		sparkline(values),
		round(work.total),
		hours(work.total),
		round(week),
		round(today),
		round(work.mastery)
	))
	if work.total > 0 then
		local function pct(x)
			return round(x / work.total * 100)
		end
		add(string.format(
			"Work done: %d%% on key results · %d%% on areas only · %d%% on neither",
			pct(work.kr),
			pct(work.area),
			pct(work.none)
		))
	else
		add("Nothing completed in these days yet.")
	end

	-- Projects in progress
	local active = vim.tbl_filter(function(p)
		return p.done > 0 and p.done < p.total
	end, projects)
	table.sort(active, function(a, b)
		return a.earned_xp > b.earned_xp
	end)
	section(string.format("Projects in progress (%d)", #active))
	for i, p in ipairs(active) do
		if i > 8 then
			add(string.format("  … and %d more (:ZortexProjects)", #active - 8))
			break
		end
		add(
			string.format(
				"  %s  %d/%d XP (%s of %s) · %d/%d tasks",
				p.project.link or p.key,
				p.earned_xp,
				p.total_xp,
				hours(p.earned_xp),
				hours(p.total_xp),
				p.done,
				p.total
			),
			{ file = p.project.file, lnum = p.project.lnum, project = p.project }
		)
	end

	-- Recent awards
	section("Recent")
	if #recent == 0 then
		add("No awards yet: tick a task with a @size.")
	end
	for _, e in ipairs(recent) do
		local m = round(e.mastery or 0)
		add(
			string.format("  %s  %-5s %s", e.date or "    ?     ", m > 0 and ("+" .. m) or "·", e.title or e.source or ""),
			e.file and { file = e.file, lnum = e.lnum } or nil
		)
	end
	add("  (+ Mastery XP; · work on neither a key result nor an area)")

	-- Areas
	section("Areas")
	if not tree then
		add("No areas.zortex yet.")
	else
		local any = false
		local function walk(node, depth)
			local show = not node:is_root()
			if show then
				any = true
				local indent = string.rep("  ", depth)
				local d = node:xp_data()
				if d.total_xp > 0 and d.level then
					local lvl = string.format("Lvl %d", d.level)
					local b = d.progress and (" " .. bar(d.progress, 10)) or ""
					local text = string.format("%s%s  %s  %d XP (%s)%s", indent, node.name, lvl, round(d.total_xp), hours(d.total_xp), b)
					local l = add(text, { file = node.file, lnum = node.lnum })
					local s = #indent + #node.name + 2
					hl(l, s, s + #lvl, level_group(d.level))
					if b ~= "" then
						hl(l, #text - #b + 1, #text, constants.HIGHLIGHTS.PROGRESS_BAR)
					end
				else
					add(indent .. node.name .. "  no XP yet", { file = node.file, lnum = node.lnum })
				end
			end
			for _, child in ipairs(node.children or {}) do
				walk(child, show and depth + 1 or depth)
			end
		end
		walk(tree, 0)
		if not any then
			add("No areas in areas.zortex yet.")
		end
	end
	return lines, hls, where
end

-- =============================================================================
-- The window
-- =============================================================================

local state = { buf = nil, win = nil, where = {}, from_win = nil }

local function define_highlights()
	local links = {
		[constants.HIGHLIGHTS.MASTERY_LEVEL_1_3] = "Comment",
		[constants.HIGHLIGHTS.MASTERY_LEVEL_4_6] = "String",
		[constants.HIGHLIGHTS.MASTERY_LEVEL_7_9] = "Function",
		[constants.HIGHLIGHTS.MASTERY_LEVEL_10_PLUS] = "Special",
		[constants.HIGHLIGHTS.PROGRESS_BAR] = "DiagnosticOk",
	}
	for group, link in pairs(links) do
		vim.api.nvim_set_hl(0, group, { link = link, default = true })
	end
end

local NS = vim.api.nvim_create_namespace("zortex_xp")

local function fill()
	local lines, hls, where = M.render()
	state.where = where
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false
	pcall(require("zortex.features.highlights").highlight_buffer, state.buf)
	vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
	for _, h in ipairs(hls) do
		pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, h.line - 1, h.col, { end_col = h.end_col, hl_group = h.group })
	end
end

function M.close()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_close(state.win, true)
	end
	state.win = nil
end

local function here()
	return state.where[vim.api.nvim_win_get_cursor(0)[1]]
end

local function open_location()
	local loc = here()
	if not (loc and loc.file) then
		return
	end
	M.close()
	if state.from_win and vim.api.nvim_win_is_valid(state.from_win) then
		vim.api.nvim_set_current_win(state.from_win)
	end
	vim.cmd("edit " .. vim.fn.fnameescape(loc.file))
	if loc.lnum then
		pcall(vim.api.nvim_win_set_cursor, 0, { loc.lnum, 0 })
		vim.cmd("normal! zvzz")
	end
end

--- :ZortexXP: open the view (or refresh it when it is open).
function M.show()
	define_highlights()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		return fill()
	end
	state.from_win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_create_buf(false, true)
	state.buf = buf
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	local cfg = vim.tbl_extend("force", { width = 90, height = 40, border = "rounded" }, ((require("zortex.config").ui or {}).xp or {}))
	local width = math.min(cfg.width, vim.o.columns - 4)
	local height = math.min(cfg.height, vim.o.lines - 4)
	state.win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((vim.o.columns - width) / 2),
		row = math.floor((vim.o.lines - height) / 2),
		style = "minimal",
		border = cfg.border,
		title = " XP ",
		title_pos = "center",
	})
	vim.wo[state.win].wrap = false
	fill()
	require("zortex.keys").map(buf, "xp", {
		open = open_location,
		guide = function()
			M.close()
			require("zortex.ui.xp_guide").show()
		end,
		explain = function()
			local loc = here()
			if not (loc and loc.project) then
				return vim.notify("Put the cursor on a project line", vim.log.levels.INFO, { title = "Zortex" })
			end
			stats().explain_project(loc.project)
		end,
		refresh = fill,
		close = M.close,
		help = function()
			require("zortex.ui.keyhelp").show("xp")
		end,
	})
end

return M
