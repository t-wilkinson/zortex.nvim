Looking at your codebase, I'll help you create the models and stores, and provide suggestions for improvements. Let me address each requirement:

## 1. Calendar Entry Model

Create `models/calendar_entry.lua`:

```lua
-- models/calendar_entry.lua - Calendar entry model
local M = {}
local M_mt = { __index = M }

local datetime = require("zortex.core.datetime")
local parser = require("zortex.core.parser")
local attributes = require("zortex.core.attributes")

-- =============================================================================
-- Calendar Entry Creation
-- =============================================================================

function M:new(data)
	local entry = {
		raw_text = data.raw_text or "",
		display_text = data.display_text or data.raw_text or "",
		date_context = data.date_context, -- The date this entry belongs to
		type = data.type or "note", -- note, event, task
		attributes = data.attributes or {},
		task_status = data.task_status,
		-- Computed fields
		time = nil, -- Extracted from attributes.at
		duration = nil, -- From attributes.dur or est
		date_range = nil, -- From attributes.from/to
	}

	setmetatable(entry, M_mt)
	entry:_compute_fields()
	return entry
end

-- Parse a calendar entry from text
function M.from_text(entry_text, date_context)
	local data = {
		raw_text = entry_text,
		date_context = date_context,
	}

	local working_text = entry_text

	-- Check for task status
	if parser.is_task_line("- " .. working_text) then
		data.task_status = parser.parse_task_status("- " .. working_text)
		if data.task_status then
			data.type = "task"
			-- Strip the checkbox pattern
			working_text = working_text:match("^%[.%]%s+(.+)$") or working_text
		end
	end

	-- Parse attributes
	local attrs, remaining_text = parser.parse_attributes(working_text, attributes.schemas.calendar_entry)
	data.attributes = attrs or {}
	data.display_text = remaining_text

	-- Determine type based on attributes if not already a task
	if data.type ~= "task" then
		if attrs.from or attrs.to or attrs.at then
			data.type = "event"
		end
	end

	return M:new(data)
end

-- =============================================================================
-- Entry Methods
-- =============================================================================

function M:_compute_fields()
	-- Extract time
	if self.attributes.at then
		self.time = datetime.parse_time(self.attributes.at)
	end

	-- Extract duration
	self.duration = self.attributes.dur or self.attributes.est

	-- Extract date range
	if self.attributes.from or self.attributes.to then
		self.date_range = {
			from = self.attributes.from,
			to = self.attributes.to
		}
	end
end

-- Check if entry is active on a given date
function M:is_active_on_date(date)
	local target_date = datetime.parse_date(date)
	if not target_date then return false end

	-- Normalize to noon to avoid DST issues
	target_date.hour, target_date.min, target_date.sec = 12, 0, 0
	local target_time = os.time(target_date)

	-- Check date range
	if self.date_range then
		local in_range = false

		if self.date_range.from and self.date_range.to then
			local from_time = os.time(vim.tbl_extend("force", self.date_range.from, {hour=12, min=0, sec=0}))
			local to_time = os.time(vim.tbl_extend("force", self.date_range.to, {hour=12, min=0, sec=0}))
			in_range = target_time >= from_time and target_time <= to_time
		elseif self.date_range.from then
			local from_time = os.time(vim.tbl_extend("force", self.date_range.from, {hour=12, min=0, sec=0}))
			in_range = target_time >= from_time
		elseif self.date_range.to then
			local to_time = os.time(vim.tbl_extend("force", self.date_range.to, {hour=12, min=0, sec=0}))
			in_range = target_time <= to_time
		end

		if in_range then return true end
	end

	-- Check repeat pattern
	if self.attributes["repeat"] and self.date_context then
		local start_date = datetime.parse_date(self.date_context)
		if start_date then
			return self:is_repeat_active(start_date, target_date)
		end
	end

	-- Default: active only on its own date
	return self.date_context == date
end

-- Check if repeat pattern is active
function M:is_repeat_active(start_date, target_date)
	local repeat_pattern = self.attributes["repeat"]
	if not repeat_pattern then return false end

	-- Normalize dates
	start_date = vim.tbl_extend("force", {}, start_date, {hour=12, min=0, sec=0})
	target_date = vim.tbl_extend("force", {}, target_date, {hour=12, min=0, sec=0})

	local start_time = os.time(start_date)
	local target_time = os.time(target_date)

	if target_time < start_time then return false end

	-- Parse repeat patterns
	if repeat_pattern == "daily" then
		return true
	elseif repeat_pattern == "weekly" then
		local days_diff = math.floor((target_time - start_time) / 86400)
		return days_diff % 7 == 0
	elseif repeat_pattern == "monthly" then
		return target_date.day == start_date.day
	elseif repeat_pattern == "yearly" then
		return target_date.month == start_date.month and target_date.day == start_date.day
	else
		-- Handle patterns like "3d", "2w", "1m"
		local num, unit = repeat_pattern:match("^(%d+)([dwmy])$")
		if num and unit then
			num = tonumber(num)
			local days_diff = math.floor((target_time - start_time) / 86400)

			if unit == "d" then
				return days_diff % num == 0
			elseif unit == "w" then
				return days_diff % (num * 7) == 0
			elseif unit == "m" then
				local month_diff = (target_date.year - start_date.year) * 12 +
								   (target_date.month - start_date.month)
				return month_diff % num == 0 and target_date.day == start_date.day
			elseif unit == "y" then
				local year_diff = target_date.year - start_date.year
				return year_diff % num == 0 and
					   target_date.month == start_date.month and
					   target_date.day == start_date.day
			end
		end
	end

	return false
end

-- Get formatted time string
function M:get_time_string()
	if self.time then
		return string.format("%02d:%02d", self.time.hour, self.time.min)
	elseif self.attributes.at then
		return self.attributes.at
	end
	return nil
end

-- Get sort priority (for ordering entries)
function M:get_sort_priority()
	-- Priority order: notifications > events > incomplete tasks > completed tasks > notes
	local priority = 0

	if self.attributes.notify then
		priority = priority + 1000
	end

	if self.type == "event" then
		priority = priority + 500
	elseif self.type == "task" then
		if self.task_status and self.task_status.key ~= "[x]" then
			priority = priority + 300
		else
			priority = priority + 100
		end
	end

	-- Add time-based priority
	if self.time then
		priority = priority + (24 - self.time.hour) * 10 + (60 - self.time.min) / 6
	end

	return priority
end

return M
```

