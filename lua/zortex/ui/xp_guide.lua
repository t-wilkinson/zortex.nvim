-- ui/xp_guide.lua - :ZortexXPGuide: how XP is calibrated, from your config
--
-- A popup that spells out what the xp config means: how many hours each
-- @size stands for (tasks, projects, objectives) and the XP that makes, the
-- priority and importance multipliers, how XP counts for areas (area XP,
-- Mastery) and for the season (season XP), the completion bonuses, the
-- Mastery level thresholds in hours and the season tiers. When the cursor
-- is on a task, project or objective, it also shows what that one is worth.
local M = {}

local constants = require("zortex.constants")

local function calc()
	return require("zortex.services.xp.calculator")
end

-- =============================================================================
-- Formatting
-- =============================================================================

--- 0.25 -> "15m", 1.5 -> "1h30m", 20.5 -> "21h", 2500 -> "2,500h"
function M.format_hours(h)
	h = tonumber(h) or 0
	local minutes = math.floor(h * 60 + 0.5)
	if minutes < 60 then
		return minutes .. "m"
	end
	local hours, rest = math.floor(minutes / 60), minutes % 60
	if h >= 10 then
		return M.format_number(math.floor(h + 0.5)) .. "h"
	end
	if rest == 0 then
		return M.format_number(hours) .. "h"
	end
	return string.format("%dh%02dm", hours, rest)
end

--- 2.5 -> "2.5", 1200 -> "1,200"
function M.format_number(n)
	n = tonumber(n) or 0
	local s
	if math.abs(n - math.floor(n + 0.5)) < 0.05 or math.abs(n) >= 100 then
		s = tostring(math.floor(n + 0.5))
	else
		s = string.format("%.1f", n)
	end
	local int, frac = s:match("^(-?%d+)(.*)$")
	int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^(-?),", "%1")
	return int .. frac
end

local function percent(x)
	return M.format_number(x * 100) .. "%"
end

local function times(x)
	return "×" .. M.format_number(x)
end

