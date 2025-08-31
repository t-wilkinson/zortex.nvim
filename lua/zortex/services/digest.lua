-- services/digest.lua - Daily digest aggregation service
local M = {}

local Config = require("zortex.config")
local Logger = require("zortex.core.logger")
local datetime = require("zortex.utils.datetime")
local fs = require("zortex.utils.filesystem")
local calendar_store = require("zortex.stores.calendar")
local workspace = require("zortex.core.workspace")
local parser = require("zortex.utils.parser")
local attributes = require("zortex.utils.attributes")
local constants = require("zortex.constants")
local Events = require("zortex.core.event_bus")

-- =============================================================================
-- State Management
-- =============================================================================

local state = {
	last_generated = nil,
	live_links = {}, -- Track live link subscriptions
	update_timer = nil,
	watchers = {}, -- File watchers for live links
}

-- =============================================================================
-- Data Collection
-- =============================================================================

-- Get calendar events for the next month
local function get_upcoming_events()
	calendar_store.ensure_loaded()

	local events = {}
	local today = datetime.get_current_date()
	local end_date = datetime.add_days(today, 30)

	local entries_by_date = calendar_store.get_entries_in_range(
		datetime.format_datetime(today, "YYYY-MM-DD"),
		datetime.format_datetime(end_date, "YYYY-MM-DD")
	)

	-- Convert to flat list with dates
	for date_str, date_entries in pairs(entries_by_date) do
		for _, entry in ipairs(date_entries) do
			if entry.type == "event" then
				table.insert(events, {
					date = date_str,
					entry = entry,
					priority = entry.attributes.p,
					importance = entry.attributes.i,
				})
			end
		end
	end

	-- Sort by date
	table.sort(events, function(a, b)
		return a.date < b.date
	end)

	return events
end

-- Get today's tasks from calendar
local function get_todays_tasks()
	calendar_store.ensure_loaded()

	local today_str = datetime.format_datetime(datetime.get_current_date(), "YYYY-MM-DD")
	local entries = calendar_store.get_entries_for_date(today_str)

	local tasks = {}
	for _, entry in ipairs(entries) do
		if entry.type == "task" and not entry.task.completed then
			table.insert(tasks, {
				entry = entry,
				priority = entry.attributes.p,
				importance = entry.attributes.i,
			})
		end
	end

	return tasks
end

-- Get high priority projects and tasks
local function get_priority_items()
	local items = {
		projects = {},
		tasks = {},
	}

	-- Get projects
	local projects_doc = workspace.projects()
	if projects_doc and projects_doc.sections then
		local function extract_projects(section, path)
			if section.type == "heading" then
				local lines = section:get_lines(projects_doc.bufnr)
				local first_line = lines[1]
				if first_line then
					local attrs = attributes.parse_project_attributes(first_line)
					local is_high_priority = attrs.p and tonumber(attrs.p) <= 2
					local is_high_importance = attrs.i and tonumber(attrs.i) <= 2

					if is_high_priority or is_high_importance then
						table.insert(items.projects, {
							name = section.text,
							section = section,
							attributes = attrs,
							path = path,
							priority = attrs.p,
							importance = attrs.i,
						})
					end
				end
			end

			-- Process children
			for _, child in ipairs(section.children) do
				extract_projects(child, path .. "/" .. section.text)
			end
		end

		extract_projects(projects_doc.sections, "")
	end

	-- Sort by priority then importance
	local sort_fn = function(a, b)
		local a_pri = tonumber(a.priority or 999)
		local a_imp = tonumber(a.importance or 999)
		local b_pri = tonumber(b.priority or 999)
		local b_imp = tonumber(b.importance or 999)

		if a_pri ~= b_pri then
			return a_pri < b_pri
		else
			return a_imp < b_imp
		end
	end

	table.sort(items.projects, sort_fn)

	return items
end

-- Get all incomplete tasks from projects
local function get_all_todos()
	local todos = {}

	local projects_doc = workspace.projects()
	if projects_doc then
		local lines = projects_doc.lines
		for lnum, line in ipairs(lines) do
			local task = parser.parse_task(line)
			if task and not task.completed then
				-- Get containing project
				local section = projects_doc:get_section_at_line(lnum)
				local project_section = section
				while project_section and project_section.type ~= "heading" do
					project_section = project_section.parent
				end

				table.insert(todos, {
					task = task,
					line = line,
					lnum = lnum,
					project = project_section and project_section.text,
					priority = task.attributes.p,
					importance = task.attributes.i,
					due = task.attributes.due,
				})
			end
		end
	end

	-- Sort by due date, then priority
	table.sort(todos, function(a, b)
		if a.due and b.due then
			return datetime.format_datetime(a.due, "YYYY-MM-DD") < datetime.format_datetime(b.due, "YYYY-MM-DD")
		elseif a.due then
			return true
		elseif b.due then
			return false
		else
			local a_pri = tonumber(a.priority or 999)
			local b_pri = tonumber(b.priority or 999)
			return a_pri < b_pri
		end
	end)

	return todos
end

-- =============================================================================
-- Digest Generation
-- =============================================================================

