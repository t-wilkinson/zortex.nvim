# Project structure

```txt
.
├── api.lua
├── config.lua
├── constants.lua
├── constants2.lua
├── init.lua
├── summarize.sh
├── summary.md
├── core
│   ├── buffer_sync.lua
│   ├── document_manager.lua
│   ├── event_bus.lua
│   ├── init.lua
│   ├── logger.lua
│   ├── performance_monitor.lua
│   └── section.lua
├── features
│   ├── archive.lua
│   ├── completion.lua
│   ├── highlights.lua
│   ├── ical.lua
│   └── links.lua
├── notifications
│   ├── init.lua
│   ├── manager.lua
│   ├── providers
│   │   ├── aws.lua
│   │   ├── base.lua
│   │   ├── ntfy.lua
│   │   ├── ses.lua
│   │   ├── system.lua
│   │   └── vim.lua
│   └── types
│       ├── calendar.lua
│       ├── digest.lua
│       ├── pomodoro.lua
│       └── timer.lua
├── services
│   ├── areas.lua
│   ├── calendar_entry.lua
│   ├── okr.lua
│   ├── search.lua
│   ├── tasks.lua
│   ├── projects
│   │   ├── init.lua
│   │   └── progress.lua
│   ├── search
│   │   ├── document_cache.lua
│   │   ├── hierarchical.lua
│   │   ├── history.lua
│   │   ├── init.lua
│   │   └── scoring.lua
│   └── xp
│       ├── calculator.lua
│       ├── distributor.lua
│       ├── init.lua
│       ├── notifications.lua
│       └── season.lua
├── stores
│   ├── base.lua
│   ├── calendar.lua
│   ├── notifications.lua
│   ├── persistence_manager.lua
│   ├── tasks.lua
│   └── xp.lua
├── tests
│   └── test.lua
├── ui
│   ├── commands.lua
│   ├── keymaps.lua
│   ├── skill_tree.lua
│   ├── calendar
│   │   ├── init.lua
│   │   └── view.lua
│   └── telescope
│       ├── calendar.lua
│       ├── core.lua
│       ├── projects.lua
│       └── search.lua
└── utils
    ├── attributes.lua
    ├── buffer.lua
    ├── datetime.lua
    ├── filesystem.lua
    ├── link_resolver.lua
    └── parser.lua

16 directories, 70 files
```

## ui/keymaps.lua
```lua
function M.setup(key_prefix, cmd_prefix)
```

## ui/skill_tree.lua - Revamped Skill Tree UI for dual progression system
```lua
function M.show()
```

## features/calendar.lua - Calendar features using CalendarService
```lua

-- Add entry with interactive prompt
function M.add_entry_interactive(date_str)

-- Delete entry with confirmation
function M.delete_entry_interactive(date_str)

-- Search calendar entries
function M.search(query)

-- Show calendar statistics
function M.show_stats()

-- Get pending notifications
function M.get_pending_notifications(lookahead_minutes)

-- Check and show notifications
function M.check_notifications()

-- Open calendar file
function M.open_file()

-- Jump to date in calendar file
function M.goto_date(date_str)

-- Initialize calendar features
function M.init()
```

## ui/calendar/view.lua - Calendar UI module for Zortex
```lua
	marks = {}, -- Date marks for navigation
function Renderer.create_buffer()
function Renderer.create_window(bufnr)
function Renderer.center(win_width, text)
function Renderer.render_month_view(date)
	CalendarState.marks = {}
function Renderer.render_digest_view()
function Renderer.apply_highlights(bufnr, highlights)
function Renderer.update_selected_extmark()
function Navigation.move_to_date(date)
function Navigation.next_day()
function Navigation.prev_day()
function Navigation.next_week()
function Navigation.prev_week()
function Navigation.next_month()
function Navigation.prev_month()
function Navigation.next_year()
function Navigation.prev_year()
function Navigation.go_to_today()
function Navigation.select_date_at_cursor()
function Actions.add_entry()
function Actions.view_entries()
function Actions.telescope_search()
function Actions.show_digest()
function Actions.toggle_view()
function Actions.go_to_file()
function Actions.sync_notifications()
function Actions.show_help()
function M.open()
function M.close()
	CalendarState.marks = {}
function M.refresh()
	CalendarState.marks = {}
function M.toggle()
function M.open_digest()
function M.setup(opts)
```

## ui/telescope.lua - Telescope integration for Zortex
```lua
function M.projects(opts)
```

## ui/telescope/search.lua - Search UI using independent document loading
```lua
function M.create_telescope_finder(opts)
function M.search(opts)
			layout_config = {
				flex = { flip_columns = 120 },
				horizontal = { preview_width = 0.6 },
				vertical = { preview_height = 0.4 },
function M.search_sections(opts)
function M.search_articles(opts)
function M.search_tasks(opts)
function M.search_all(opts)
function M.search_current_word()
function M.search_current_section()
function M.show_history()
function M.setup(opts)
```

## =============================================================================
```lua

-- Search calendar entries
function M.search(query, opts)
```

## ui/telescope/core.lua - assimilates telescope searches
```lua
function M.setup()
		exports = {
```

## ui/commands.lua
```lua
function M.setup(prefix)
```

## constants.lua - Centralized constants for Zortex with normalized section hierarchy
```lua

-- File names
M.FILES = {

-- Core patterns
M.PATTERNS = {

-- Section types with hierarchical priorities
-- Lower numbers = higher priority (can contain higher numbers)
M.SECTION_TYPE = {

-- Section hierarchy helper
M.SECTION_HIERARCHY = {

-- Task status definitions
M.TASK_STATUS = {

-- Highlight groups
M.HIGHLIGHTS = {
```

## init.lua - Main entry point for Zortex
```lua
```

## core/buffer_sync.lua - keeps buffer and document in sync
```lua

-- Sync strategies
M.strategies = {

-- Change types
M.change_types = {

-- Queue a change for sync
function M.queue_change(bufnr, change_type, data)

-- Toggle task completion
function M.toggle_task(bufnr, lnum, completed)

-- Update task attributes
function M.update_task(bufnr, lnum, attributes, text)

-- Update line attributes
function M.update_attributes(bufnr, lnum, attributes)

-- Update text lines
function M.update_text(bufnr, start_line, end_line, lines)

-- Force sync for a buffer
function M.sync_buffer(bufnr)

-- Sync all buffers
function M.sync_all()

-- Clear pending changes for a buffer
function M.clear_buffer(bufnr)

-- Get pending changes for a buffer
function M.get_pending_changes(bufnr)

-- Configure sync behavior
function M.setup(opts)

-- Status information
function M.get_status()
```

