-- services/okr/objective.lua - Objective entities and key results
--
-- Every heading in the OKR article is an entity (so "# Current" is a
-- container). Objectives are either
--   * headings whose text looks like "3M-2026-Q1 Title" (the prefix is the
--     objective's own window), or
--   * the headings directly under a season heading, which names when the
--     season starts: "# 2026-Q4 Season 10 Juniper", "# 2026-10 …",
--     "# 2026-October …", "# 2026-10-20 …". They share the season's window:
--     from its start to the day before the next season heading starts, at
--     most a quarter (Qn) or xp.season.default_length days.
-- Key results are list items directly under an objective:
--   "- KR2: [ ] Make list of habits and routines [P/#1 Personal/#Habits]"
--
-- KR progress is computed from the projects it links to (points done / points
-- across their subtrees); a KR without project links uses its checkbox. A
-- checked KR always counts as done. Objective progress is the mean of its KRs.
local M = {}

local attributes = require("zortex.utils.attributes")
local Item = require("zortex.core.item")
local Entity = require("zortex.core.entity").Entity

local OBJECTIVE_SCHEMA = vim.tbl_extend("force", attributes.schemas.project, {
	created = { type = "date" },
})

-- Objective headings (text with attributes stripped)
local OBJECTIVE = "^(%w+)%-(%d%d%d%d)%-(%w+)%s+(.+)$" -- "3M-2026-Q1 Title"

-- Parse objective heading text -> { span, year, period, title } or nil
function M.parse_objective(text)
	local span, year, period, title = text:match(OBJECTIVE)
	if not span then
		return nil
	end
	return { span = span, year = tonumber(year), period = period, title = title }
end

-- =============================================================================
-- Time windows
-- =============================================================================

local function ymd(y, m, d)
	local t = os.time({ year = y, month = m, day = d, hour = 12 })
	return os.date("%Y-%m-%d", t)
end

-- The last day of the month `months` after (year, month)
local function month_end(year, month, months)
	local m0 = (year * 12 + month - 1) + months -- first month after the window
	return ymd(math.floor(m0 / 12), m0 % 12 + 1, 0) -- day 0: the day before
end

--- The dates an objective covers, from its span and period:
---   3M-2026-Q4  -> 2026-10-01 .. 2026-12-31     (Q1-Q4)
---   6M-2026-H2  -> 2026-07-01 .. 2026-12-31     (H1, H2)
---   1M-2026-03  -> 2026-03-01 .. 2026-03-31     (a month, 01-12 or M3)
---   1Y-2026-Y   -> 2026-01-01 .. 2026-12-31     (anything else: the year)
--- The span sets the length ("3M", "M", "Q", "1Y", "5Y"); the period where
--- it starts. Returns start, end ("YYYY-MM-DD"), or nil.
function M.window(span, year, period)
	year = tonumber(year)
	if not year then
		return nil
	end
	period = tostring(period or "")
	local month, default_len
	local q = period:match("^[Qq](%d)$")
	local h = period:match("^[Hh](%d)$")
	local mm = period:match("^[Mm]?(%d%d?)$")
	if q and tonumber(q) >= 1 and tonumber(q) <= 4 then
		month, default_len = (tonumber(q) - 1) * 3 + 1, 3
	elseif h and (h == "1" or h == "2") then
		month, default_len = h == "1" and 1 or 7, 6
	elseif mm and tonumber(mm) >= 1 and tonumber(mm) <= 12 then
		month, default_len = tonumber(mm), 1
	else
		month, default_len = 1, 12
	end
	span = tostring(span or ""):upper()
	local len
	local n, unit = span:match("^(%d*)([MQYH])$")
	if unit then
		n = tonumber(n) or 1
		len = unit == "M" and n or unit == "Q" and n * 3 or unit == "H" and n * 6 or n * 12
	end
	len = len or default_len
	return ymd(year, month, 1), month_end(year, month, len)
end

-- =============================================================================
-- Season headings
-- =============================================================================

local MONTHS = {
	january = 1, february = 2, march = 3, april = 4, may = 5, june = 6,
	july = 7, august = 8, september = 9, october = 10, november = 11, december = 12,
}

local function add_days(date, days)
	local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)")
	return ymd(tonumber(y), tonumber(m), tonumber(d) + days)
