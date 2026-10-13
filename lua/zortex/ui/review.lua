-- ui/review.lua - The daily and weekly review buffers
--
-- :ZortexReview [day|week|N] renders services/agenda.review() into a read-only,
-- Zortex-highlighted scratch buffer (zortex://review). Every finding links to
-- its project, area or objective, so gx / K (preview) work as in any note.
--
--   <CR>   jump to the finding's source line (task, calendar entry, heading)
--   gx     follow the link on the line
--   K      preview the link on the line
--   r      refresh (re-reads the notes)
--   q      close
--
-- render(review) is pure: it returns the lines and a line -> location map,
-- so other front ends (the digest, an app) can reuse the same layout.
local M = {}

local BUF_NAME = "zortex://review"

local state = { bufnr = nil, days = 7, scope = "week", locations = {} }

local function rel(path)
	local dir = require("zortex.config").notes_dir or ""
	if dir ~= "" and path:sub(1, #dir) == dir then
		return path:sub(#dir + 1):gsub("^/", "")
	end
	return vim.fn.fnamemodify(path, ":~:.")
end

local function project_summary(p)
	local r = p:rollup()
	local parts = {}
	if r.total > 0 then
		parts[#parts + 1] = string.format("%d/%d done", r.done, r.total)
	end
	if r.points_open > 0 then
		parts[#parts + 1] = string.format("%.3g pts open", r.points_open)
	end
	return #parts > 0 and ("(" .. table.concat(parts, ", ") .. ")") or ""
end

-- One agenda item (overdue / due soon / completed)
local function item_line(item)
	local when = item.date or ""
	if item.time then
		when = when .. " " .. item.time
	end
	local where
	if item.project and item.project.link then
		where = item.project.link
	elseif item.entry then
		where = "(calendar)"
	end
	local line = string.format("- %s %s", when, item.text or "")
	if where then
		line = line .. " " .. where
	end
	local task = item.task
	return line,
		{
			file = item.file or (task and task.file) or (item.project and item.project.file),
			lnum = item.lnum or (task and task.lnum) or (item.project and item.project.lnum),
		}
end

local function entity_line(e, suffix)
	return "- " .. (e.link or e.name) .. (suffix and (" " .. vim.trim(suffix)) or ""), { file = e.file, lnum = e.lnum }
end

--- Lines and line -> { file, lnum } locations for a review.
---@param r table result of agenda.review()
---@param opts { days?: integer }?
---@return string[] lines, table<integer, { file: string, lnum: integer }> locations
function M.render(r, opts)
	opts = opts or {}
	local lines, locations = {}, {}

	local function add(line, loc)
		lines[#lines + 1] = line
		if loc and loc.file and loc.lnum then
			locations[#lines] = loc
		end
	end

	local function section(title, list, fn, empty)
		add("")
		add(string.format("## %s (%d)", title, #list))
		if #list == 0 then
			add(empty or "  nothing")
			return
		end
		for _, x in ipairs(list) do
			add(fn(x))
		end
	end

	local stale = {}
	for _, p in ipairs(r.stale) do
		stale[p] = true
	end
	local unscheduled = vim.tbl_filter(function(p)
		return not stale[p]
	end, r.unscheduled)

	if r.scope == "day" then
		M.render_day(r, add, section)
		return lines, locations
	end

	add("@@Weekly Review")
	add(string.format("Today %s · looking back to %s, ahead to %s", r.today, r.from, r.to))
	add(
		string.format(
			"%d overdue · %d due soon · %d completed · %d stale · %d broken links",
			#r.overdue,
			#r.due_soon,
			#r.completed,
			#r.stale,
			#r.broken_links
		)
	)

	M.render_plan(r, add, section)

	add("")
	add("# Tasks")
	section("Overdue", r.overdue, item_line)
	section("Due soon", r.due_soon, item_line)
	section("Completed", r.completed, item_line)

	add("")
	add("# Projects")
	section("Stale: no calendar time behind or ahead", r.stale, function(p)
		return entity_line(p, project_summary(p))
	end)
	section("Unscheduled: open work, nothing on the calendar ahead", unscheduled, function(p)
		return entity_line(p, project_summary(p))
	end)
	section("No next action", r.no_next_action, function(p)
		return entity_line(p)
	end)

	add("")
	add("# Goals")
	section("Key results without projects", r.krs_without_projects, function(kr)
		local line = "- " .. (kr.id and (kr.id .. ": ") or "") .. (kr.text or "")
		local link = kr.link or (kr.objective and kr.objective.link)
		if link then
			line = line .. " " .. link
		end
		return line, { file = kr.file, lnum = kr.lnum }
	end)
	section("Objectives without key results", r.objectives_without_krs, function(o)
		return entity_line(o)
	end)
	section("Areas without active projects", r.areas_without_projects, function(a)
		return entity_line(a)
	end)
	section("Areas without an objective this period", r.areas_without_objective or {}, function(a)
		return entity_line(a)
	end)
	section("Projects with neither a key result nor an area", r.unaligned or {}, function(p)
		return entity_line(p, project_summary(p))
	end)

	add("")
	add("# Notes")
	section("Broken links", r.broken_links, function(ref)
		return string.format("- %s:%d %s", rel(ref.file), ref.lnum, ref.text or ""),
			{ file = ref.file, lnum = ref.lnum }
	end)

	return lines, locations
end

local function pct(x)
	return string.format("%d%%", math.floor((x or 0) * 100 + 0.5))
end

-- "+60 Mastery XP · 12h of estimated work: 70% on key results, 20% areas only, 10% neither"
local function xp_line(xp)
	if not xp or xp.xp <= 0 then
		return "  no XP in this window"
	end
	local a = xp.by_alignment
	local hours = xp.xp / require("zortex.services.xp.calculator").xp_per_hour()
	return string.format(
		"  +%d Mastery XP · %sh of estimated work: %s on key results, %s areas only, %s neither",
		math.floor(xp.mastery + 0.5),
		(string.format("%.1f", hours):gsub("%.0$", "")),
		pct(a.kr / xp.xp),
		pct(a.area / xp.xp),
		pct(a.none / xp.xp)
	)
end

-- "  Season Q4 2026: 42% of its objectives · Silver · Gold at 70%"
local function season_line(s)
	if not s then
		return nil
	end
	return string.format(
		"  Season %s: %s of its objectives%s%s",
		s.season.name or "",
		pct(s.progress),
		s.tier and (" · " .. s.tier.name) or "",
		s.next_tier and string.format(" · %s at %s", s.next_tier.name, pct(s.next_tier.at)) or ""
	)
end

--- Objectives (most behind first), XP and time: the top of both reviews.
function M.render_plan(r, add, section, opts)
	opts = opts or {}
	local fmt_time = require("zortex.services.time_spent").format
	add("")
	add("# Plan")
	add("")
	add("## XP")
	local sl = season_line(r.season)
	if sl then
		add(sl)
	end
	add(xp_line(r.xp))
	section("Objectives", r.objectives or {}, function(x)
		local o = x.objective
		local line = string.format("- %s %s", o.link or o.name, pct(x.progress))
		if x.expected then
			line = line .. string.format(" (expected %s by now)", pct(x.expected))
		end
		return line, { file = o.file, lnum = o.lnum }
	end, "  no current objectives: plan some in okr.zortex")
	-- the key results of each objective, under it (behind schedule first)
	if #(r.objectives or {}) > 0 and not opts.brief then
		add("")
		add("## Key results")
		for _, x in ipairs(r.objectives) do
			for _, k in ipairs(x.krs) do
				local kr = k.kr
				local status = kr:is_done() and "done" or (k.lag >= 0.05 and (pct(k.lag) .. " behind") or "on track")
				add(
					string.format("- %s: %s %s · %s %s", kr.id, kr.text or "", pct(k.progress), status, kr.link or ""),
					{ file = kr.file, lnum = kr.lnum }
				)
			end
		end
	end
	if r.time and r.time.minutes > 0 then
		section("Time spent: " .. fmt_time(r.time.minutes), r.time.tasks, function(t)
			return string.format("- %s %s (%s)", fmt_time(t.minutes), t.text or "", t.rel or ""),
				t.file and { file = t.file, lnum = t.lnum }
		end)
	end
end

--- The daily review: what today (or since the last daily review) added up to.
function M.render_day(r, add, section)
	local since = r.from == r.today and "today" or ("since " .. r.from)
	add("@@Daily Review")
	add(string.format("%s · %s", r.today, since))
	local cal = r.calendar or { entries = 0, tasks = 0, done = 0, open = {} }
	add(
		string.format(
			"%d completed · %d of %d calendar tasks done · %d overdue · %d due by tomorrow",
			#r.completed,
			cal.done,
			cal.tasks,
			#r.overdue,
			#r.due_soon
		)
	)
	M.render_plan(r, add, section, { brief = false })
	add("")
	add("# Day")
	section("Completed", r.completed, item_line)
	section("Left on the calendar (put them on another day with :ZortexPlan)", cal.open, item_line)
	section("Overdue", r.overdue, item_line)
	section("Due today and tomorrow", r.due_soon, item_line)
end

-- =============================================================================
-- Buffer
-- =============================================================================

local function jump()
	local loc = state.locations[vim.api.nvim_win_get_cursor(0)[1]]
	if not loc then
		return
	end
	vim.cmd("edit " .. vim.fn.fnameescape(loc.file))
	local last = vim.api.nvim_buf_line_count(0)
	vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(loc.lnum, last)), 0 })
	vim.cmd("normal! zv")
end

local function get_buffer()
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		return state.bufnr
	end
	local buf = vim.fn.bufnr(BUF_NAME)
	if buf == -1 then
		buf = vim.api.nvim_create_buf(true, true)
		vim.api.nvim_buf_set_name(buf, BUF_NAME)
	end
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false

	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	map("<CR>", jump, "Zortex review: jump to source")
	map("gx", function()
		require("zortex.features.links").open_link()
	end, "Zortex review: follow link")
	map("K", function()
		require("zortex.features.preview").preview_link()
	end, "Zortex review: preview link")
	map("r", function()
		M.refresh()
	end, "Zortex review: refresh")
	map("q", function()
		vim.cmd("bdelete")
	end, "Zortex review: close")

	state.bufnr = buf
	return buf
end

--- Re-render the review buffer (if open).
function M.refresh()
	local buf = state.bufnr
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local agenda = require("zortex.services.agenda")
	local r = agenda.review({ days = state.days, today = state.today, scope = state.scope, from = state.from })
	if state.scope == "day" then
		-- refreshing keeps the window; the next day's review starts after it
		state.from = r.from
		agenda.mark_day_reviewed(r.today, r.from)
	end
	local lines, locations = M.render(r)
	state.locations = locations
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	pcall(require("zortex.features.highlights").highlight_buffer, buf)
end

--- Open a review: scope "day" (since the last daily review) or "week"
--- (default: last and next `days`, 7).
---@param opts { days?: integer, today?: string, scope?: "day"|"week" }?
---@return integer bufnr
function M.open(opts)
	opts = opts or {}
	state.days = opts.days or 7
	state.today = opts.today
	state.scope = opts.scope or "week"
	state.from = nil
	local buf = get_buffer()
	vim.api.nvim_set_current_buf(buf)
	M.refresh()
	return buf
end

-- Test hook
function M._state()
	return state
end

return M