## core/logger.lua - Performance logging and debugging utilities
```lua

-- Public logging functions
function M.trace(category, message, data)
function M.debug(category, message, data)
function M.info(category, message, data)
function M.warn(category, message, data)
function M.error(category, message, data)
function M.log(category, data)

-- Performance tracking
function M.start_timer(operation_name)
				recent = {},

-- Wrap a function with performance tracking
function M.wrap_function(name, fn)

-- Get performance report
function M.get_performance_report()

-- Show performance report in a buffer
function M.show_performance_report()

-- Get recent log entries
function M.get_recent_logs(count, level_filter)

-- Show logs in buffer
function M.show_logs(count, level_filter)

-- Clear logs
function M.clear_logs()
	log_buffer = {}
	performance_stats = {}

-- Enable/disable logging
function M.enable()
function M.disable()
function M.set_level(level)

-- Configuration
function M.setup(opts)

-- Log levels
M.levels = {

-- Log at different levels
function M.debug(component, message, data)
function M.info(component, message, data)
function M.warn(component, message, data)
function M.error(component, message, data)

-- Generic log function
function M.log(level_name, data)

-- Start a timer
function M.start_timer(name)

-- Stop a timer
function M.stop_timer(timer_id, data)

-- Get log buffer
function M.get_buffer()

-- Clear log buffer
function M.clear_buffer()
	log_buffer = {}

-- Search log buffer
function M.search(pattern)

-- Configure logger
function M.configure(opts)

-- Get configuration
function M.get_config()

-- Show log in new buffer
function M.show_log()

-- Filter log
function M.filter_log(pattern)

-- Get performance statistics
function M.get_performance_stats()

-- Show performance report
function M.show_performance_report()
```

## core/init.lua - Initialize core systems: Events, Doc, and Services
```lua
function M.setup(opts)

-- Get system status
function M.get_status()
		document_manager = {

-- Print status report
function M.print_status()

-- Get service references (for direct access)
function M.get_services()
```

## core/section.lua - first-class representation of document structure
```lua

-- Create a new section
function Section:new(opts)
	section.children = {}
	section.tasks = {}
	section.attributes = {}

-- Get unique identifier for this section
function Section:get_id()

-- Get section priority (for hierarchy comparisons)
function Section:get_priority()

-- Check if this section can contain another section type
function Section:can_contain(other_section)

-- Get the path from root to this section
function Section:get_path()
		self._path = {}

-- Get breadcrumb string
function Section:get_breadcrumb()

-- Check if this section contains a line number
function Section:contains_line(line_num)

-- Add a child section
function Section:add_child(child)

-- Remove a child section
function Section:remove_child(child)

-- Find child section containing line
function Section:find_child_at_line(line_num)

-- Get all descendant sections (depth-first)
function Section:get_descendants()

-- Get all tasks in this section (including descendants)
function Section:get_all_tasks()

-- Update section bounds (after buffer changes)
function Section:update_bounds(start_line, end_line)

-- Get section statistics
function Section:get_stats()

-- Format section for display
function Section:format_display()

-- Build a link to a section
function Section:build_link(doc)
function SectionTreeBuilder:new()
		stack = {},

-- Add a section to the tree
function SectionTreeBuilder:add_section(section)

-- Update the end line of the current section
function SectionTreeBuilder:update_current_end(line_num)

-- Get the built tree
function SectionTreeBuilder:get_tree()

-- Create section from parsed line
function M.create_from_line(line, line_num, in_code_block)
```

## core/document_manager.lua - Document cache and parsing with buffer integration
```lua
function LRU:new(opts)
		items = {},
		order = {},
function LRU:get(key)
function LRU:set(key, value)
function LRU:_touch(key)
function Document:new(opts)
		line_map = {}, -- line_num -> deepest section
		dirty_ranges = {}, -- { {start, end}, ... }
		article_names = {}, -- Array of all article names (@@)
		tags = {},
		stats = {

-- Parse entire document
function Document:parse_full(lines)
	self.article_names = {}
	self.tags = {}
	self.line_map = {}
	self.dirty_ranges = {}

-- Incremental parsing for dirty ranges
function Document:parse_incremental(lines)

-- Update document statistics
function Document:update_stats()

-- Get section at line
function Document:get_section_at_line(line_num)

-- Get task by ID
function Document:get_task(task_id)

-- Update task
function Document:update_task(task_id, updates)

-- Get all tasks
function Document:get_all_tasks()

-- Get primary article name (for compatibility)
function Document:get_article_name()
	buffers = {},
	files = {},
	reparse_timers = {},

-- Load document from buffer
function Doc:load_buffer(bufnr, filepath)

-- Load document from file
function Doc:load_file(filepath)

-- Get document for buffer
function Doc:get_buffer(bufnr)

-- Get document for file
function Doc:get_file(filepath)

-- Mark buffer dirty
function Doc:mark_buffer_dirty(bufnr, start_line, end_line)

-- Reparse buffer
function Doc:reparse_buffer(bufnr)
	doc.dirty_ranges = {}

-- Unload buffer document
function Doc:unload_buffer(bufnr)

-- Reload file document (if file changed)
function Doc:reload_file(filepath)

-- Get all loaded documents
function Doc:get_all_documents()

-- Get a document by filepath without loading into main cache
function Doc:peek_file(filepath)

-- Setup autocmds
function Doc:setup_autocmds()

-- Initialize
function Doc:init()

-- Public API
function M.init()
function M.get_buffer(bufnr)
function M.load_buffer(bufnr)
function M.get_file(filepath)
function M.get_all_documents()
function M.peek_file(filepath)
function M.mark_buffer_dirty(bufnr, start_line, end_line)
```

## core/event_bus.lua - Event system with priority handling and async execution
```lua
function PriorityQueue:new()
function PriorityQueue:push(item, priority)
function PriorityQueue:pop()
function PriorityQueue:is_empty()
	handlers = {}, -- event -> handler_list
	middleware = {}, -- Global processors
	stats = { -- Performance tracking
		events = {}, -- event -> { count, total_time, max_time }

-- Internal: ensure handler list exists
function Events:ensure_handler_list(event)

-- Register an event handler
function Events:on(event, handler, opts)

-- Remove an event handler
function Events:off(event, handler)

-- Emit an event
function Events:emit(event, data, opts)

-- Add middleware
function Events:add_middleware(fn)

-- Track performance statistics
function Events:track_performance(event, elapsed_ms)

-- Get performance report
function Events:get_performance_report()

-- Clear all handlers (useful for tests)
function Events:clear()
	self.handlers = {}
	self.middleware = {}
	self.stats.events = {}

-- Public API
function M.on(event, handler, opts)
function M.off(event, handler)
function M.emit(event, data, opts)
function M.add_middleware(fn)
function M.get_performance_report()
function M.clear()
```