-- Get day of week from date
local function get_wday(date)
	local t = os.time(date)
	return os.date("*t", t).wday
end

-- Format a date for display
local function format_date_header(date_str)
	local date = datetime.parse_date(date_str)
	local today = datetime.get_current_date()
	local days_diff = datetime.days_between(today, date)

	local relative = ""
	if days_diff == 0 then
		relative = " (Today)"
	elseif days_diff == 1 then
		relative = " (Tomorrow)"
	elseif days_diff > 0 and days_diff <= 7 then
		relative = " (This " .. datetime.get_day_name(date.wday) .. ")"
	end

	return string.format(
		"%s, %s %d%s:",
		datetime.get_day_name(get_wday(date)),
		datetime.get_month_name(date.month),
		date.day,
		relative
	)
end

-- Generate the digest content
function M.generate_digest()
	local lines = {
		"@@Daily Digest",
		"@@Digest",
		"",
		"Generated: " .. os.date("%Y-%m-%d %H:%M"),
		"",
	}

	-- Today's Calendar Tasks
	local todays_tasks = get_todays_tasks()
	if #todays_tasks > 0 then
		table.insert(lines, "## Today's Tasks")
		table.insert(lines, "")
		for _, item in ipairs(todays_tasks) do
			local entry = item.entry
			local line = string.format("- [ ] %s", entry.display_text)
			if entry.attributes.at then
				line = line .. " @at(" .. entry.attributes.at .. ")"
			end
			if item.priority then
				line = line .. " @p" .. item.priority
			end
			table.insert(lines, line)
		end
		table.insert(lines, "")
	end

	-- High Priority Projects
	local priority_items = get_priority_items()
	if #priority_items.projects > 0 then
		table.insert(lines, "## High Priority Projects")
		table.insert(lines, "")
		for _, project in ipairs(priority_items.projects) do
			local link = project.section:build_link(workspace.projects())
			local line = string.format("- ![%s]", link:sub(2, -2))
			if project.priority then
				line = line .. " @p" .. project.priority
			end
			if project.importance then
				line = line .. " @i" .. project.importance
			end
			if project.attributes.due then
				line = line .. " @due(" .. datetime.format_datetime(project.attributes.due, "YYYY-MM-DD") .. ")"
			end
			table.insert(lines, line)
		end
		table.insert(lines, "")
	end

	-- Upcoming Due Tasks
	local todos = get_all_todos()
	local due_soon = {}
	local today = datetime.get_current_date()

	for _, todo in ipairs(todos) do
		if todo.due then
			local days_until = datetime.days_between(today, todo.due)
			if days_until <= 7 and days_until >= 0 then
				table.insert(due_soon, todo)
			end
		end
	end

	if #due_soon > 0 then
		table.insert(lines, "## Tasks Due This Week")
		table.insert(lines, "")
		for _, todo in ipairs(due_soon) do
			local line = string.format("- [ ] %s", todo.task.text)
			if todo.project then
				line = line .. " ![Projects/#" .. todo.project .. "]"
			end
			line = line .. " @due(" .. datetime.format_datetime(todo.due, "YYYY-MM-DD") .. ")"
			table.insert(lines, line)
		end
		table.insert(lines, "")
	end

	-- Upcoming Events (grouped by date)
	local events = get_upcoming_events()
	if #events > 0 then
		table.insert(lines, "## Upcoming Events")
		table.insert(lines, "")

		local current_date = nil
		local event_count = 0
		local max_events = 20

		for _, event_data in ipairs(events) do
			if event_count >= max_events then
				table.insert(lines, "... and " .. (#events - max_events) .. " more events")
				break
			end

			-- Add date header if new date
			if current_date ~= event_data.date then
				if current_date then
					table.insert(lines, "")
				end
				current_date = event_data.date
				table.insert(lines, format_date_header(event_data.date))
				table.insert(lines, "")
			end

			-- Add event
			local entry = event_data.entry
			local line = "- " .. entry:format_pretty()
			table.insert(lines, line)
			event_count = event_count + 1
		end
		table.insert(lines, "")
	end

	-- Update state
	state.last_generated = os.time()

	return lines
end

-- =============================================================================
-- Live Links
-- =============================================================================

-- Parse live link syntax ![...]
local function parse_live_link(text)
	local link_def = text:match("^!%[([^%]]+)%]")
	if link_def then
		return parser.parse_link_definition(link_def)
	end
	return nil
end

-- Register a live link for updates
local function register_live_link(link_id, link_def, digest_lnum)
	state.live_links[link_id] = {
		definition = link_def,
		digest_lnum = digest_lnum,
		last_content = nil,
	}
end

-- Update live link content in digest
local function update_live_link(link_id)
	local link_info = state.live_links[link_id]
	if not link_info then
		return
	end

	-- Resolve the link to get current content
	local link_resolver = require("zortex.utils.link_resolver")
	local results = link_resolver.process_link(link_info.definition)

	if #results > 0 then
		local result = results[1]
		local doc = workspace.get_for_buffer(vim.fn.bufadd(result.file))

		if doc then
			-- Get the line content
			local line = doc:get_line(result.lnum)

			-- Check if content changed
			if line ~= link_info.last_content then
				link_info.last_content = line

				-- Update digest buffer if open
				local digest_path = fs.get_digest_file()
				local digest_bufnr = vim.fn.bufadd(digest_path)

				if vim.api.nvim_buf_is_loaded(digest_bufnr) then
					-- Preserve the link syntax while updating content
					local new_line = line:gsub("^%s*%-?%s*", "- ![" .. link_info.definition.components[1].text .. "] ")
					vim.api.nvim_buf_set_lines(
						digest_bufnr,
						link_info.digest_lnum - 1,
						link_info.digest_lnum,
						false,
						{ new_line }
					)
				end
			end
		end
	end
end

-- Setup file watchers for live links
local function setup_live_link_watchers()
	-- Clear existing watchers
	for _, watcher in pairs(state.watchers) do
		pcall(function()
			watcher:stop()
		end)
	end
	state.watchers = {}

	-- Setup document change listeners
	Events.on("workspace:lines_changed", function(data)
		-- Check if any live links need updating
		for link_id, _ in pairs(state.live_links) do
			update_live_link(link_id)
		end
	end)
end

-- Public method to register live link from cursor position
function M.register_live_link_from_cursor(link_id, link_def, lnum)
	register_live_link(link_id, link_def, lnum)
	-- Immediately update to get current content
	update_live_link(link_id)
end

-- =============================================================================
-- File Operations
-- =============================================================================

-- Save digest to file
function M.save_digest(lines)
	local path = fs.get_digest_file()
	return fs.write_lines(path, lines)
end

-- Load and setup digest
function M.load_digest()
	local path = fs.get_digest_file()

	-- Generate if doesn't exist or is old
	if not fs.file_exists(path) or M.needs_update() then
		M.update_digest()
	end

	-- Open in buffer
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	local bufnr = vim.api.nvim_get_current_buf()

	-- Parse live links
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	state.live_links = {}

	for lnum, line in ipairs(lines) do
		local link_def = parse_live_link(line)
		if link_def then
			local link_id = table.concat(
				vim.tbl_map(function(c)
					return c.text
				end, link_def.components),
				"/"
			)
			register_live_link(link_id, link_def, lnum)
		end
	end

	-- Setup watchers
	setup_live_link_watchers()

	-- Set buffer options
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].buftype = "nowrite"

	return bufnr
end

-- Check if digest needs update
function M.needs_update()
	if not state.last_generated then
		local path = fs.get_digest_file()
		if fs.file_exists(path) then
			local stat = vim.loop.fs_stat(path)
			if stat then
				-- Check if file is from today
				local file_date = os.date("*t", stat.mtime.sec)
				local today = os.date("*t")

				if file_date.year == today.year and file_date.month == today.month and file_date.day == today.day then
					state.last_generated = stat.mtime.sec
					return false
				end
			end
		end
		return true
	end

	-- Check if it's a new day
	local last_date = os.date("*t", state.last_generated)
	local today = os.date("*t")

	return last_date.year ~= today.year or last_date.month ~= today.month or last_date.day ~= today.day
end

-- Update digest
function M.update_digest()
	Logger.info("digest", "Generating daily digest")

	local lines = M.generate_digest()
	M.save_digest(lines)

	-- Reload if buffer is open
	local path = fs.get_digest_file()
	local bufnr = vim.fn.bufnr(path)

	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modifiable = false

		-- Re-parse live links
		state.live_links = {}
		for lnum, line in ipairs(lines) do
			local link_def = parse_live_link(line)
			if link_def then
				local link_id = table.concat(
					vim.tbl_map(function(c)
						return c.text
					end, link_def.components),
					"/"
				)
				register_live_link(link_id, link_def, lnum)
			end
		end
	end

	Events.emit("digest:updated", { lines = #lines })
end

-- =============================================================================
-- Auto-update
-- =============================================================================

-- Setup auto-update timer
function M.setup_auto_update()
	-- Clear existing timer
	if state.update_timer then
		state.update_timer:stop()
		state.update_timer = nil
	end

	-- Check every hour if digest needs update
	state.update_timer = vim.loop.new_timer()
	state.update_timer:start(
		60000, -- Initial delay: 1 minute
		3600000, -- Repeat: every hour
		vim.schedule_wrap(function()
			if M.needs_update() then
				M.update_digest()
			end
		end)
	)
end

-- =============================================================================
-- Commands
-- =============================================================================

function M.open_digest()
	M.load_digest()
end

function M.force_update()
	M.update_digest()
	vim.notify("Digest updated", vim.log.levels.INFO)
end

-- Setup
function M.setup()
	M.setup_auto_update()

	-- Update digest on calendar changes
	Events.on("calendar:entry_added", function()
		if M.needs_update() then
			vim.defer_fn(function()
				M.update_digest()
			end, 100)
		end
	end)

	-- Update digest on task completion
	Events.on("task:completed", function()
		vim.defer_fn(function()
			M.update_digest()
		end, 100)
	end)
end

return M
