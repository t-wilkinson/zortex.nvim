-- stores/calendar.lua - Calendar store using entry models
local M = {}

local Logger = require("zortex.core.logger")
local datetime = require("zortex.utils.datetime")
local fs = require("zortex.utils.filesystem")
local CalendarEntry = require("zortex.services.calendar_entry")
local Events = require("zortex.core.event_bus")

-- =============================================================================
-- Store State
--
-- The calendar file is the source of truth. Entries are parsed from the
-- current snapshot of calendar.zortex (core/document: a modified buffer wins
-- over the file) and re-parsed whenever that snapshot changes. Edits are line
-- edits through core/workspace, so the header, notes between entries,
-- ordering and formatting are never rewritten.
-- =============================================================================

local state = {
	entries = {}, -- entries[date_str] = array of CalendarEntry models
	doc = nil, -- snapshot the entries were parsed from
	loaded = false,
	-- calendar feeds (z/feeds/<name>.zortex, written by `zortex serve
	-- -feeds`): feed_entries[date_str] = array of read-only CalendarEntry
	-- models with `feed` (its name) and `file`; feed_docs the snapshots
	feed_entries = {},
	feed_docs = {},
	-- the Repeating section's rules (services/calendar_rules), and the done
	-- copies that stand for an occurrence on another day: for_copies[date][text]
	rules = {},
	for_copies = {},
}

local DEFAULT_HEADER = { "@@Calendar", "@@C", "" }

local function calendar_path()
	return fs.get_calendar_file()
end

local function current_doc()
	local path = calendar_path()
	if not path or not fs.file_exists(path) then
		return nil
	end
	return require("zortex.core.document").get(path)
end

-- =============================================================================
-- Loading
-- =============================================================================

