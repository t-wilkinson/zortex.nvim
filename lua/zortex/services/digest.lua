-- services/digest.lua - The daily digest: a note (digest.zortex) and an email
--
-- Both are built from services/agenda. notifications/types/digest decides
-- when to send the email; this module decides what is in it.
local M = {}

local Logger = require("zortex.core.logger")
local datetime = require("zortex.utils.datetime")
local fs = require("zortex.utils.filesystem")
local link_mod = require("zortex.core.link")
local Events = require("zortex.core.event_bus")

-- =============================================================================
-- State Management
-- =============================================================================

local state = {
	last_generated = nil,
	live_links = {}, -- Track live link subscriptions
	watchers = {}, -- File watchers for live links
}

-- =============================================================================
-- Data Collection
-- =============================================================================

local function agenda()
	return require("zortex.services.agenda")
end

-- Calendar events for the next month: { { date, entry }, ... } by date
local function get_upcoming_events()
	local events = {}
	for _, day in ipairs(agenda().upcoming(31, { kinds = { event = true } })) do
		for _, item in ipairs(day.items) do
			events[#events + 1] = { date = day.date, entry = item.entry, priority = item.priority }
		end
	end
	return events
end

-- Today's open calendar tasks
local function get_todays_tasks()
	local tasks = {}
	local today = os.date("%Y-%m-%d")
	for _, item in ipairs(agenda().day(today)) do
		if item.kind == "task" and not item.done then
			tasks[#tasks + 1] = { entry = item.entry, priority = item.priority, importance = item.entry.attributes.i }
		end
	end
	return tasks
end

-- High priority / importance (1-2) projects that still have work left
local function get_priority_items()
	local projects = require("zortex.services.projects").query({
		sort = "priority",
		include_done = false,
		filter = function(p)
			local pri, imp = tonumber(p.attributes.p), tonumber(p.attributes.i)
			return (pri and pri <= 2) or (imp and imp <= 2)
		end,
	})
	return { projects = projects, tasks = {} }
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
			local line = string.format("- [ ] %s", entry.text)
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
			local line = string.format("- !%s", project.link)
			if project.attributes.p then
				line = line .. " @p" .. project.attributes.p
			end
			if project.attributes.i then
				line = line .. " @i" .. project.attributes.i
			end
			if project.attributes.due then
				line = line .. " @due(" .. datetime.format_datetime(project.attributes.due, "YYYY-MM-DD") .. ")"
			end
			table.insert(lines, line)
		end
		table.insert(lines, "")
	end

	-- Upcoming Due Tasks (project tasks due in the next 8 days)
	local due_soon = {}
	for _, day in ipairs(agenda().upcoming(8, { kinds = { due = true } })) do
		vim.list_extend(due_soon, day.items)
	end

	if #due_soon > 0 then
		table.insert(lines, "## Tasks Due This Week")
		table.insert(lines, "")
		for _, item in ipairs(due_soon) do
			local line = string.format("- [ ] %s", item.text)
			if item.project and item.project.link then
				line = line .. " !" .. item.project.link
			end
			line = line .. " @due(" .. item.date .. ")"
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
		return link_mod.parse(link_def)
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
	local result = link_mod.resolve_first(link_info.definition)

	if result then
		local doc = result.doc

		if doc then
			-- Get the line content
			local line = doc:line(result.lnum)

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
			local stat = vim.uv.fs_stat(path)
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

return M