## core/performance_monitor.lua - Advanced performance monitoring for Zortex
```lua
	operations = {}, -- operation -> { samples, p50, p95, p99 }
	slow_operations = {}, -- operation -> count
	memory_usage = {}, -- timestamp -> usage
	event_queue_size = {}, -- timestamp -> size
			samples = {},
		operations = {},
		memory = {},
		recommendations = {},

-- Start monitoring
function M.start()

-- Stop monitoring
function M.stop()

-- Get current report
function M.get_report()

-- Show report in buffer
function M.show_report()

-- Reset metrics
function M.reset()
	metrics = {
		operations = {},
		slow_operations = {},
		memory_usage = {},
		event_queue_size = {},

-- Configure thresholds
function M.configure(opts)

-- Get status
function M.get_status()

-- Setup commands
function M.setup_commands()
```

## features/archive.lua - Intelligent section archiving and restoration
```lua

-- Archive the section at current cursor position
function M.archive_current_section()

-- Revert an archived section back to original file
function M.revert_archive(archive_file, section_line)
```

## features/links.lua - Link navigation for Zortex with normalized section handling
```lua
		cmd_parts = { "open", target }
		cmd_parts = { "xdg-open", target }
		cmd_parts = { "cmd", "/c", "start", "", target:gsub("/", "\\") }

-- Open link at cursor or search forward
function M.open_link()

-- Navigate to next/previous section at same or higher level
function M.navigate_section(direction)

-- Navigate to parent section
function M.navigate_parent()
```

## features/highlights.lua - Complete syntax highlighting for Zortex
```lua
	Heading = {
		patterns = {
	Article = {
		opts = { bold = true, fg = "#c4a7e7" },
		patterns = {
	Tag = {
		opts = { fg = "#ea9a97" },
		patterns = {
	BoldHeading = {
		opts = { bold = true },
		patterns = {
	Label = {
		opts = { bold = true, fg = "#3e8fb0" },
		patterns = {
	LabelText = {
		opts = { bold = true, fg = "#f6c177" },
		patterns = {
	LabelList = {
		opts = { bold = true, fg = "#3e8fb0" },
		patterns = {
	LabelListText = {
		opts = { bold = true, fg = "#f6c177" },
		patterns = {
	ListBullet = {
		patterns = {
				conceal = {
	NumberList = {
		opts = { fg = "#3e8fb0", bold = true },
		patterns = {
	TextList = {
		opts = { fg = "#3e8fb0", bold = true },
		patterns = {
	TaskCheckbox = {
		opts = { fg = "#ea9a97" },
		patterns = {
				conceal = {
	TaskText = {
		opts = { fg = "#f6c177" },
		patterns = {
	TaskDone = {
		opts = { fg = "#908caa", strikethrough = true },
		patterns = {
	Link = {
		opts = { fg = "#3e8fb0", underline = true },
		patterns = {
				conceal = {
	Footnote = {
		opts = { fg = "#9ccfd8", italic = true },
		patterns = { "%[%^([^]]+)%]" },
	URL = {
		opts = { fg = "#3e8fb0", underline = true },
		patterns = { "https?://[^%s]+" },
	Bold = {
		opts = { bold = true },
		patterns = {
				conceal = { type = "markers", chars = 2 },
	Italic = {
		opts = { italic = true },
		patterns = {
				conceal = { type = "markers", chars = 1 },
	CodeInline = {
		opts = { fg = "#f2ae49", bg = "#2d2a2e" },
		patterns = {
	MathInline = {
		opts = { fg = "#a9d977", italic = true },
		patterns = {
	MathBlock = {
		opts = { fg = "#a9d977", italic = true },
		patterns = {
	Attribute = {
		opts = { fg = "#908caa", italic = true },
		patterns = {
	Time = {
		opts = { fg = "#f6c177" },
		patterns = { "%d%d?:%d%d" },
	Percent = {
		opts = { fg = "#9ccfd8" },
		patterns = { "%d+%%" },
	Operator = {
		opts = { fg = "#ea9a97" },
		patterns = {
	Punctuation = {
		opts = { fg = "#ea9a97" },
		patterns = {
	Quote = {
		opts = { fg = "#c4a7e7", italic = true },
		patterns = { '"([^"]*)"' },
			caps = { cap1, cap2, cap3 },

--------------------------------------------------------------------------
-- Main highlighting function ------------------------------------------
--------------------------------------------------------------------------
function M.highlight_buffer(bufnr)
									virt_text = { { bullet_text, hl_group } },
											virt_text = { { text, "ZortexTaskCheckbox" } },
									virt_text = { { conceal.icon, "ZortexLinkDelimiter" } },

--------------------------------------------------------------------------
-- Setup functions -----------------------------------------------------
--------------------------------------------------------------------------
function M.setup()
function M.setup_autocmd()
```

## features/completion.lua - Context-aware completion for Zortex links
```lua
	article_data = {},
				data = {
	cache.articles = {}
	cache.article_data = {}
					headings = {},
					tags = {},
					labels = {},

-- Main completion function
function M.get_completions(line, col)

-- nvim-cmp source
function M.new()
	function source:is_available()
	function source:get_debug_name()
	function source:get_trigger_characters()
	function source:complete(params, callback)
			item.labelDetails = { detail = item.detail }
```

## features/ical.lua - iCal import/export for Zortex calendar
```lua
		properties = {},

-- Import iCal file
function M.import_file(filepath)

-- Export to iCal file
function M.export_file(filepath, options)

-- Import from URL
function M.import_url(url)

-- Interactive import
function M.import_interactive()

-- Interactive export
function M.export_interactive()
```

## tests/test.lua
```lua

-- Run all tests
function M.run_all()
```