## 2. Archive Store

Create `stores/archive.lua`:

```lua
-- stores/archive.lua - Archive store for project headings
local M = {}

local BaseStore = require("zortex.stores.base")
local constants = require("zortex.constants")
local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")

-- Create the store instance
local store = BaseStore:new(".archive_cache.json")

-- Override init_empty
function store:init_empty()
	self.data = {
		headings = {}, -- Hierarchical heading structure
		last_updated = nil,
		file_mtime = nil,
	}
	self.loaded = true
end

-- =============================================================================
-- Archive Loading
-- =============================================================================

-- Load and parse the archive file
function M.load()
	local archive_path = fs.get_file_path(constants.FILES.ARCHIVE_PROJECTS)
	if not archive_path or not fs.file_exists(archive_path) then
		return false
	end

	-- Check if we need to reload
	local stat = vim.loop.fs_stat(archive_path)
	local mtime = stat and stat.mtime and stat.mtime.sec or 0

	store:ensure_loaded()

	-- Use cache if file hasn't changed
	if store.data.file_mtime == mtime and store.data.headings then
		return true
	end

	-- Parse the archive file
	local lines = fs.read_lines(archive_path)
	if not lines then
		return false
	end

	-- Build heading structure
	local headings = M._parse_headings(lines)

	-- Update store
	store.data = {
		headings = headings,
		last_updated = os.time(),
		file_mtime = mtime,
		file_path = archive_path,
	}

	store:save()
	return true
end

-- Parse headings into hierarchical structure
function M._parse_headings(lines)
	local headings = []
	local stack = {} -- Stack to track parent headings

	for lnum, line in ipairs(lines) do
		local heading = parser.parse_heading(line)
		if heading then
			-- Strip attributes to get clean text
			local clean_text = parser.parse_attributes(heading.text, {}).text or heading.text

			local heading_info = {
				text = clean_text,
				raw_text = heading.text,
				level = heading.level,
				lnum = lnum,
				children = {},
			}

			-- Find parent in stack
			while #stack > 0 and stack[#stack].level >= heading.level do
				table.remove(stack)
			end

			if #stack > 0 then
				-- Add as child to parent
				table.insert(stack[#stack].children, heading_info)
			else
				-- Top-level heading
				table.insert(headings, heading_info)
			end

			-- Add to stack
			table.insert(stack, heading_info)
		end
	end

	return headings
end

-- =============================================================================
-- Search Functions
-- =============================================================================

-- Search for headings matching a pattern
function M.search_headings(pattern, case_sensitive)
	M.load()

	local results = {}
	local search_pattern = case_sensitive and pattern or pattern:lower()

	local function search_recursive(headings, parent_path)
		for _, heading in ipairs(headings) do
			local search_text = case_sensitive and heading.text or heading.text:lower()

			if search_text:find(search_pattern, 1, true) then
				local path = vim.deepcopy(parent_path or {})
				table.insert(path, heading)

				table.insert(results, {
					heading = heading,
					path = path,
					lnum = heading.lnum,
					text = heading.text,
				})
			end

			-- Search children
			if heading.children and #heading.children > 0 then
				local path = vim.deepcopy(parent_path or {})
				table.insert(path, heading)
				search_recursive(heading.children, path)
			end
		end
	end

	search_recursive(store.data.headings)
	return results
end

-- Get all headings as flat list
function M.get_all_headings()
	M.load()

	local results = {}

	local function flatten_recursive(headings, parent_path)
		for _, heading in ipairs(headings) do
			local path = vim.deepcopy(parent_path or {})
			table.insert(path, heading)

			table.insert(results, {
				heading = heading,
				path = path,
				lnum = heading.lnum,
				text = heading.text,
				level = heading.level,
			})

			if heading.children and #heading.children > 0 then
				flatten_recursive(heading.children, path)
			end
		end
	end

	flatten_recursive(store.data.headings)
	return results
end

-- Get heading at specific line
function M.get_heading_at_line(lnum)
	M.load()

	local function find_recursive(headings)
		for _, heading in ipairs(headings) do
			if heading.lnum == lnum then
				return heading
			end
			if heading.children then
				local found = find_recursive(heading.children)
				if found then return found end
			end
		end
		return nil
	end

	return find_recursive(store.data.headings)
end

-- Force reload
function M.reload()
	store.data.file_mtime = nil
	return M.load()
end

return M
```