-- The notes of the calendar feeds shown (features.calendar_feeds): the
-- server writes each feed's events into z/feeds/<name>.zortex, tagged
-- @CalendarFeed. false hides every feed, { cozi = false } one of them.
-- { { name, path, doc } } by name.
local function feed_notes()
	local Config = require("zortex.config")
	local setting = Config.features and Config.features.calendar_feeds
	if setting == false or not Config.notes_dir then
		return {}
	end
	local dir = fs.joinpath(Config.notes_dir, "z", "feeds")
	if vim.fn.isdirectory(dir) == 0 then
		return {}
	end
	local out = {}
	for _, path in ipairs(vim.fn.glob(dir .. "/*" .. Config.extension, false, true)) do
		local name = vim.fn.fnamemodify(path, ":t"):sub(1, -#Config.extension - 1)
		if not (type(setting) == "table" and setting[name] == false) then
			local doc = require("zortex.core.document").get(path)
			local marked = false
			for i = 1, math.min(#doc.lines, 5) do
				if doc.lines[i]:match("^%s*@CalendarFeed%s*$") then
					marked = true
					break
				end
			end
			if marked then
				out[#out + 1] = { name = name, path = path, doc = doc }
			end
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

local function load_feeds(notes)
	state.feed_entries, state.feed_docs = {}, {}
	for _, note in ipairs(notes) do
		state.feed_docs[#state.feed_docs + 1] = note.doc
		for date, entries in pairs(M.parse_lines(note.doc.lines, note.doc)) do
			local list = state.feed_entries[date] or {}
			state.feed_entries[date] = list
			for _, entry in ipairs(entries) do
				entry.feed, entry.file = note.name, note.path
				list[#list + 1] = entry
			end
		end
	end
end

local function feeds_changed(notes)
	if #notes ~= #state.feed_docs then
		return true
	end
	for i, note in ipairs(notes) do
		if note.doc ~= state.feed_docs[i] then
			return true
		end
	end
	return false
end

function M.load()
	local doc = current_doc()
	state.doc = doc
	state.entries = doc and M.parse_lines(doc.lines, doc) or {}
	state.rules = doc and require("zortex.services.calendar_rules").rules(doc.lines) or {}
	state.for_copies = {}
	for _, entries in pairs(state.entries) do
		for _, e in ipairs(entries) do
			local for_date = e.raw_text and e.raw_text:match("@for%((%d%d%d%d%-%d%d%-%d%d)%)")
			if for_date then
				state.for_copies[for_date] = state.for_copies[for_date] or {}
				state.for_copies[for_date][e.text or ""] = e
			end
		end
	end
	load_feeds(feed_notes())
	state.loaded = true
	if not doc then
		Logger.warn("calendar.load", "Calendar file not found", { path = calendar_path() })
	end
	return doc ~= nil
end

-- Date blocks in file order: { date, heading_lnum, last_lnum }. A date
-- heading is a bold label "**YYYY-MM-DD:**" (what new days get, so labels
-- such as "Outcomes:" nest under it) or a top-level label "YYYY-MM-DD:";
-- its block runs to the next date heading, and last_lnum is its last
-- non-blank line.
local function date_blocks(doc)
	local blocks = {}
	for _, sec in ipairs(doc.syntax.sections) do
		if sec.type == "bold_heading" or (sec.type == "label" and doc:info(sec.lnum).indent == 0) then
			local date = datetime.date_heading(doc.lines[sec.lnum])
			if date then
				blocks[#blocks + 1] = { date = date, heading_lnum = sec.lnum }
			end
		end
	end
	for i, block in ipairs(blocks) do
		local stop = blocks[i + 1] and (blocks[i + 1].heading_lnum - 1) or #doc.lines
		block.last_lnum = block.heading_lnum
		for lnum = block.heading_lnum + 1, stop do
			if doc.lines[lnum]:match("%S") then
				block.last_lnum = lnum
			end
		end
	end
	return blocks
end

-- "Outcomes:" in a day: what would make the day a success
local OUTCOMES = "^%s*[Oo]utcomes:%s*$"

-- Parse calendar lines into { ["YYYY-MM-DD"] = { CalendarEntry, ... } }.
-- Entries are the list items under each date heading; each records its line
-- in `entry.lnum`. Duplicate date headings merge into one list. The items
-- right under an "Outcomes:" label (up to the first blank line) are the
-- day's outcomes: `entry.outcome` is true.
function M.parse_lines(lines, doc)
	doc = doc or require("zortex.core.document").from_lines(lines)
	local entries = {}
	for _, block in ipairs(date_blocks(doc)) do
		entries[block.date] = entries[block.date] or {}
		local outcomes = false
		for lnum = block.heading_lnum + 1, block.last_lnum do
			local line = doc.lines[lnum]
			if line:match(OUTCOMES) then
				outcomes = true
			elseif not line:match("%S") then
				outcomes = false
			elseif doc:info(lnum).item then
				local entry = CalendarEntry.from_text(line, block.date)
				if entry then
					entry.lnum = lnum
					entry.outcome = outcomes or nil
					table.insert(entries[block.date], entry)
				end
			end
		end
	end
	return entries
end

--- The day's outcomes: the entries under its "Outcomes:" label, in file
--- order.
function M.outcomes(date_str)
	M.ensure_loaded()
	local out = {}
	for _, entry in ipairs(state.entries[date_str] or {}) do
		if entry.outcome then
			out[#out + 1] = entry
		end
	end
	table.sort(out, function(a, b)
		return (a.lnum or 0) < (b.lnum or 0)
	end)
	return out
end

-- Re-parse when the calendar file (or its buffer) changed since last load;
-- the feed notes when one of them changed, came or went.
function M.ensure_loaded()
	if not state.loaded or current_doc() ~= state.doc then
		M.load()
		return
	end
	local notes = feed_notes()
	if feeds_changed(notes) then
		load_feeds(notes)
	end
end

--- The names of the calendar feeds shown, sorted.
function M.feeds()
	M.ensure_loaded()
	local names, seen = {}, {}
	for _, list in pairs(state.feed_entries) do
		for _, entry in ipairs(list) do
			if not seen[entry.feed] then
				seen[entry.feed] = true
				names[#names + 1] = entry.feed
			end
		end
	end
	table.sort(names)
	return names
end

-- =============================================================================
-- Line layout helpers
-- =============================================================================

-- Format a new entry like its siblings (indent and "- " style). Lines without
-- a leading time need "- " to be read as entries.
local function format_entry_line(text, sibling)
	text = vim.trim(text)
	local indent = sibling and sibling:match("^(%s*)") or ""
	local sibling_dash = sibling and sibling:match("^%s*%- ") ~= nil
	local has_dash = text:match("^%- ") ~= nil
	local has_time = text:match("^%d%d?:%d%d") ~= nil
	if not has_dash and (sibling_dash or not has_time) then
		text = "- " .. text
	end
	return indent .. text
end

local function notify_changed(event, payload)
	M.load()
	Events.emit(event, payload)
	local ok, notifications = pcall(require, "zortex.notifications")
	if ok and notifications.calendar then
		vim.defer_fn(function()
			pcall(notifications.calendar.sync, { silent = true })
		end, 100)
	end
end

local function workspace()
	return require("zortex.core.workspace")
end

-- =============================================================================
-- Single Entry Management (line edits)
-- =============================================================================

--- The block of `date_str` in `lines` (default: the current calendar):
--- { date, heading_lnum, last_lnum } or nil. last_lnum is the day's last
--- non-blank line.
function M.date_block(date_str, lines)
	lines = lines or workspace().get_lines(calendar_path())
	for _, b in ipairs(date_blocks(require("zortex.core.document").from_lines(lines))) do
		if b.date == date_str then
			return b
		end
	end
	return nil
end

--- Make sure `date_str` has a heading in the calendar, creating it in date
--- order with `lines` (a day template) under it. Returns the heading's line
--- number and whether it was created.
local function day_number(date_str)
	local y, m, d = date_str:match("^(%d+)%-(%d+)%-(%d+)$")
	return math.floor(os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) / 86400)
end

--- Line a new "YYYY-MM-DD:" block goes before (#lines + 1: append). Dates
--- compare as dates. With no later day in the file the new day goes at the
--- bottom; otherwise next to its nearest neighbour in time: right after the
--- closest earlier day, or right before the closest later day when that one
--- is nearer. So a stray block elsewhere in the file (a far-future
--- appointment near the top) doesn't pull today away from yesterday.
function M.insertion_line(blocks, date_str, lines)
	local target = day_number(date_str)
	local before_i, before_n, after_i, after_n
	for i, b in ipairs(blocks) do
		local n = day_number(b.date)
		if n < target and (not before_n or n >= before_n) then
			before_i, before_n = i, n
		elseif n > target and (not after_n or n < after_n) then
			after_i, after_n = i, n
		end
	end
	if not after_i then
		return #lines + 1
	end
	local use_before = before_i and (target - before_n) <= (after_n - target)
	if use_before then
		local next_block = blocks[before_i + 1]
		return next_block and next_block.heading_lnum or (#lines + 1)
	end
	if after_i then
		return blocks[after_i].heading_lnum
	end
	return #lines + 1
end

function M.ensure_date(date_str, lines)
	local date = datetime.parse_date(date_str)
	if not date then
		return nil, "Invalid date format"
	end
	date_str = datetime.format_datetime(date, "YYYY-MM-DD")
	local path = workspace().ensure_file(calendar_path(), DEFAULT_HEADER)
	local current = workspace().get_lines(path)
	local blocks = date_blocks(require("zortex.core.document").from_lines(current))
	for _, b in ipairs(blocks) do
		if b.date == date_str then
			return b.heading_lnum, false
		end
	end

	local new_lines = { datetime.date_heading_line(date_str) }
	vim.list_extend(new_lines, lines or {})
	new_lines[#new_lines + 1] = ""
	local insert_at = M.insertion_line(blocks, date_str, current)
	if insert_at > #current then
		insert_at = #current + 1
		if #current > 0 and current[#current]:match("%S") then
			table.insert(new_lines, 1, "")
		end
		table.remove(new_lines) -- no trailing blank at the end of the file
	elseif insert_at > 1 and current[insert_at - 1]:match("%S") then
		table.insert(new_lines, 1, "") -- after a block whose last line isn't blank
	end
	local ok, err = workspace().insert_lines(path, insert_at, new_lines)
	if not ok then
		return nil, err
	end
	notify_changed("calendar:entry_added", { date = date_str })
	return insert_at + (new_lines[1] == "" and 1 or 0), true
end

-- Add an entry under its date heading, creating the heading (in date order)
-- if needed. The entry is formatted like the other entries of that date.
function M.add_entry(date_str, entry_text)
	local date = datetime.parse_date(date_str)
	if not date then
		return nil, "Invalid date format"
	end
	date_str = datetime.format_datetime(date, "YYYY-MM-DD")
	if not CalendarEntry.from_text(format_entry_line(entry_text), date_str) then
		return nil, "Not a valid calendar entry: " .. entry_text
	end

	local path = workspace().ensure_file(calendar_path(), DEFAULT_HEADER)
	local lines = workspace().get_lines(path)
	local blocks = date_blocks(require("zortex.core.document").from_lines(lines))

	local ok, err
	local block
	for _, b in ipairs(blocks) do
		if b.date == date_str then
			block = b
			break
		end
	end

	if block then
		local sibling = block.last_lnum > block.heading_lnum and lines[block.last_lnum] or nil
		ok, err = workspace().insert_lines(path, block.last_lnum + 1, { format_entry_line(entry_text, sibling) })
	else
		-- New date: after the closest earlier date (see insertion_line)
		local new_lines = { datetime.date_heading_line(date_str), format_entry_line(entry_text), "" }
		local insert_at = M.insertion_line(blocks, date_str, lines)
		if insert_at > #lines then
			insert_at = #lines + 1
			if #lines > 0 and lines[#lines]:match("%S") then
				table.insert(new_lines, 1, "")
			end
			table.remove(new_lines) -- no trailing blank at end of file
		elseif insert_at > 1 and lines[insert_at - 1]:match("%S") then
			table.insert(new_lines, 1, "")
		end
		ok, err = workspace().insert_lines(path, insert_at, new_lines)
	end

	if not ok then
		return nil, err or "Failed to add entry"
	end

	-- Return the freshly parsed entry
	notify_changed("calendar:entry_added", { date = date_str })
	local added
	for _, entry in ipairs(state.entries[date_str] or {}) do
		if not added or entry.lnum > added.lnum then
			added = entry
		end
	end
	return added
end

-- Line of an entry in the current file (verifies the recorded lnum).
local function locate(entry)
	local lines = workspace().get_lines(calendar_path())
	if entry.lnum and lines[entry.lnum] == entry.raw_text then
		return entry.lnum
	end
	for lnum, line in ipairs(lines) do
		if line == entry.raw_text then
			return lnum
		end
	end
	return nil
end

-- Delete one entry (a CalendarEntry from this store). Its date heading stays.
-- A feed's entries are read-only.
function M.delete_entry(entry)
	if entry and entry.feed then
		return false, "Calendar feed entries are read-only"
	end
	local lnum = entry and locate(entry)
	if not lnum then
		return false, "Entry not found in calendar"
	end
	local ok, err = workspace().delete_lines(calendar_path(), lnum)
	if not ok then
		return false, err
	end
	notify_changed("calendar:entry_removed", { date = entry.date_context, entry = entry })
	return true
end

-- Replace an entry's text, keeping the line's indentation and "- " style.
function M.update_entry(date_str, old_text, new_text)
	M.ensure_loaded()
	for _, entry in ipairs(state.entries[date_str] or {}) do
		if entry.raw_text == old_text then
			local lnum = locate(entry)
			if not lnum then
				return false
			end
			local ok = workspace().set_line(calendar_path(), lnum, format_entry_line(new_text, entry.raw_text))
			if ok then
				notify_changed("calendar:entry_updated", { date = date_str })
			end
			return ok
		end
	end
	return false
end

-- =============================================================================
-- Templates and repeating entries (the top of the calendar note)
-- =============================================================================

--- The lines a new day `date_str` starts with: the calendar's # Templates
--- (services/calendar_rules.template).
function M.template(date_str)
	local lines = workspace().get_lines(calendar_path())
	return require("zortex.services.calendar_rules").template(lines, date_str)
end

--- The rules of the calendar's # Repeating section.
function M.rules()
	M.ensure_loaded()
	return state.rules
end

--- The entries the repeating rules put on `date_str`: an entry per rule
--- that lands on it, with `rule` (its line in the Repeating section) and
--- `rule_lnum`, no `lnum` (it isn't written on the day). A task done on its
--- own day (a copy on the day) shows as that copy instead; one done another
--- day (a copy with @for(date_str)) has the copy's state and `copy`.
function M.occurrences(date_str)
	M.ensure_loaded()
	local rules_mod = require("zortex.services.calendar_rules")
	local out = {}
	for _, rule in ipairs(state.rules) do
		if rules_mod.matches(rule, date_str) then
			local e = CalendarEntry.from_text(rules_mod.plain_line(rule.line), date_str)
			if e then
				local own
				for _, x in ipairs(state.entries[date_str] or {}) do
					if x.text == e.text and not (x.raw_text or ""):match("@for%(") then
						own = x
					end
				end
				if not own then
					e.rule, e.rule_lnum, e.lnum = rule, rule.lnum, nil
					e.file = calendar_path()
					local copy = (state.for_copies[date_str] or {})[e.text or ""]
					if copy then
						e.copy, e.completed, e.mark = copy, copy.completed, copy.mark
					elseif e.type == "task" then
						e.completed, e.mark = false, " "
					end
					e.text = rules_mod.label(rule, e.text or "", date_str)
					out[#out + 1] = e
				end
			end
		end
	end
	return out
end

--- Write the repeating tasks due on `date_str` into its day (made from its
--- template when missing), at the end of the day: the rule's line without
--- its rule attributes, so the copy stands for the occurrence. Tasks already
--- on the day (or done for it on another day, @for) are skipped. Returns how
--- many were added.
function M.add_repeating_tasks(date_str)
	local rules_mod = require("zortex.services.calendar_rules")
	local function due()
		local add = {}
		for _, occ in ipairs(M.occurrences(date_str)) do
			if occ.type == "task" and not occ.copy then
				add[#add + 1] = rules_mod.plain_line(occ.rule.line)
			end
		end
		return add
	end
	if #due() == 0 then
		return 0
	end
	-- the day first: its template may already hold some of them
	local heading, err = M.ensure_date(date_str, M.template(date_str))
	if not heading then
		return 0, err
	end
	M.ensure_loaded()
	local add = due()
	if #add == 0 then
		return 0
	end
	local block = M.date_block(date_str)
	if not block then
		return 0, "no day " .. date_str
	end
	local ok, ins_err = workspace().insert_lines(calendar_path(), block.last_lnum + 1, add)
	if not ok then
		return 0, ins_err
	end
	notify_changed("calendar:entry_added", { date = date_str })
	return #add
end

--- Tick a repeating task's occurrence (M.occurrences): its copy is ticked
--- when it has one, else the task goes, done, into the day `today` (made
--- from its template when new) with @for(date) when it was due another day.
--- Returns true, or nil and an error.
function M.complete_occurrence(occ, today)
	today = today or os.date("%Y-%m-%d")
	if occ.copy then
		local lnum = locate(occ.copy)
		if not lnum then
			return nil, "its copy moved"
		end
		local ok, err = require("zortex.services.tasks").toggle_at(calendar_path(), lnum)
		M.load()
		return ok and true or nil, err
	end
	if occ.type ~= "task" then
		return nil, "not a task"
	end
	local line = require("zortex.services.calendar_rules").done_copy(occ.rule, occ.date_context, today)
	if not line then
		return nil, "can't make a task of it"
	end
	local heading, err = M.ensure_date(today, M.template(today))
	if not heading then
		return nil, err
	end
	-- at the end of the day, at its top level (not under its last block)
	local block = M.date_block(today)
	if not block then
		return nil, "no day " .. today
	end
	local ok, add_err = workspace().insert_lines(calendar_path(), block.last_lnum + 1, { line })
	if not ok then
		return nil, add_err
	end
	notify_changed("calendar:entry_added", { date = today })
	return true
end

-- =============================================================================
-- Entries Management
-- =============================================================================

--- The entries active on `date_str`, by priority: the calendar's own and
--- the calendar feeds' (with `entry.feed`; opts.feeds = false leaves them
--- out).
function M.get_entries_for_date(date_str, opts)
	M.ensure_loaded()

	local active_entries = {}
	local seen = {} -- Track processed entries by a unique key

	-- Check all entries to see if they're active on this date
	for entry_date_str, entries in pairs(state.entries) do
		for _, entry in ipairs(entries) do
			-- Create a unique key for this entry
			local entry_key = entry_date_str .. ":" .. entry.raw_text

			if not seen[entry_key] and entry:is_active_on_date(date_str) then
				table.insert(active_entries, entry)
				seen[entry_key] = true
			end
		end
	end
	-- feeds write each occurrence on its own day
	if not (opts and opts.feeds == false) then
		for _, entry in ipairs(state.feed_entries[date_str] or {}) do
			active_entries[#active_entries + 1] = entry
		end
	end
	-- the # Repeating rules that land on it
	for _, entry in ipairs(M.occurrences(date_str)) do
		active_entries[#active_entries + 1] = entry
	end

	-- Sort by priority
	table.sort(active_entries, function(a, b)
		return a:get_sort_priority() > b:get_sort_priority()
	end)

	return active_entries
end

--- The entries shown on `date_str` in the calendar's own layout: entries
--- from other days that reach it (repeats, ranges over several days) first,
--- by time, then the day's lines in file order. Each gets `depth`: its
--- nesting under the day (0 for the day's top-level lines), so a task under
--- its project's block stays under it.
function M.get_day_entries(date_str)
	local own, other, feed = {}, {}, {}
	for _, entry in ipairs(M.get_entries_for_date(date_str)) do
		if entry.feed or entry.rule then
			feed[#feed + 1] = entry
		elseif entry.date_context == date_str and entry.lnum then
			own[#own + 1] = entry
		else
			other[#other + 1] = entry
		end
	end
	table.sort(own, function(a, b)
		return a.lnum < b.lnum
	end)
	table.sort(other, function(a, b)
		return a:get_sort_priority() > b:get_sort_priority()
	end)
	local out = {}
	for _, e in ipairs(other) do
		e.depth = 0
		out[#out + 1] = e
	end
	out = vim.list_extend(out, M.day_layout(own))
	-- feeds in their note's order, then the repeating rules in theirs
	table.sort(feed, function(a, b)
		if (a.rule == nil) ~= (b.rule == nil) then
			return a.rule == nil
		end
		return (a.lnum or a.rule_lnum or 0) < (b.lnum or b.rule_lnum or 0)
	end)
	for _, e in ipairs(feed) do
		e.depth = 0
		M.insert_by_time(out, e)
	end
	return out
end

--- Put a calendar feed's entry among a day's entries: before the first
--- top-level entry that starts later (an all-day one before the first timed
--- one, after the other feeds' all-day ones). As the web's insertByTime.
function M.insert_by_time(list, e)
	local time = e:get_time_string()
	local at = #list + 1
	for i, x in ipairs(list) do
		local xt = x:get_time_string()
		if (x.depth or 0) == 0 and not (x.feed and not time and not xt) then
			if (not time and xt) or (time and xt and xt > time) then
				at = i
				break
			end
		end
	end
	table.insert(list, at, e)
	return list
end

--- A day's own entries in file order, each with `depth`: the rank of its
--- indent among the day's indents (0 for the day's top-level lines), so a
--- task under its project's block stays under it. The web calendar
--- (app/web calendarDays) lays days out the same way
--- (tests/fixtures/calendar.json).
function M.day_layout(own)
	own = vim.list_slice(own)
	table.sort(own, function(a, b)
		return a.lnum < b.lnum
	end)
	local levels, seen = {}, {}
	for _, e in ipairs(own) do
		local w = e.indent or 0
		if not seen[w] then
			seen[w] = true
			levels[#levels + 1] = w
		end
	end
	table.sort(levels)
	local rank = {}
	for i, w in ipairs(levels) do
		rank[w] = i - 1
	end
	for _, e in ipairs(own) do
		e.depth = rank[e.indent or 0] or 0
	end
	return own
end

-- Get all entries (for search/telescope): the calendar's own, and with
-- opts.feeds the calendar feeds' too.
function M.get_all_entries(opts)
	M.ensure_loaded()

	local all_entries = {}
	local sources = { state.entries }
	if opts and opts.feeds then
		sources[2] = state.feed_entries
	end
	for _, source in ipairs(sources) do
		for date_str, entries in pairs(source) do
			for _, entry in ipairs(entries) do
				table.insert(all_entries, {
					date = date_str,
					entry = entry,
				})
			end
		end
	end

	return all_entries
end

return M