## stores/xp.lua - XP state persistence
```lua

-- Override init_empty to set default XP structure
function store:init_empty()
	self.data = {
		area_xp = {}, -- area_path -> { xp, level }
		project_xp = {}, -- project_name -> { xp, level }
		completed_objectives = {}, -- Track completed objectives
		completed_projects = {}, -- Track completed projects
		season_history = {}, -- Past seasons

-- Area XP methods
function M.get_area_xp(path)
function M.set_area_xp(path, xp, level)
function M.get_all_area_xp()

-- Project XP methods
function M.get_project_xp(name)
function M.set_project_xp(name, xp, level)
function M.add_project_xp(name, xp_amount)

-- Season methods
function M.get_season_data()
function M.set_season_data(season_xp, season_level)
function M.start_season(name, end_date)
	store.data.current_season = {
	store.data.project_xp = {} -- Reset project XP for new season
function M.end_season()
		store.data.project_xp = {}

-- Objective tracking
function M.mark_objective_completed(objective_id, xp_awarded)
function M.is_objective_completed(objective_id)

-- Project tracking
function M.mark_project_completed(project_name, xp_awarded)

-- Force reload from disk
function M.reload()

-- Force save
function M.save()
function M.setup()
```

## stores/tasks.lua - Task state persistence
```lua

-- Override init_empty
function store:init_empty()
	self.data = {
		tasks = {}, -- task_id -> task_data
		project_tasks = {}, -- project_name -> array of task_ids

-- Task CRUD operations
function M.get_task(id)
function M.create_task(id, task_data)
function M.update_task(id, updates)
function M.delete_task(id)

-- Bulk operations
function M.get_project_tasks(project_name)
function M.get_all_tasks()

-- Task statistics
function M.get_stats()
		tasks_by_project = {},

-- ID management
function M.get_next_numeric_id()
function M.task_exists(id)

-- Archive completed tasks older than N days
function M.archive_old_tasks(days_old)

-- Force operations
function M.reload()
function M.save()
```

## stores/notifications.lua - Manages persistence for all notification state
```lua

-- Override init_empty for the main store to define the data structure
function store:init_empty()
	self.data = {
		scheduled = {}, -- Scheduled notifications
		pomodoro = {}, -- Pomodoro session state
		digest = {}, -- Digest-related state (e.g., last_sent)
		calendar_sent = {}, -- IDs of sent calendar notifications

-- Scheduled notifications
function M.get_scheduled()
function M.save_scheduled(scheduled_data)

-- Pomodoro state
function M.get_pomodoro()
function M.save_pomodoro(pomodoro_data)

-- Digest state
function M.get_digest_state()
function M.update_digest_state(digest_data)
		store.data.digest = {}

-- Calendar sent notifications
function M.get_calendar_sent()
function M.save_calendar_sent(calendar_data)

-- Force operations
function M.reload()
function M.save()
```

## stores/calendar.lua - Calendar store using entry models
```lua
	entries = {}, -- entries[date_str] = array of CalendarEntry models
function M.load()
	state.entries = {}
function M.save()
function M.ensure_loaded()

-- Add calendar entry
function M.add_entry(date_str, entry_text)

-- Delete an entry
function M.delete_entry_by_text(date_str, entry_text)
function M.delete_entry_by_index(date_str, entry_index)

-- Update an entry
function M.update_entry(date_str, old_text, new_text)
function M.get_entries_for_date(date_str)
function M.get_entries_in_range(start_date, end_date)

-- Get all entries (for search/telescope)
function M.get_all_entries()
function M.set_all_entries(entries)
```

## stores/base.lua - Base store class for persistence
```lua

-- Create a new store instance
function M:new(filepath)
	store.data = {}

-- Initialize empty data (override in subclasses)
function M:init_empty()
	self.data = {}

-- Load data from file
function M:load()

-- Save data to file
function M:save()

-- Ensure store is loaded before operations
function M:ensure_loaded()

-- Mark store as dirty (needs save)
function M:mark_dirty()

-- Get data with optional default
function M:get(key, default)

-- Set data value
function M:set(key, value)

-- Update multiple values
function M:update(updates)

-- Clear all data
function M:clear()
	self.data = {}

-- Get store status
function M:get_status()
```

## stores/persistence_manager.lua - Manages coordinated persistence of all stores
```lua
	dirty_stores = {}, -- store_name -> true
	registered_stores = {}, -- store_name -> store_module

-- Register a store for managed persistence
function M.register_store(name, store_module)

-- Register all default stores
function M.register_defaults()

-- Mark a store as dirty (needs saving)
function M.mark_dirty(store_name)

-- Check if any stores are dirty
function M.has_dirty_stores()

-- Get list of dirty stores
function M.get_dirty_stores()

-- Schedule a save operation
function M.schedule_save()

-- Cancel scheduled save
function M.cancel_scheduled_save()

-- Save all dirty stores
function M.save_all()
		saved = {},
		errors = {},

-- Force save a specific store
function M.save_store(store_name)

-- Initialize persistence manager
function M.setup(opts)

-- Get current status
function M.get_status()

-- Debug: force mark all stores dirty
function M.debug_mark_all_dirty()
```