## 3. Improved Calendar Store

Replace the existing `stores/calendar.lua` with:

```lua
-- stores/calendar.lua - Calendar store using entry models
local M = {}

local constants = require("zortex.constants")
local datetime = require("zortex.core.datetime")
local fs = require("zortex.core.filesystem")
local CalendarEntry = require("zortex.models.calendar_entry")

-- =============================================================================
-- Store State
-- =============================================================================

local state = {
	entries = {}, -- entries[date_str] = array of CalendarEntry models
	loaded = false,
}

-- =============================================================================
-- Loading and Saving
-- =============================================================================

function M.load()
	local path = fs.get_file_path(constants.FILES.CALENDAR)
	if not path or not fs.file_exists(path) then
		state.loaded = true
		return false
	end

	state.entries = {}
	local lines = fs.read_lines(path)
	if not lines then
		state.loaded = true
		return false
	end

	local current_date_str = nil
	for _, line in ipairs(lines) do
		local m, d, y = line:match(constants.PATTERNS.CALENDAR_DATE_HEADING)
		if m and d and y then
			current_date_str = datetime.format_date({ year = y, month = m, day = d }, "YYYY-MM-DD")
			state.entries[current_date_str] = {}
		elseif current_date_str then
			local entry_text = line:match(constants.PATTERNS.CALENDAR_ENTRY_PREFIX)
			if entry_text then
				local entry = CalendarEntry.from_text(entry_text, current_date_str)
				table.insert(state.entries[current_date_str], entry)
			end
		end
	end

	state.loaded = true
	return true
end

function M.save()
	local path = fs.get_file_path(constants.FILES.CALENDAR)
	if not path then
		return false
	end

	local lines = {}
	local dates = vim.tbl_keys(state.entries)
	table.sort(dates)

	for _, date_str in ipairs(dates) do
		local entries = state.entries[date_str]
		if entries and #entries > 0 then
			local date_tbl = datetime.parse_date(date_str)
			table.insert(lines, datetime.format_date(date_tbl, "MM-DD-YYYY") .. ":")

			-- Sort entries by priority
			table.sort(entries, function(a, b)
				return a:get_sort_priority() > b:get_sort_priority()
			end)

			for _, entry in ipairs(entries) do
				table.insert(lines, "  - " .. entry.raw_text)
			end
			table.insert(lines, "")
		end
	end

	return fs.write_lines(path, lines)
end

function M.ensure_loaded()
	if not state.loaded then
		M.load()
	end
end

-- =============================================================================
-- Entry Management
-- =============================================================================

function M.add_entry(date_str, entry_text)
	M.ensure_loaded()

	if not state.entries[date_str] then
		state.entries[date_str] = {}
	end

	local entry = CalendarEntry.from_text(entry_text, date_str)
	table.insert(state.entries[date_str], entry)

	return M.save()
end

function M.get_entries_for_date(date_str)
	M.ensure_loaded()

	local active_entries = {}
	local seen = {} -- Track processed entries by raw_text

	-- Check all entries to see if they're active on this date
	for entry_date_str, entries in pairs(state.entries) do
		for _, entry in ipairs(entries) do
			if not seen[entry.raw_text] and entry:is_active_on_date(date_str) then
				table.insert(active_entries, entry)
				seen[entry.raw_text] = true
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
		local date_str = datetime.format_date(current, "YYYY-MM-DD")
		local entries = M.get_entries_for_date(date_str)
		if #entries > 0 then
			entries_by_date[date_str] = entries
		end
		current = datetime.add_days(current, 1)
	end

	return entries_by_date
end

-- Update an entry
function M.update_entry(date_str, old_text, new_text)
	M.ensure_loaded()

	local entries = state.entries[date_str]
	if not entries then return false end

	for i, entry in ipairs(entries) do
		if entry.raw_text == old_text then
			entries[i] = CalendarEntry.from_text(new_text, date_str)
			return M.save()
		end
	end

	return false
end

-- Delete an entry
function M.delete_entry(date_str, entry_text)
	M.ensure_loaded()

	local entries = state.entries[date_str]
	if not entries then return false end

	for i, entry in ipairs(entries) do
		if entry.raw_text == entry_text then
			table.remove(entries, i)
			return M.save()
		end
	end

	return false
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
```