end

local function season_length()
	local xp = require("zortex.config").xp or {}
	return tonumber((xp.season or {}).default_length) or 90
end

--- A season heading's text -> { start, natural_end, token, name } or nil.
--- The text starts with when the season starts: "2026-Q4", "2026-10",
--- "2026-October" (or "2026-Oct"), "2026-10-20"; the rest is its name.
--- natural_end: the quarter's last day for Qn, else start + default_length.
function M.parse_season(text)
	text = vim.trim(text or "")
	local token, rest = text:match("^(%d%d%d%d%-%S+)%s*(.*)$")
	if not token then
		return nil
	end
	local year = tonumber(token:sub(1, 4))
	local tail = token:sub(6)
	local start, natural_end
	local q = tail:match("^[Qq]([1-4])$")
	local mm, dd = tail:match("^(%d%d)%-(%d%d)$")
	local month_only = tail:match("^(%d%d?)$")
	if q then
		start, natural_end = M.window("3M", year, "Q" .. q)
	elseif mm then
		local m, d = tonumber(mm), tonumber(dd)
		if m < 1 or m > 12 or d < 1 or d > 31 then
			return nil
		end
		start = string.format("%04d-%02d-%02d", year, m, d)
	elseif month_only and tonumber(month_only) >= 1 and tonumber(month_only) <= 12 then
		start = string.format("%04d-%02d-01", year, tonumber(month_only))
	else
		local name = tail:lower()
		local m = MONTHS[name]
		if not m and #name >= 3 then
			for full, n in pairs(MONTHS) do
				if full:sub(1, #name) == name then
					m = n
				end
			end
		end
		if not m then
			return nil
		end
		start = string.format("%04d-%02d-01", year, m)
	end
	natural_end = natural_end or add_days(start, season_length() - 1)
	return { start = start, natural_end = natural_end, token = token, name = vim.trim(rest) }
end

--- The season headings of `lines`: { { lnum, level, start, natural_end, name, text } }
function M.season_headings(lines)
	local out = {}
	for lnum, line in ipairs(lines or {}) do
		local hashes, text = line:match("^(#+)%s+(.-)%s*$")
		if hashes then
			local s = M.parse_season(text)
			if s then
				s.lnum, s.level, s.text = lnum, #hashes, text
				out[#out + 1] = s
			end
		end
	end
	return out
end

--- start, end of the season heading at `lnum` of `lines`: it ends the day
--- before the next season heading (of the same level) starts, and at its
--- natural end at the latest.
function M.season_window(lines, lnum)
	local seasons = M.season_headings(lines)
	local this
	for _, s in ipairs(seasons) do
		if s.lnum == lnum then
			this = s
		end
	end
	if not this then
		return nil
	end
	local finish = this.natural_end
	for _, s in ipairs(seasons) do
		if s.level == this.level and s.start > this.start then
			local before = add_days(s.start, -1)
			if before < finish then
				finish = before
			end
		end
	end
	return this.start, finish
end

--- The calendar quarter around `date` ("YYYY-MM-DD"; default today):
--- { name = "2026 Q4", start_date, end_date }
function M.quarter(date)
	date = date or os.date("%Y-%m-%d")
	local y, m = date:match("^(%d%d%d%d)%-(%d%d)")
	y, m = tonumber(y), tonumber(m)
	local q = math.floor((m - 1) / 3) + 1
	local s, e = M.window("3M", y, "Q" .. q)
	return { name = string.format("%d Q%d", y, q), start_date = s, end_date = e }
end

-- Fraction of [start, end] (inclusive days) that has passed by `today`
function M.elapsed(start_date, end_date, today)
	if not start_date or not end_date then
		return nil
	end
	local function t(d)
		local y, mo, da = d:match("^(%d+)%-(%d+)%-(%d+)")
		return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = 12 })
	end
	local s, e, n = t(start_date), t(end_date), t(today or os.date("%Y-%m-%d"))
	local total = (e - s) / 86400 + 1
	local done = (n - s) / 86400 + 1
	return math.max(0, math.min(1, done / total))