## utils/datetime.lua - Date and time utilities for Zortex
```lua

--- Gets the current date as a table.
-- @return table A table with {year, month, day, wday}
function M.get_current_date()

--- Adds days to a date.
-- @param date table A date table with {year, month, day}
-- @param days number Number of days to add (can be negative)
-- @return table A new date table
function M.add_days(date, days)

--- Parses a date string into a table.
-- Supports YYYY-MM-DD and MM-DD-YYYY formats.
-- @param date_str string The date string to parse.
-- @return table|nil A table with {year, month, day} or nil if parsing fails.
function M.parse_date(date_str)

--- Parses a time string into a table.
-- Supports 24-hour (HH:MM) and 12-hour (HH:MMam/pm) formats.
-- @param time_str string The time string to parse.
-- @return table|nil A table with {hour, min} or nil if parsing fails.
function M.parse_time(time_str)

--- Parses a datetime string into a single date table.
-- @param dt_str string The datetime string (e.g., "YYYY-MM-DD HH:MM").
-- @param default_date_str string (Optional) A date string to use if dt_str is only a time.
-- @return table|nil A table with {year, month, day, hour, min} or nil.
function M.parse_datetime(dt_str, default_date_str)

-- Parse duration and units and return in minutes
function M.parse_duration(duration)

-- Parse multiple duration num+unit pairs
function M.parse_durations(durations)

--- Formats a date table into a string.
-- @param date_tbl table A table with {year, month, day, [hour], [min]}.
-- @param format_str string The format string (e.g., "YYYY-MM-DD").
-- @return string The formatted date string.
function M.format_date(date_tbl, format_str)

--- Compares two dates.
-- @param date1 table First date
-- @param date2 table Second date
-- @return number -1 if date1 < date2, 0 if equal, 1 if date1 > date2
function M.compare_dates(date1, date2)

--- Gets the day of week name.
-- @param wday number Day of week (1-7, Sunday is 1)
-- @return string Day name
function M.get_day_name(wday)

--- Gets the month name.
-- @param month number Month (1-12)
-- @return string Month name
function M.get_month_name(month)

--- Checks if a year is a leap year.
-- @param year number The year
-- @return boolean True if leap year
function M.is_leap_year(year)

--- Gets the number of days in a month.
-- @param year number The year
-- @param month number The month (1-12)
-- @return number Number of days
function M.get_days_in_month(year, month)

--- Calculates the difference in days between two dates.
-- @param date1 table First date
-- @param date2 table Second date
-- @return number Number of days (positive if date2 > date1)
function M.days_between(date1, date2)

--- Formats a relative date string.
-- @param date table The date to format
-- @param reference table Optional reference date (defaults to today)
-- @return string Relative date string (e.g., "Today", "Tomorrow", "Next Monday")
function M.format_relative_date(date, reference)

--- Gets the day of week name abbreviated.
-- @param wday number Day of week (1-7, Sunday is 1)
-- @return string Abbreviated day name
function M.get_day_abbrev(wday)

--- Gets the month name abbreviated.
-- @param month number Month (1-12)
-- @return string Abbreviated month name
function M.get_month_abbrev(month)

--- Gets the first weekday of a month.
-- @param year number The year
-- @param month number The month (1-12)
-- @return number Day of week (1-7, Sunday is 1)
function M.get_first_weekday(year, month)

--- Formats a month and year.
-- @param date table Date with year and month
-- @return string Formatted string like "January 2024"
function M.format_month_year(date)

--- Normalizes a date to noon (for consistent date comparisons).
-- @param date table Date to normalize
-- @return table New date table with time set to noon
function M.normalize_date(date)

--- Checks if two dates are the same day.
-- @param date1 table First date
-- @param date2 table Second date
-- @return boolean True if same day
function M.is_same_day(date1, date2)
```

## utils/attributes.lua - Simplified attributes module using consolidated parser
```lua
M.schemas = {
	task = {
		id = { type = "string" },
		size = { type = "enum", values = { "xs", "sm", "md", "lg", "xl" } },
		p = { type = "enum", values = { "1", "2", "3" } },
		i = { type = "enum", values = { "1", "2", "3" } },
		due = { type = "date" },
		at = { type = "string" },
		dur = { type = "duration" },
		est = { type = "duration" },
		done = { type = "date" },
		progress = { type = "progress" },
		notify = { type = "list" },
		depends = { types = "string" }, -- Specifies task dependence
	project = {
		p = { type = "enum", values = { "1", "2", "3" } },
		i = { type = "enum", values = { "1", "2", "3" } },
		progress = { type = "progress" },
		due = { type = "date" },
		done = { type = "date" },
		xp = { type = "number" },
		dur = { type = "duration" },
		est = { type = "duration" },
		size = {
			values = {
	event = {
		at = { type = "string" },
		from = { type = "datetime" },
		to = { type = "datetime" },
		notify = { type = "duration" },
	calendar_entry = {
		id = { type = "string" },
		p = { type = "enum", values = { "1", "2", "3" } },
		i = { type = "enum", values = { "1", "2", "3" } },
		due = { type = "datetime" },
		at = { type = "datetime" },
		dur = { type = "duration" },
		est = { type = "duration" },
		from = { type = "datetime" },
		to = { type = "datetime" },
		notify = { type = "list" },

-- Parse task attributes
function M.parse_task_attributes(line, context)

-- Parse project attributes
function M.parse_project_attributes(line, context)

-- Parse event attributes
function M.parse_event_attributes(line, context)

-- Parse calendar entry attributes
function M.parse_calendar_attributes(line, context)

-- Strip attributes (returns clean text and extracted attributes)
function M.strip_attributes(line, schema)

-- Extract specific attribute
function M.extract_attribute(line, key)

-- Update attribute
function M.update_attribute(line, key, value)

-- Remove attribute
function M.remove_attribute(line, key)

-- Add attribute if not present
function M.add_attribute(line, key, value)

-- Progress attribute helpers
function M.update_progress_attribute(line, completed, total)
function M.extract_progress(line)

-- Done attribute helpers
function M.update_done_attribute(line, done)
function M.was_done(line)
function M.extract_task_id(line)

-- Task status parsing
function M.parse_task_status(line)

-- Format minutes to duration string
function M.format_duration(minutes)
```

## utils/parser.lua - Consolidated parsing logic for Zortex
```lua
function M.trim(str)
function M.escape_pattern(text)
function CodeBlockTracker:new()
function CodeBlockTracker:update(line)
function CodeBlockTracker:is_in_code_block()
function M.detect_section_type(line, in_code_block)
function M.get_section_priority(line, in_code_block)
function M.get_heading_level(line)
function M.parse_heading(line)
function M.is_bold_heading(line)
function M.parse_bold_heading(line)
function M.parse_label(line)
function M.is_task_line(line)
function M.parse_task_status(line)
function M.get_task_text(line)

-- Parse @key(value) attributes from text
-- @param parser_context table Context of the text being parsed to optionally pass to functions like parse_datetime() default_date_str.
--  The attribute parsers know how to take the parser_context and pass relevant information to functions as necessary.
function M.parse_attributes(text, schema, parser_context)

-- Extract specific attribute
function M.extract_attribute(line, key)

-- Update attribute value
function M.update_attribute(line, key, value)

-- Remove attribute
function M.remove_attribute(line, key)
function M.extract_link_at(line, cursor_col)
function M.extract_all_links(line)

-- Escape special characters in link components
function M.escape_link_component(text)

-- Unescape link components
function M.unescape_link_component(text)

-- Enhanced parse_link_component that handles attributes
function M.parse_link_component(component)

-- Smart parse_link_definition that handles slashes within parentheses
function M.parse_link_definition(definition)
		components = {},
function M.extract_article_name(line)
function M.extract_tags_from_lines(lines, max_lines)
function M.parse_okr_date(line)

--  Build the section "breadcrumb" that leads to a given buffer line
---Return an ordered list of section‑objects that enclose `target_lnum`.
---Each element contains everything the rest of the code already expects:
---• `lnum`  – where the section starts
---• `type`  – one of constants.SECTION_TYPE.*
---• `priority`– numeric hierarchy value (lower ⇒ higher level)
---• `level`  – heading level (only for `HEADING`)
---• `text`    – raw text that represents the section (article title, heading,
---               bold heading, or label)
---• `display` – text to show in breadcrumbs / Telescope lists
---@param lines        string[]  -- full buffer ‑ 1‑indexed
---@param target_lnum  integer   -- line the user/caller is interested in
---@return table[]               -- top‑down path  (article → … → innermost)
function M.build_section_path(lines, target_lnum)

--- Find the start of a section by searching backwards from a line.
--- Searches upwards from `start_lnum` to find the first line that defines a
--- section with a priority that is less than or equal to (i.e., higher than
--- or the same level as) the given `priority`.
function M.find_section_start(lines, start_lnum, section_type, heading_level)
function M.find_section_end(lines, start_lnum, section_type, heading_level)
```