## 4. DateTime Improvements

Add these functions to `core/datetime.lua`:

```lua
-- Add to core/datetime.lua

--- Gets the day of week name abbreviated.
-- @param wday number Day of week (1-7, Sunday is 1)
-- @return string Abbreviated day name
function M.get_day_abbrev(wday)
	local days = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
	return days[wday] or ""
end

--- Gets the month name abbreviated.
-- @param month number Month (1-12)
-- @return string Abbreviated month name
function M.get_month_abbrev(month)
	local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
	                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
	return months[month] or ""
end

--- Gets the first weekday of a month.
-- @param year number The year
-- @param month number The month (1-12)
-- @return number Day of week (1-7, Sunday is 1)
function M.get_first_weekday(year, month)
	local time = os.time({ year = year, month = month, day = 1 })
	return os.date("*t", time).wday
end

--- Formats a month and year.
-- @param date table Date with year and month
-- @return string Formatted string like "January 2024"
function M.format_month_year(date)
	return string.format("%s %d", M.get_month_name(date.month), date.year)
end

--- Normalizes a date to noon (for consistent date comparisons).
-- @param date table Date to normalize
-- @return table New date table with time set to noon
function M.normalize_date(date)
	return vim.tbl_extend("force", {}, date, {
		hour = 12,
		min = 0,
		sec = 0
	})
end

--- Checks if two dates are the same day.
-- @param date1 table First date
-- @param date2 table Second date
-- @return boolean True if same day
function M.is_same_day(date1, date2)
	return date1.year == date2.year and
	       date1.month == date2.month and
	       date1.day == date2.day
end
```