end

-- Parse a key result line -> { id, text, completed, links } or nil.
-- A key result is a list item keyed "KRn": "- KR2: [ ] Text [P/...]".
function M.parse_key_result(line)
	local item = Item.from_line(line)
	if not item then
		return nil
	end
	local id = item.key and item.key:match("^KR%d*$") and item.key
	local text, completed = item.text, item.completed
	if id then
		-- Without a checkbox the key is still part of the item text
		text = text:gsub("^" .. id .. ":%s*", "")
	end
	if not id then
		return nil
	end
	return {
		id = id,
		text = text,
		completed = completed,
		has_box = item.mark ~= nil, -- "- KR1: [ ] …": it can be checked when reached
		links = item:links(),
		attributes = attributes.parse_attributes(line, attributes.schemas.project),
	}
end

-- =============================================================================
-- KeyResult
-- =============================================================================

local KeyResult = {}
KeyResult.__index = function(kr, k)
	-- `kr.projects` is computed on access (projects change independently of
	-- the OKR file), keyed by project key.
	if k == "projects" then
		return kr:linked_projects()
	end
	return KeyResult[k]
end
M.KeyResult = KeyResult

-- { [project_key] = Project } for every link on the KR's line that lands in
-- a project (via core/link_index).
function KeyResult:linked_projects()
	local projects = require("zortex.services.projects")
	local out = {}
	for _, ref in ipairs(require("zortex.core.link_index").links_from(self.file)) do
		if ref.lnum == self.lnum and ref.target then
			for _, p in ipairs(projects.for_target(ref.target.file, ref.target.lnum)) do
				out[p.key] = p
			end
		end
	end
	return out
end

-- Linked projects as a list, in key order
function KeyResult:project_list()
	local list = vim.tbl_values(self:linked_projects())
	table.sort(list, function(a, b)
		return a.key < b.key
	end)
	return list
end

-- 0..1: checked => 1; with linked projects => their points done / points;
-- otherwise 0.
function KeyResult:progress()
	if self.completed then
		return 1
	end
	local done, total = 0, 0
	for _, p in ipairs(self:project_list()) do
		local r = p:rollup()
		done, total = done + r.points_done, total + r.points
	end
	if total == 0 then
		return 0
	end
	return done / total
end

function KeyResult:is_done()
	return self.completed or self:progress() >= 1
end

--- Nothing can move it: no project linked and no checkbox to tick.
function KeyResult:is_stuck()
	return not self.completed and not self.has_box and next(self:linked_projects()) == nil
end

--- How far behind schedule (0..1): the share of the objective's window that
--- has passed minus the progress made. 0 when on track, ahead, or the
--- objective has no window.
function KeyResult:lag(today)
	local o = self.objective
	local s, e
	if o then
		s, e = o:window()
	end
	local elapsed = M.elapsed(s, e, today)
	if not elapsed then
		return 0
	end
	return math.max(0, elapsed - self:progress())
end

--- The date the KR was reached: its own @done, else the latest @done among
--- the tasks of its linked projects (when they are all done), else nil.
function KeyResult:done_date()
	if not self:is_done() then
		return nil
	end
	local line = self.objective and self.objective.doc.lines[self.lnum] or ""
	local item = Item.from_line(line)
	local done = item and item.attributes and item.attributes.done
	local date = require("zortex.services.xp.ledger").date_string(done)
	if date then
		return date
	end
	local latest
	for _, p in ipairs(self:project_list()) do
		p:walk(function(x)
			for _, t in ipairs(x:tasks()) do
				local d = t.completed and require("zortex.services.xp.ledger").date_string(t.attributes.done)
				if d and (not latest or d > latest) then
					latest = d
				end
			end
		end)
		local pd = require("zortex.services.xp.ledger").date_string(p.attributes.done)
		if pd and (not latest or pd > latest) then
			latest = pd
		end
	end
	return latest