## utils/filesystem.lua - File operations for Zortex
```lua
function M.get_file_path(filename)
function M.joinpath(...)
function M.ensure_directory(path)
function M.read_lines(filepath)
function M.write_lines(filepath, lines)
function M.file_exists(filepath)
function M.directory_exists(dirpath)
function M.find_files(dir, pattern)
function M.get_all_note_files()

-- Get all note files with basic filtering
function M.find_all_notes(filter_fn)
function M.get_calendar_file()
function M.get_projects_file()
function M.get_archive_file()
function M.get_okr_file()
function M.get_areas_file()
function M.read_archive()
function M.write_archive(lines)
function M.read_json(filepath)
function M.write_json(filepath, data)
```

## utils/resolver.lua - Search functionality for Zortex with normalized section handling
```lua
function M.create_search_pattern(component)
function M.find_article_files(article_name)
function M.get_section_end(lines, start_lnum, component)
function M.search_component_in_files(component, file_paths, section_bounds)
function M.search_in_buffer(component, start_line, end_line)
function M.process_link(parsed_link)
			section_bounds = {}
function M.search_footnote(ref_id)

-- Find section in a document using parsed link components
function M.find_section_by_link(doc, link_def)
function M.populate_quickfix(results)
```

## core/buffer.lua - Buffer operations for Zortex
```lua
function M.get_lines(bufnr, start_line, end_line)
function M.set_lines(bufnr, start_line, end_line, lines)
function M.get_current_line()
function M.get_cursor_pos()
function M.set_cursor_pos(line, col)
function M.find_current_project(bufnr)
function M.get_all_headings(bufnr)

-- Get the bounds of a project/section
function M.find_section_bounds(lines, start_idx)
function M.is_special_buffer()
function M.get_target_window()
function M.find_in_buffer(pattern, start_line, end_line)
function M.update_line(bufnr, lnum, new_text)
function M.insert_lines(bufnr, lnum, lines)
function M.delete_lines(bufnr, start_lnum, end_lnum)
```

## config.lua - Centralized configuration for Zortex
```lua
	special_articles = { "structure" }, -- Changes link opening behavior
	commands = {
	keymaps = {
	core = {
		persistence_manager = {
		logger = {
		buffer_sync = {
	notifications = {
		enable = {
		providers = {
			system = {
				commands = {
			ntfy = {
				tags = { "zortex" },
			aws = {
			vim = {
			ses = {
		default_providers = { "vim", "system" },
		calendar_providers = { "vim", "system", "ntfy" },
		timer_providers = { "vim", "system" },
		pomodoro_providers = { "vim", "system" },
		digest_providers = { "ses" },
		digest = {
		pomodoro = {
		timers = {
	ui = {
		search = {
			breadcrumb_display = {
				one_token = { "article" },
				two_tokens = { "article", "heading_1_2" },
				three_plus_tokens = { "article", "heading", "bold_heading", "label" },
			history = {
			token_filters = {
		calendar = {
			window = {
			colors = {
			icons = {
			digest = {
			keymaps = {
				close = { "q", "<Esc>" },
				next_day = { "l", "<Right>" },
				prev_day = { "h", "<Left>" },
				next_week = { "j", "<Down>" },
				prev_week = { "k", "<Up>" },
				next_month = { "J" },
				prev_month = { "K" },
				next_year = { "L" },
				prev_year = { "H" },
				today = { "t", "T" },
				add_entry = { "a", "i" },
				view_entries = { "<CR>", "o" },
				edit_entry = { "e" },
				delete_entry = { "x" },
				telescope_search = { "/" },
				toggle_view = { "v" },
				digest = { "d", "D" },
				refresh = { "r", "R" },
				go_to_file = { "gf" },
				sync_notifications = { "n" },
				help = { "?" },
		telescope = {
	xp = {
		distribution_rules = {
			task = {
			objective = {
			daily_review = {
		area = {
			level_curve = {
			time_multipliers = {
		project = {
			season_curve = {
			task_rewards = {
				initiation = {
				execution = {
				completion = {
		seasons = {
			tiers = {

-- Initialize configuration
function Config.setup(opts)
```

## constants.lua - Shared constants for Zortex
```lua

-- File paths (relative to notes_dir)
M.FILES = {

-- Section types
M.SECTION_TYPE = {

-- Section hierarchy and priorities (lower number = higher priority)
M.SECTION_HIERARCHY = {
	priorities = {

-- Patterns for parsing
M.PATTERNS = {

-- Task status definitions
M.TASK_STATUS = {
	TODO = { symbol = " ", name = "To Do", color = "Comment" },
	DOING = { symbol = "◐", name = "In Progress", color = "DiagnosticWarn" },
	WAITING = { symbol = "⏸", name = "Waiting", color = "DiagnosticInfo" },
	DONE = { symbol = "✓", name = "Done", color = "DiagnosticOk" },
	CANCELLED = { symbol = "✗", name = "Cancelled", color = "DiagnosticError" },
	DELEGATED = { symbol = "→", name = "Delegated", color = "DiagnosticHint" },

-- Time horizons
M.TIME_HORIZONS = {

-- Calendar view modes
M.CALENDAR_MODES = {

-- XP tier definitions
M.XP_TIERS = {
	BRONZE = { name = "Bronze", min_level = 1 },
	SILVER = { name = "Silver", min_level = 5 },
	GOLD = { name = "Gold", min_level = 10 },
	PLATINUM = { name = "Platinum", min_level = 15 },
	DIAMOND = { name = "Diamond", min_level = 20 },
	MASTER = { name = "Master", min_level = 30 },

-- Highlight groups
M.HIGHLIGHTS = {
M.SEARCH_MODES = {
```