## 5. UI Calendar Updates

In `ui/calendar.lua`, remove the DateUtil section and update imports at the top:

```lua
-- At the top of ui/calendar.lua, update imports:
local datetime = require("zortex.core.datetime")
local calendar_store = require("zortex.stores.calendar")

-- Remove the entire DateUtil section and replace all DateUtil calls with datetime calls:
-- DateUtil.get_current_date() → datetime.get_current_date()
-- DateUtil.format_date() → datetime.format_date()
-- DateUtil.add_days() → datetime.add_days()
-- etc.
```

Also update the calendar entry handling to use the new store:

```lua
-- In Renderer.render_month_view, replace the calendar loading section:
-- Load calendar data
calendar_store.load()

-- And replace the entry retrieval:
local entries = calendar_store.get_entries_for_date(date_str)

-- Update the format_entry functions to work with CalendarEntry models:
function M.format_entry(entry)
	if not entry.attributes then
		return ""
	end

	local parts = {}

	-- Time display
	local time_str = entry:get_time_string()
	if time_str then
		table.insert(parts, cfg.pretty_attributes and ("🕐 " .. time_str) or time_str)
	end

	-- Continue with rest of formatting...
end
```

## 6. About `core/search.lua`

The `core/search.lua` file serves a specific purpose - it's a **link resolver** for Zortex's internal linking system. It's not really about general search, but about:

1. Resolving Zortex link syntax (e.g., `[article/heading/label]`)
2. Finding link targets in files
3. Supporting hierarchical navigation

**Recommendation**: Rename it to `core/link_resolver.lua` or `core/resolver.lua` to better reflect its purpose. This would make the architecture clearer.

## 7. Architecture Improvements

### Suggested File Moves:

1. Move `ui/search_managers.lua` → `modules/search_managers.lua` (it's not UI code)
2. Move `ui/search.lua` → `modules/search.lua` (the actual search logic)

### Code Consolidation Opportunities:

1. **Attribute Parsing**: The calendar attributes could use the centralized attribute parser better
2. **Date/Time Handling**: Now consolidated in `core/datetime.lua`
3. **Section Parsing**: Already well-consolidated in `core/parser.lua`

### Future Features to Consider:

1. **Calendar Sync**:

   - Export to iCal format
   - Import from external calendars
   - Two-way sync with Google Calendar

2. **Advanced Search**:

   - Full-text search with ranking
   - Search within date ranges
   - Tag-based filtering

3. **Task Dependencies**:

   - Visual dependency graph
   - Critical path analysis
   - Automatic scheduling

4. **Templates System**:

   - Daily/weekly/monthly templates
   - Project templates
   - Custom entry templates

5. **Analytics Dashboard**:
   - Time tracking visualization
   - Progress trends
   - XP/skill progression charts

- Clearer naming for components based on their actual purpose
