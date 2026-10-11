-- stores/calendar.lua - Calendar store using entry models
local M = {}

local Logger = require("zortex.core.logger")
local constants = require("zortex.constants")
local datetime = require("zortex.utils.datetime")
local fs = require("zortex.utils.filesystem")
local CalendarEntry = require("zortex.services.calendar_entry")
local Events = require("zortex.core.event_bus")
local attributes = require("zortex.utils.attributes")

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

function M.load()
	local doc = current_doc()
	state.doc = doc
	state.entries = doc and M.parse_lines(doc.lines, doc) or {}
	state.loaded = true
	if not doc then
		Logger.warn("calendar.load", "Calendar file not found", { path = calendar_path() })
	end
	return doc ~= nil
end

-- Date blocks in file order: { date, heading_lnum, last_lnum }. A date
-- heading is a top-level label "YYYY-MM-DD:"; its block runs to the next date
-- heading, and last_lnum is its last non-blank line.
local function date_blocks(doc)
	local blocks = {}
	for _, sec in ipairs(doc.syntax.sections) do
		if sec.type == "label" and doc:info(sec.lnum).indent == 0 then
			local y, m, d = sec.text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
			if y then
				blocks[#blocks + 1] = { date = string.format("%s-%s-%s", y, m, d), heading_lnum = sec.lnum }
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

-- Parse calendar lines into { ["YYYY-MM-DD"] = { CalendarEntry, ... } }.
-- Entries are the list items under each date heading; each records its line
-- in `entry.lnum`. Duplicate date headings merge into one list.
function M.parse_lines(lines, doc)
	doc = doc or require("zortex.core.document").from_lines(lines)
	local entries = {}
	for _, block in ipairs(date_blocks(doc)) do
		entries[block.date] = entries[block.date] or {}
		for lnum = block.heading_lnum + 1, block.last_lnum do
			if doc:info(lnum).item then
				local entry = CalendarEntry.from_text(doc.lines[lnum], block.date)
				if entry then
					entry.lnum = lnum
					table.insert(entries[block.date], entry)
				end
			end
		end
	end
	return entries
end

-- Re-parse when the calendar file (or its buffer) changed since last load.
function M.ensure_loaded()
	if not state.loaded or current_doc() ~= state.doc then
		M.load()
	end
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
			pcall(notifications.calendar.sync)
		end, 100)
	end
end

local function workspace()
	return require("zortex.core.workspace")
end

-- =============================================================================
-- Single Entry Management (line edits)
-- =============================================================================

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
		-- New date: before the first later date, or at the end of the file
		local new_lines = { date_str .. ":", format_entry_line(entry_text), "" }
		local insert_at
		for _, b in ipairs(blocks) do
			if b.date > date_str then
				insert_at = b.heading_lnum
				break
			end
		end
		if not insert_at then
			insert_at = #lines + 1
			if #lines > 0 and lines[#lines]:match("%S") then
				table.insert(new_lines, 1, "")
			end
			table.remove(new_lines) -- no trailing blank at end of file
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
function M.delete_entry(entry)
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

function M.delete_entry_by_text(date_str, entry_text)
	M.ensure_loaded()
	for _, entry in ipairs(state.entries[date_str] or {}) do
		if entry.raw_text == entry_text then
			return M.delete_entry(entry)
		end
	end
	return false
end

-- Index into get_entries_for_date(date_str): the list the UI shows.
function M.delete_entry_by_index(date_str, entry_index)
	local entries = M.get_entries_for_date(date_str)
	local entry = entries[entry_index]
	if not entry then
		return false, "Invalid entry index"
	end
	return M.delete_entry(entry)
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
-- Entries Management
-- =============================================================================

function M.get_entries_for_date(date_str)
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

	-- Sort by priority
	table.sort(active_entries, function(a, b)
		return a:get_sort_priority() > b:get_sort_priority()
	end)

	return active_entries
end

function M.get_entries_in_range(start_date, end_date)
	M.ensure_loaded()

	local entries_by_date = {}
	local current = datetime.parse_date(start_date)
	local end_time = os.time(datetime.parse_date(end_date))

	while os.time(current) <= end_time do
		local date_str = datetime.format_datetime(current, "YYYY-MM-DD")
		local entries = M.get_entries_for_date(date_str)
		if #entries > 0 then
			entries_by_date[date_str] = entries
		end
		current = datetime.add_days(current, 1)
	end

	return entries_by_date
end

-- Get all entries (for search/telescope)
function M.get_all_entries()
	M.ensure_loaded()

	local all_entries = {}
	for date_str, entries in pairs(state.entries) do
		for _, entry in ipairs(entries) do
			table.insert(all_entries, {
				date = date_str,
				entry = entry,
			})
		end
	end

	return all_entries
end


return M