## M.show_progress = function()
```lua
M.task = {

-- ===========================================================================
-- XP
-- ===========================================================================
M.xp = {
	season = {

-- ===========================================================================
-- UI
-- ===========================================================================
M.search = {
M.calendar = {

-- ===========================================================================
-- Archive
-- ===========================================================================
M.archive = {
```

## notifications/init.lua - Public API for the notification system
```lua
function M.setup_commands()

-- Initialize the notification system
function M.setup(opts) -- Config.notifications

-- Send a notification immediately
function M.notify(title, message, options)

-- Schedule a notification
function M.schedule(title, message, when, options)

-- Cancel a scheduled notification
function M.cancel(id)

-- List scheduled notifications
function M.list_scheduled()

-- Pomodoro functions
M.pomodoro = {

-- Timer functions
M.timer = {

-- Calendar functions
M.calendar = {

-- Test functions
M.test = {

-- Cleanup on exit
function M.cleanup()
```

## notifications/types/pomodoro.lua - Pomodoro timer implementation
```lua

-- Start pomodoro
function M.start(phase)
	current_session = {

-- Stop pomodoro
function M.stop()

-- Pause/Resume
function M.pause()
function M.resume()

-- Get status
function M.status()

-- Skip to next phase
function M.skip_to_next()

-- Setup
function M.setup(config)
```

## notifications/types/timer.lua - Timer/alarm implementation
```lua

-- Start a timer
function M.start(duration, name, options)
		warnings_sent = {},

-- Start an alarm (timer for specific time)
function M.alarm(time_str, name, options)

-- Stop a timer
function M.stop(timer_id)

-- List active timers
function M.list()

-- Get remaining time
function M.get_remaining(timer_id)

-- Setup
function M.setup(cfg)

-- Cleanup all timers
function M.cleanup()
	active_timers = {}
```

## notifications/types/calendar.lua - Calendar notification handler
```lua
		tags = { "calendar", entry.type or "event" },

-- Check and send due notifications
function M.check_and_notify()
					notify_values = { notify_values }

-- Sync notifications to external services
function M.sync()
					notify_values = { notify_values }

-- Clean old sent notifications
function M.clean_old_notifications()

-- Get pending notifications for a date
function M.get_pending_for_date(date_str)
				notify_values = { notify_values }

-- Setup
function M.setup(config)
```

## notifications/types/digest.lua - Daily digest email notifications
```lua

-- Send daily digest
function M.send_digest(options)

-- Schedule automatic digest
function M.schedule_auto_digest()

-- Setup
function M.setup(opts)

-- Manual commands
function M.send_now(days)
function M.preview(days)
```

## notifications/providers/vim.lua - Vim notification provider
```lua
```

## notifications/providers/aws.lua - AWS notification provider
```lua
		notification = {
```

## notifications/providers/system.lua - System notification provider
```lua
			commands = {
```

## notifications/providers/ntfy.lua - ntfy.sh notification provider
```lua
```

## notifications/providers/ses.lua - AWS SES email provider
```lua
		Destination = {
		Message = {
			Subject = {
			Body = {},
		email_json.Message.Body.Text = {
		email_json.Message.Body.Html = {
```

## notifications/providers/base.lua - Base provider interface
```lua

-- Provider interface that all providers should implement
M.interface = {

-- Helper to create a new provider
function M.create_provider(name, implementation)
```

## notifications/manager.lua - Core notification manager
```lua

-- Send notification through all active providers
function M.send_notification(title, message, options)

-- Schedule a notification
function M.schedule_notification(title, message, when, options)

-- Cancel a scheduled notification
function M.cancel_notification(id)

-- List scheduled notifications
function M.list_scheduled()

-- Setup function
function M.setup(cfg)

-- Cleanup
function M.stop()
```

## services/objective.lua
```lua

-- Parse OKR file and extract objectives
function M.get_objectives()

-- Update OKR progress based on project completions
function M.update_progress()

-- Get current (incomplete) objectives
function M.get_current_objectives()

-- Get objective statistics
function M.get_stats()
		by_span = {},
		by_year = {},

-- Private helper functions
function M._parse_objectives_from_document(doc)
			current_objective = {
				key_results = {},
				area_links = {},
				created = { type = "date" },
				done = { type = "date" },
function M._generate_objective_id(date_info)
function M._extract_project_links(text)
function M._calculate_objective_progress(objective)
function M._calculate_objective_xp(objective)
function M._apply_progress_updates(updates)
```

## services/projects/init.lua - Project management service using Doc
```lua

-- Get all projects from document
function M.get_projects_from_document(doc)
				subprojects = {},
				stats = {

-- Get all projects
function M.get_all_projects()

-- Get project at line
function M.get_project_at_line(bufnr, line_num)

-- Update project progress
function M.update_project_progress(project, bufnr)

-- Update all projects in document
function M.update_all_project_progress(bufnr)

-- Check if project is completed
function M.is_project_completed(project_name)

-- Get project by link
function M.get_project_by_link(link_str)

-- Get project statistics
function M.get_all_stats()
		projects_by_priority = {},
		projects_by_importance = {},
```

## services/projects/progress.lua - Handles project progress updates
```lua

-- Queue a project update
function M.queue_project_update(bufnr, project_link, completed_delta, total_delta)

-- Process all queued updates
function M.process_update_queue()
	update_queue = {}

-- Update a single project
function M.update_single_project(update)

-- Initialize project progress tracking
function M.init()

-- Force update all projects in a buffer
function M.update_all_projects(bufnr)
```

## services/task.lua - Stateless service for task operations
```lua

-- Complete a task
function M.complete_task(task_id, context)

-- Uncomplete a task
function M.uncomplete_task(task_id, context)

-- Change task completion at cursor line
-- @param context table Table containing the {bufnr: int, lnum: int}
-- @param should_complete boolean|nil nil then toggle, true to complete, false to uncomplete
function M.change_task_completion(context, should_complete)

-- Convert line to task
function M.convert_line_to_task(context)
		attributes = { id = task_id },

-- Build XP context for a task
function M._build_xp_context(task, context)

-- Find project containing task (returns {text, link})
function M._find_project_for_task(doc, section)

-- Extract area links from section hierarchy
function M._extract_area_links(doc, section)

-- Calculate task position within project
function M._calculate_task_position_in_project(doc, task, project_name)

-- Update task attributes
function M.update_task_attributes(task_id, attributes, context)
		updates = { attributes = attributes },

-- Process all tasks in buffer (for bulk operations)
function M.process_buffer_tasks(bufnr)
function M.get_task_context()
function M.toggle_current_task()
function M.complete_current_task()
function M.uncomplete_current_task()
```