end

-- =============================================================================
-- Objective
-- =============================================================================

local Objective = Entity:extend()
local base_index = Objective.__index
Objective.__index = function(o, k)
	-- key_results is parsed lazily (child entities are attached after init)
	if k == "key_results" then
		local krs = o:parse_key_results()
		rawset(o, "key_results", krs)
		return krs
	end
	return base_index[k]
end
M.Objective = Objective

function M.init(o)
	o.attributes = attributes.parse_attributes(o.doc.lines[o.lnum] or "", OBJECTIVE_SCHEMA)
	o.attributes.tags = nil
	local info = o.kind == "heading" and M.parse_objective(o.name) or nil
	o.is_objective = info ~= nil
	if info then
		o.span, o.year, o.period, o.title = info.span, info.year, info.period, info.title
		o.id = string.format("%s_%d_%s_%s", info.span, info.year, info.period, (info.title:gsub("[^%w]", "_")))
		o.completed = o.attributes.done ~= nil
		o.section = o.parent and o.parent.name or nil -- e.g. "Current"
		return
	end
	if o.kind ~= "heading" then
		return
	end
	local season = M.parse_season(o.name)
	if season then
		o.is_season = true
		o.season_info = season
	elseif o.parent and o.parent.is_season then
		-- an objective of the season it is under: "# 2026-Q4 Season 10" / "## Title"
		o.is_objective = true
		o.title = o.name
		o.season = o.parent
		o.id = string.format("S_%s_%s", o.parent.season_info.start, (o.name:gsub("[^%w]", "_")))
		o.completed = o.attributes.done ~= nil
		o.section = o.parent.name
	end
end

--- start, end of a season heading entity
function Objective:season_window()
	if not self.is_season then
		return nil
	end
	return M.season_window(self.doc.lines, self.lnum)
end

function Objective:parse_key_results()
	local krs = {}
	if not self.is_objective then
		return krs
	end
	local s, e = self:own_range()
	for lnum = s + 1, e do
		local kr = M.parse_key_result(self.doc.lines[lnum])
		if kr then
			kr.lnum = lnum
			kr.file = self.file
			kr.objective = self
			-- Explicit link to the key result itself: [O/…/-KR1]
			kr.link = self.link and (self.link:sub(1, -2) .. "/-" .. kr.id .. "]") or nil
			krs[#krs + 1] = setmetatable(kr, KeyResult)
		end
	end
	return krs
end

-- Mean KR progress (1 when the objective is marked @done)
function Objective:progress()
	if self.completed then
		return 1
	end
	local krs = self.key_results
	if #krs == 0 then
		return 0
	end
	local sum = 0
	for _, kr in ipairs(krs) do
		sum = sum + kr:progress()
	end
	return sum / #krs
end

--- start, end dates ("YYYY-MM-DD") the objective covers, or nil
function Objective:window()
	if not self.is_objective then
		return nil
	end
	if self.season then
		return self.season:season_window()
	end
	return M.window(self.span, self.year, self.period)
end

-- Areas from @a(...) (services/areas Area objects)
function Objective:areas()
	return require("zortex.services.areas").from_attributes(self.attributes)
end

-- Every project linked from this objective's KRs
function Objective:projects()
	local seen, out = {}, {}
	for _, kr in ipairs(self.key_results) do
		for _, p in ipairs(kr:project_list()) do
			if not seen[p.key] then
				seen[p.key] = true
				out[#out + 1] = p
			end
		end
	end
	return out
end

return M