-- Sizes of a kind, smallest first: { { size, hours } }
local function sorted_sizes(kind)
	local out = {}
	for size, h in pairs((calc().conf().sizes or {})[kind] or {}) do
		local hours = calc().hours(kind, size)
		if hours then
			out[#out + 1] = { size = size, hours = hours }
		end
	end
	table.sort(out, function(a, b)
		if a.hours ~= b.hours then
			return a.hours < b.hours
		end
		return a.size < b.size
	end)
	return out
end

-- =============================================================================
-- Sections
-- =============================================================================

local function size_tables(lines)
	local xph = calc().xp_per_hour()
	local cols = {
		{ title = "Tasks", rows = sorted_sizes("task") },
		{ title = "Projects", rows = sorted_sizes("project") },
		{ title = "Objectives", rows = sorted_sizes("objective") },
	}
	local function cell(size, time, xp)
		return string.format("%-10s%7s%8s", size, time, xp)
	end
	local gap = "   "
	local header, sub = {}, {}
	for _, c in ipairs(cols) do
		header[#header + 1] = string.format("%-25s", c.title)
		sub[#sub + 1] = cell("@size", "time", "XP")
	end
	lines[#lines + 1] = ("  " .. table.concat(header, gap)):gsub("%s+$", "")
	lines[#lines + 1] = "  " .. table.concat(sub, gap)
	local n = 0
	for _, c in ipairs(cols) do
		n = math.max(n, #c.rows)
	end
	for i = 1, n do
		local row = {}
		for _, c in ipairs(cols) do
			local r = c.rows[i]
			row[#row + 1] = r and cell(r.size, M.format_hours(r.hours), M.format_number(r.hours * xph))
				or string.rep(" ", 25)
		end
		lines[#lines + 1] = ("  " .. table.concat(row, gap)):gsub("%s+$", "")
	end
end

local function multiplier_line(label, prefix, map)
	local keys = {}
	for k in pairs(map or {}) do
		if tonumber(k) then
			keys[#keys + 1] = tonumber(k)
		end
	end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = string.format("@%s%d %s", prefix, k, times(map[k]))
	end
	parts[#parts + 1] = "none " .. times((map or {}).default or 1)
	return string.format("  %-12s%s", label, table.concat(parts, "   "))
end

--- The guide's lines and which of them are headings: lines, { [lnum] = true }
function M.lines(context)
	local C = calc()
	local cfg = C.conf()
	local xph = C.xp_per_hour()
	local lines, headings = {}, {}
	local function heading(text)
		if #lines > 0 then
			lines[#lines + 1] = ""
		end
		lines[#lines + 1] = text
		headings[#lines] = true
	end
	local function add(text)
		lines[#lines + 1] = text
	end

	heading("How XP is calibrated")
	add(string.format("  XP is estimated work: %s XP = 1 hour (xp.xp_per_hour).", M.format_number(xph)))
	add("  @size says how long something takes (xp.sizes). Time you track (@spent)")
	add("  is shown next to it, not paid.")
	add("")
	size_tables(lines)
	add("")
	local default_task = constants.DEFAULT_TASK_SIZE
	add(
		string.format(
			"  No @size: a task counts as %s (%s); a project is the sum of its tasks;",
			default_task,
			M.format_hours(C.task_points(nil))
		)
	)
	add(
		string.format(
			"  an objective is the projects its key results link, else md (%s).",
			M.format_hours(C.hours("objective", "md") or 30)
		)
	)
	add("  @xp(n) on a project, key result or objective sets its XP outright.")

	heading("Priority and importance")
	local mods = cfg.modifiers or {}
	add(multiplier_line("Priority", "p", mods.priority_multipliers))
	add(multiplier_line("Importance", "i", mods.importance_multipliers))
	add("  They rank work in the planner and the projects picker; ×1 leaves XP alone")
	add("  (xp.modifiers).")

	local A = require("zortex.services.areas")
	local default = C.default_area_value()
	heading("Area XP (Mastery): every piece of work, for its areas")
	add(string.format("  %s of its XP (xp.area_transfer), to the areas it is linked to:", percent(C.area_transfer())))
	add("    on a key result: the objective's areas, then the project's @area, the task's")
	add("    otherwise:       the task's own @area, then the project's")
	if default then
		add(
			string.format(
				"    no area at all:  @a(%s) (xp.default_area)%s; the daily review asks for one",
				default,
				A.default_area() and "" or " · add that heading to areas.zortex"
			)
		)
	else
		add("    no area at all:  no area XP (xp.default_area = false)")
	end
	if (cfg.area_split or 0.5) ~= 1 then
		add(string.format("  Several areas share it, each %s of the one before (xp.area_split).", percent(cfg.area_split or 0.5)))
	end

	heading("Season XP: work on a key result, for the season")
	local bonus = C.completion_bonus()
	local md = (C.hours("objective", "md") or 30) * xph
	add(string.format("  %s of its XP (xp.season_transfer) when a key result links its project", percent(C.season_transfer())))
	add("  (or a project above it); anything else earns none.")
	add(string.format("  A key result reached:  +%s of its objective's XP, split over its key results", percent(bonus)))
	add(string.format("  An objective @done:    +%s of its XP (bonuses are season XP only)", percent(bonus)))
	add(
		string.format(
			"  So an md objective (%s, %s XP) done through its key results: %s season XP, %s area XP.",
			M.format_hours(C.hours("objective", "md") or 30),
			M.format_number(md),
			M.format_number(md * C.season_transfer() + md * bonus * 2 * C.season_transfer()),
			M.format_number(md * C.area_transfer())
		)
	)

	heading("Mastery levels")
	local store = require("zortex.stores.xp")
	local parts = {}
	for _, level in ipairs({ 2, 3, 5, 10, 15, 20 }) do
		local xp = store.calculate_area_level_xp(level)
		parts[#parts + 1] = string.format("%d: %s", level, M.format_hours(xp / xph))
	end
	add("  Hours of work in an area to reach a level (xp.area.level_curve):")
	add("  " .. table.concat(parts, " · "))
	local bubble = (cfg.area or {}).bubble
	if bubble then
		add(string.format("  A sub-area's XP also counts %s for its parent area.", percent(bubble)))
	end

	heading("Season tiers")
	add("  The season is progress on its objectives, weighted by their XP:")
	local tiers = {}
	for _, t in ipairs(require("zortex.services.xp.season").tiers()) do
		tiers[#tiers + 1] = string.format("%s %s", t.name, percent(t.at))
	end
	add("  " .. (#tiers > 0 and table.concat(tiers, " · ") or "(no tiers configured)"))

	if context and #context > 0 then
		heading("At the cursor")
		for _, l in ipairs(context) do
			add("  " .. l)
		end
	end

	add("")
	add("  Change these with setup({ xp = { ... } }) · :ZortexXPExplain on a project · g overview · q close")
	return lines, headings
end

-- =============================================================================
-- What the thing under the cursor is worth
-- =============================================================================

local function with_mods(xp, attrs)
	local m = calc().modifier(attrs)
	if m == 1 then
		return M.format_number(xp) .. " XP"
	end
	return string.format("%s XP %s = %s XP", M.format_number(xp), times(m), M.format_number(xp * m))
end

--- Lines describing the task, project and objective at (bufnr, lnum)
function M.context(bufnr, lnum)
	local C = calc()
	local xph = C.xp_per_hour()
	local out = {}
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""

	local ok_p, project = pcall(function()
		return require("zortex.services.projects").at(bufnr, lnum)
	end)
	project = ok_p and project or nil

	local task = require("zortex.core.item").task(line)
	if task and require("zortex.services.okr.objective").parse_key_result(line) then
		task = nil -- a key result, described with its objective
	end
	-- the project's view of the task: a group, or a share of one
	local grouped
	if task and project then
		for _, t in ipairs(project:tasks()) do
			if t.lnum == lnum then
				grouped = t
			end
		end
	end
	if task and grouped and grouped.leaf == false then
		local leaves = 0
		local function count(t)
			if #t.children_tasks == 0 then
				leaves = leaves + 1
			end
			for _, c in ipairs(t.children_tasks) do
				count(c)
			end
		end
		count(grouped)
		out[#out + 1] = string.format(
			"Group (%s): %s over its %d tasks, %d open; it is paid through them",
			task.attributes.size and ("@" .. task.attributes.size) or "no @size: the sum of its tasks",
			M.format_hours(grouped.hours),
			leaves,
			grouped.open_leaves
		)
	elseif task then
		local size = task.attributes.size
		local h = (grouped and grouped.hours) or C.task_points(size)
		local label = size and ("@" .. size) or ("no @size: " .. constants.DEFAULT_TASK_SIZE)
		if grouped and grouped.parent_task then
			label = "a share of " .. grouped.parent_task.text
		end
		out[#out + 1] = string.format(
			"Task (%s): %s → %s",
			label,
			M.format_hours(h),
			with_mods(h * xph, (grouped and grouped.xp_attrs) or task.attributes)
		)
		if project then
			out[#out + 1] = "  as a project task it is paid from the project's pool, on its curve"
		end
	end

	if project then
		local attrs = project.attributes or {}
		local pool = C.calculate_project_total_xp(project, project:leaf_tasks())
		local how
		if tonumber(attrs.xp) then
			how = "@xp"
		elseif C.project_points(attrs.size) then
			how = string.format("@%s: %s", attrs.size, M.format_hours(C.project_points(attrs.size)))
		else
			how = "sum of its tasks"
		end
		out[#out + 1] = string.format(
			"Project %s: %s XP, %s of estimated work (%s)",
			project.name or project.key,
			M.format_number(pool),
			M.format_hours(pool / xph),
			how
		)
		local ok_k, krs = pcall(function()
			return require("zortex.services.projects.relations").key_results(project, { inherit = true })
		end)
		local linked = ok_k and krs and #krs > 0
		local A = require("zortex.services.areas")
		local has_areas = project.areas and #A.chosen(project:areas({ inherit = true })) > 0
		local area_text = has_areas and string.format("area XP %s to its areas", times(C.area_transfer()))
			or (C.default_area_value() and string.format("no @a: area XP to @a(%s) until it gets one", C.default_area_value()) or "no @a: no area XP")
		if linked then
			out[#out + 1] = string.format("  linked from a key result: season XP %s · %s", times(C.season_transfer()), area_text)
		else
			out[#out + 1] = string.format("  no key result: no season XP · %s", area_text)
		end
	end

	local ok_o, entity = pcall(function()
		return require("zortex.services.okr").at(bufnr, lnum)
	end)
	local o = ok_o and entity or nil
	while o and not o.is_objective do
		o = o.parent
	end
	if o then
		local h, how = C.objective_hours(o)
		local source = how == "size" and ("@" .. o.attributes.size)
			or how == "projects" and "its key results' projects"
			or "no @size: md"
		out[#out + 1] = string.format(
			"Objective %s: %s (%s) → %s XP · %s done",
			o.title or o.name,
			M.format_hours(h),
			source,
			M.format_number(C.objective_value(o)),
			percent(o:progress())
		)
		out[#out + 1] = string.format(
			"  bonuses: %s XP per key result, %s XP when @done",
			M.format_number(C.objective_value(o) * C.completion_bonus() / math.max(1, #o.key_results)),
			M.format_number(C.calculate_objective_xp(o))
		)
	end
	return out
end

-- =============================================================================
-- Popup
-- =============================================================================

function M.show()
	local src_buf = vim.api.nvim_get_current_buf()
	local context = {}
	if vim.bo[src_buf].filetype == "zortex" then
		local ok, ctx = pcall(M.context, src_buf, vim.api.nvim_win_get_cursor(0)[1])
		context = ok and ctx or {}
	end
	local lines, headings = M.lines(context)

	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	width = math.min(width + 2, vim.o.columns - 4)
	local height = math.min(#lines, vim.o.lines - 4)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	local ns = vim.api.nvim_create_namespace("zortex_xp_guide")
	for lnum in pairs(headings) do
		vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { end_col = #lines[lnum], hl_group = "Title" })
	end
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "zortex-xp-guide"

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((vim.o.columns - width) / 2),
		row = math.floor((vim.o.lines - height) / 2),
		style = "minimal",
		border = "rounded",
		title = " XP guide ",
		title_pos = "center",
	})
	vim.wo[win].wrap = false
	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	require("zortex.keys").map(buf, "xp_guide", {
		overview = function()
			close()
			require("zortex.ui.xp").show()
		end,
		close = close,
		help = function()
			require("zortex.ui.keyhelp").show("xp_guide")
		end,
	})
	return buf, win
end

return M