## services/area.lua - Area management service
```lua

-- Parse areas file and build tree
function M.get_area_tree()
		children = {},

-- Invalidate area cache
function M.invalidate_cache()

-- Add XP to area with parent bubbling
function M.add_area_xp(area_path, xp_amount)

-- Remove XP from area (for task uncomplete)
function M.remove_area_xp(area_path, xp_amount)

-- Extract area links from text
function M.extract_area_links(text)

-- Parse area link to path
function M.parse_area_path(area_link)

-- Complete objective and award area XP
function M.complete_objective(objective_id, objective_data)
		areas = {},

-- Get area statistics
function M.get_area_stats(area_path)

-- Get top areas by XP
function M.get_top_areas(limit)
function M._build_area_tree_from_sections(section, parent)
				children = {},
function M._apply_xp_to_tree(node)
function M._is_area_link(parsed_link)
function M._get_parent_path(area_path)

-- Set up event listeners
function M.init()
```

## services/search.lua - Search service with improved hierarchical matching
```lua
	cache = {}, -- filepath -> { mtime, document }
function FileCache:get(filepath)
function FileCache:set(filepath, document)
function FileCache:clear()
	self.cache = {}
		article_names = {}, -- Changed to array
		stats = {

-- Load or get cached document for search
function SearchDocumentCache:get_document(filepath)

-- Get all searchable documents
function SearchDocumentCache:get_all_documents()

-- Clear cache (for refresh)
function SearchDocumentCache:clear()
	data = {}, -- filepath -> { last_access, access_count }
function AccessTracker.load()
function AccessTracker.save()
function AccessTracker.record(filepath)
function AccessTracker.get_score(filepath, current_time)
	entries = {},
function SearchHistory.add(entry)
		score_contribution = {},
function SearchHistory.propagate_scores(entry)
function SearchHistory.get_score(filepath, line_num, section_path)
				result._matched_path = { section }
					result._matched_path = {}
function M.search(query, opts)
				section_path = {
function M.open_result(result, cmd)
function M.get_stats()
function M.refresh_all()
function M.setup(opts)

-- Configure token filters
function M.configure_token_filters(filters)
```

## services/calendar_entry.lua - Calendar entry model
```lua
function M:new(data)

-- Parse a calendar entry from text
function M.from_text(entry_text, current_date_str)
function M:_compute_fields()
		self.date_range = {

-- Check if entry is active on a given date
function M:is_active_on_date(date)

-- Check if repeat pattern is active
function M:is_repeat_active(start_date, target_date)

-- Get formatted time string
function M:get_time_string()

-- Get sort priority (for ordering entries)
function M:get_sort_priority()

-- Format entry depending on calendar pretty_attributes setting
function M:format()

-- Pretty‑print attributes
function M:format_pretty()

-- Format attributes in simple mode
function M:format_simple()
```

## services/search/init.lua
```lua
```

## services/search/document_cache.lua
```lua
```

## services/search/scoring.lua
```lua
```

## services/search/hierarchical.lua
```lua
```

## services/search/history.lua
```lua
```

## services/xp/init.lua - Service for XP orchestration and calculation
```lua

-- Check for level ups
function M.check_level_ups()

-- Get XP statistics
function M.get_stats()

-- Initialize service
function M.init()
```

## services/xp/season.lua - Manage seasons
```lua

-- Season management
function M.start_season(name, end_date)
function M.end_season()
function M.get_season_status()
```

## services/xp/distributor.lua - Handles XP distribution logic and rules
```lua

-- Distribute XP with full tracking
function M.distribute(source_type, source_id, base_amount, targets)
		source = {
		distributions = {},

-- Distribute task XP
function M._distribute_task_xp(distribution, targets)

-- Distribute objective XP
function M._distribute_objective_xp(distribution, targets)

-- Distribute daily review XP
function M._distribute_daily_review_xp(distribution, targets)

-- Add a distribution entry
function M._add_distribution(distribution, entry)

-- Initialize distributor with event listeners
function M.setup(opts)

-- Bubble XP to parent areas
function M._bubble_to_parent_areas(area_path, base_amount)

-- Get parent area links (simplified for now)
function M._get_parent_area_links(area_path)

-- Update distribution statistics
function M._update_distribution_stats(distribution)

-- Calculate effective XP with all modifiers
function M.calculate_effective_xp(base_xp, modifiers)

-- Validate distribution targets
function M.validate_targets(source_type, targets)
```

## services/xp/calculator.lua - Core XP calculations and formulas
```lua

-- Calculate XP required for a specific area level
function M.calculate_area_level_xp(level)

-- Calculate XP required for a specific season level
function M.calculate_season_level_xp(level)

-- Calculate level from total XP (area)
function M.calculate_area_level(xp)

-- Calculate level from total XP (season)
function M.calculate_season_level(xp)

-- Get progress towards next level
function M.get_level_progress(xp, level, level_calc_fn)

-- Get time horizon multiplier for objectives
function M.get_time_multiplier(time_horizon)

-- Calculate decay factor for old objectives
function M.calculate_decay_factor(days_old)

-- Calculate XP for a task based on its position in the project
function M.calculate_task_xp(task_position, total_tasks)

-- Calculate total potential XP for a project
function M.calculate_project_total_xp(total_tasks)

-- Calculate XP for completing an objective
function M.calculate_objective_xp(time_horizon, created_date)

-- Calculate area XP from project XP
function M.calculate_area_transfer(project_xp, num_areas)

-- Calculate parent area XP from child area XP
function M.calculate_parent_bubble(child_xp, num_parents)

-- Get tier information for a season level
function M.get_season_tier(level)
function M.setup(config)

-- Format XP display
function M.format_xp(xp)

-- Get color for level (for UI)
function M.get_level_color(level, max_level)
```

## services/xp/notifications.lua - Enhanced XP notifications
```lua
function M.notify_progress_update(xp_changes, projects_completed)
function M.notify_objective_completion(objective_text, xp_awarded, area_awards)
function M.show_xp_overview()
function M.init()
```

