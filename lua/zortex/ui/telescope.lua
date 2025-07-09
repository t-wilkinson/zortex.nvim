-- ui/telescope.lua - Unified Telescope interface for Zortex
local M = {}

-- Core dependencies
local parser = require("zortex.core.parser")
local buffer = require("zortex.core.buffer")
local fs = require("zortex.core.filesystem")
local search = require("zortex.core.search")

-- Feature dependencies
local calendar = require("zortex.features.calendar")
local projects = require("zortex.features.projects")
local xp = require("zortex.features.xp")
local skills = require("zortex.features.skills")

-- Telescope dependencies
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")
local entry_display = require("telescope.pickers.entry_display")

-- =============================================================================
-- Common Types and Utilities
-- =============================================================================

-- Entry types for consistent handling
local EntryType = {
	CALENDAR_EVENT = "calendar_event",
	PROJECT_TASK = "project_task",
	PROJECT = "project",
	DATE_HEADER = "date_header",
	SECTION_HEADER = "section_header",
}

-- Scoring weights for intelligent sorting
local ScoreWeights = {
	OVERDUE = 1000,
	DUE_TODAY = 500,
	PRIORITY_HIGH = 300,
	PRIORITY_MEDIUM = 200,
	PRIORITY_LOW = 100,
	HAS_TIME = 50,
	UPCOMING = 20,
	COMPLETED = -500,
}

-- =============================================================================
-- Scoring and Prioritization Engine
-- =============================================================================

local Scorer = {}

function Scorer.calculate_date_score(date_str)
	local today = os.date("%Y-%m-%d")
	local date_obj = parser.parse_date(date_str)
	if not date_obj then
		return 0
	end

	local date_time = os.time(date_obj)
	local today_time = os.time(parser.parse_date(today))
	local days_diff = math.floor((date_time - today_time) / 86400)

	if days_diff < 0 then
		return ScoreWeights.OVERDUE + math.abs(days_diff) * 10
	elseif days_diff == 0 then
		return ScoreWeights.DUE_TODAY
	elseif days_diff <= 7 then
		return ScoreWeights.UPCOMING - days_diff
	else
		return 0
	end
end

function Scorer.calculate_priority_score(priority)
	if not priority then
		return 0
	end

	local priority_lower = priority:lower()
	if priority_lower:match("high") or priority_lower:match("urgent") or priority_lower == "!" then
		return ScoreWeights.PRIORITY_HIGH
	elseif priority_lower:match("medium") or priority_lower == "!!" then
		return ScoreWeights.PRIORITY_MEDIUM
	elseif priority_lower:match("low") or priority_lower == "!!!" then
		return ScoreWeights.PRIORITY_LOW
	end

	return 0
end

function Scorer.calculate_entry_score(entry)
	local score = 0

	-- Date-based scoring
	if entry.date then
		score = score + Scorer.calculate_date_score(entry.date)
	end

	-- Attribute-based scoring
	if entry.attributes then
		-- Priority
		if entry.attributes.priority then
			score = score + Scorer.calculate_priority_score(entry.attributes.priority)
		end

		-- Time scheduling
		if entry.attributes.at or entry.attributes.from then
			score = score + ScoreWeights.HAS_TIME
		end

		-- Due dates
		if entry.attributes.due then
			score = score + Scorer.calculate_date_score(entry.attributes.due)
		end
	end

	-- Status-based scoring
	if entry.task_status and entry.task_status.key == "[x]" then
		score = score + ScoreWeights.COMPLETED
	end

	return score
end

-- =============================================================================
-- Entry Builders
-- =============================================================================

local EntryBuilder = {}

function EntryBuilder.create_calendar_entry(parsed_entry, date_str)
	local entry = {
		type = EntryType.CALENDAR_EVENT,
		data = parsed_entry,
		date = date_str,
		attributes = parsed_entry.attributes or {},
		task_status = parsed_entry.task_status,
		score = 0,
	}

	-- Build display components
	local display_parts = {}

	-- Status icon
	if parsed_entry.type == "task" and parsed_entry.task_status then
		table.insert(display_parts, parsed_entry.task_status.symbol)
	elseif parsed_entry.type == "event" then
		table.insert(display_parts, parsed_entry.attributes.notification_enabled and "🔔" or "📅")
	else
		table.insert(display_parts, "📝")
	end

	-- Time component
	if parsed_entry.attributes.from and parsed_entry.attributes.to then
		table.insert(display_parts, string.format("%s-%s", parsed_entry.attributes.from, parsed_entry.attributes.to))
	elseif parsed_entry.attributes.at then
		table.insert(display_parts, parsed_entry.attributes.at)
	end

	-- Text content
	table.insert(display_parts, parsed_entry.display_text)

	-- Indicators
	local indicators = {}
	if parsed_entry.attributes.priority then
		table.insert(indicators, parsed_entry.attributes.priority)
	end
	if parsed_entry.is_recurring_instance then
		table.insert(indicators, "🔁")
	end

	entry.display = table.concat(display_parts, " ")
	if #indicators > 0 then
		entry.display = entry.display .. " [" .. table.concat(indicators, " ") .. "]"
	end

	entry.ordinal = (date_str or "") .. " " .. entry.display
	entry.score = Scorer.calculate_entry_score(entry)

	return entry
end

function EntryBuilder.create_project_task_entry(task, project_name)
	local entry = {
		type = EntryType.PROJECT_TASK,
		data = task,
		project = project_name,
		attributes = task.attributes or {},
		task_status = task.status,
		score = 0,
	}

	-- Build display
	local display_parts = {}

	-- Status
	table.insert(display_parts, task.status and task.status.symbol or "☐")

	-- Time
	if task.attributes.at then
		table.insert(display_parts, task.attributes.at)
	end

	-- Task text
	table.insert(display_parts, task.display_text)

	-- Project name
	table.insert(display_parts, "[" .. project_name .. "]")

	entry.display = table.concat(display_parts, " ")
	entry.ordinal = project_name .. " " .. task.display_text
	entry.score = Scorer.calculate_entry_score(entry)

	return entry
end

function EntryBuilder.create_project_entry(project, area_name)
	local entry = {
		type = EntryType.PROJECT,
		data = project,
		area = area_name,
		score = 0,
	}

	-- Calculate project metrics
	local task_count = #project.tasks
	local completed_count = 0
	local has_priority = false
	local has_due_today = false
	local total_score = 0

	for _, task in ipairs(project.tasks) do
		if task.completed then
			completed_count = completed_count + 1
		end

		local task_entry = {
			attributes = task.attributes,
			task_status = task.status,
		}
		local task_score = Scorer.calculate_entry_score(task_entry)
		total_score = total_score + task_score

		if task.attributes then
			if task.attributes.priority then
				has_priority = true
			end
			if task.attributes.due == os.date("%Y-%m-%d") then
				has_due_today = true
			end
		end
	end

	-- Build display
	local display_parts = { "📁", project.name }

	-- Progress indicator
	if task_count > 0 then
		table.insert(display_parts, string.format("(%d/%d)", completed_count, task_count))
	end

	-- Status indicators
	local indicators = {}
	if has_priority then
		table.insert(indicators, "PRIORITY")
	end
	if has_due_today then
		table.insert(indicators, "DUE")
	end

	if #indicators > 0 then
		table.insert(display_parts, "[" .. table.concat(indicators, ",") .. "]")
	end

	-- Area name
	if area_name then
		table.insert(display_parts, "-")
		table.insert(display_parts, area_name)
	end

	entry.display = table.concat(display_parts, " ")
	entry.ordinal = project.name .. " " .. (area_name or "")
	entry.score = task_count > 0 and (total_score / task_count) or 0

	-- Adjust for completion
	if task_count > 0 and completed_count / task_count > 0.8 then
		entry.score = entry.score * 0.5
	end

	return entry
end

function EntryBuilder.create_header_entry(text, sort_key)
	return {
		type = EntryType.SECTION_HEADER,
		display = "═══ " .. text .. " ═══",
		ordinal = sort_key or "0000",
		score = 10000, -- Headers always sort first
	}
end

-- =============================================================================
-- Preview Builders
-- =============================================================================

local PreviewBuilder = {}

function PreviewBuilder.build_calendar_preview(entry)
	local lines = {}
	local data = entry.data

	-- Date header
	table.insert(lines, "Date: " .. (entry.date or "Unknown"))
	table.insert(lines, "")

	-- Type and status
	table.insert(lines, "Type: " .. (data.type or "note"))
	if data.task_status then
		table.insert(lines, "Status: " .. data.task_status.name .. " " .. data.task_status.symbol)
	end
	table.insert(lines, "")

	-- Time information
	if data.attributes.from and data.attributes.to then
		table.insert(lines, "Time: " .. data.attributes.from .. " - " .. data.attributes.to)
	elseif data.attributes.at then
		table.insert(lines, "Time: " .. data.attributes.at)
	end

	-- Other attributes
	if data.attributes.priority then
		table.insert(lines, "Priority: " .. data.attributes.priority)
	end
	if data.attributes.due then
		table.insert(lines, "Due: " .. data.attributes.due)
	end
	if data.attributes.repeating then
		table.insert(lines, "Repeat: " .. data.attributes.repeating)
	end

	-- Content
	table.insert(lines, "")
	table.insert(lines, "Content:")
	table.insert(lines, string.rep("─", 40))
	table.insert(lines, data.display_text)

	-- Recurring info
	if data.is_recurring_instance then
		table.insert(lines, "")
		table.insert(lines, "Note: This is a recurring event")
		if data.original_date then
			table.insert(lines, "Original date: " .. data.original_date)
		end
	end

	return lines
end

function PreviewBuilder.build_project_preview(project)
	local lines = {}

	-- Project header
	table.insert(lines, "PROJECT: " .. project.name)
	table.insert(lines, string.rep("═", 50))
	table.insert(lines, "")

	-- Attributes
	if project.attributes and next(project.attributes) then
		table.insert(lines, "Attributes:")
		for key, value in pairs(project.attributes) do
			table.insert(lines, "  " .. key .. ": " .. tostring(value))
		end
		table.insert(lines, "")
	end

	-- Task summary
	local task_count = #project.tasks
	local completed_count = 0
	for _, task in ipairs(project.tasks) do
		if task.completed then
			completed_count = completed_count + 1
		end
	end

	table.insert(
		lines,
		string.format(
			"Progress: %d/%d tasks (%.0f%%)",
			completed_count,
			task_count,
			task_count > 0 and (completed_count / task_count * 100) or 0
		)
	)
	table.insert(lines, "")

	-- Task list
	if task_count > 0 then
		table.insert(lines, "Tasks:")
		table.insert(lines, string.rep("─", 40))
		for _, task in ipairs(project.tasks) do
			local line = "  "
			if task.status then
				line = line .. task.status.symbol .. " "
			else
				line = line .. "☐ "
			end

			if task.attributes.at then
				line = line .. task.attributes.at .. " "
			end

			line = line .. task.display_text

			-- Task attributes
			local attrs = {}
			if task.attributes.priority then
				table.insert(attrs, task.attributes.priority)
			end
			if task.attributes.due then
				table.insert(attrs, "📅 " .. task.attributes.due)
			end

			if #attrs > 0 then
				line = line .. " (" .. table.concat(attrs, ", ") .. ")"
			end

			table.insert(lines, line)
		end
	end

	-- Child projects
	if project.children and #project.children > 0 then
		table.insert(lines, "")
		table.insert(lines, "Sub-projects:")
		table.insert(lines, string.rep("─", 40))
		for _, child in ipairs(project.children) do
			table.insert(lines, "  • " .. child.name)
		end
	end

	return lines
end

-- =============================================================================
-- Main Telescope Pickers
-- =============================================================================

-- Calendar view with intelligent sorting
function M.calendar(opts)
	opts = opts or {}

	-- Load data
	calendar.load()

	local entries = {}
	local all_entries = calendar.get_all_entries()

	-- Build entries for all dates
	for date_str, date_entries in pairs(all_entries) do
		for _, parsed_entry in ipairs(date_entries) do
			local entry = EntryBuilder.create_calendar_entry(parsed_entry, date_str)
			table.insert(entries, entry)
		end
	end

	-- Sort by score (highest first) then by date/time
	table.sort(entries, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		if a.date ~= b.date then
			return a.date > b.date
		end
		local a_time = a.attributes.at or "00:00"
		local b_time = b.attributes.at or "00:00"
		return a_time < b_time
	end)

	-- Create picker
	pickers
		.new(opts, {
			prompt_title = "📅 Calendar Search",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.display,
						ordinal = entry.ordinal,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				title = "Calendar Entry Details",
				define_preview = function(self, entry)
					local lines = PreviewBuilder.build_calendar_preview(entry.value)
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.api.nvim_buf_set_option(self.state.bufnr, "filetype", "markdown")
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						local entry = selection.value
						-- Open calendar file at the date
						local cal_file = fs.get_file_path("calendar.zortex")
						if cal_file then
							vim.cmd("edit " .. vim.fn.fnameescape(cal_file))
							-- Search for the date header
							vim.fn.search(entry.date:match("(%d%d%d%d)%-(%d%d)%-(%d%d)"))
						end
					end
				end)

				-- Additional mappings
				map("i", "<C-t>", function()
					-- Toggle task completion
					local selection = action_state.get_selected_entry()
					if selection and selection.value.type == EntryType.CALENDAR_EVENT then
						local entry = selection.value
						if entry.task_status then
							-- TODO: Implement task toggle
							vim.notify("Task toggle not yet implemented", vim.log.levels.INFO)
						end
					end
				end)

				return true
			end,
		})
		:find()
end

-- Project browser with hierarchical view
function M.projects(opts)
	opts = opts or {}

	-- Load project data
	projects.load()

	local entries = {}
	local all_projects = projects.get_all_projects()

	-- Group projects by area/parent
	local areas = {}
	for _, project in ipairs(all_projects) do
		if not project.parent then
			-- Top-level project or area
			local area_name = project.name
			if not areas[area_name] then
				areas[area_name] = {
					name = area_name,
					projects = {},
				}
			end
			table.insert(areas[area_name].projects, project)
		end
	end

	-- Build entries
	for area_name, area in pairs(areas) do
		-- Add area header
		table.insert(entries, EntryBuilder.create_header_entry(area_name, area_name))

		-- Add projects in this area
		for _, project in ipairs(area.projects) do
			local entry = EntryBuilder.create_project_entry(project, area_name)
			table.insert(entries, entry)
		end
	end

	-- Sort entries
	table.sort(entries, function(a, b)
		-- Headers first
		if a.type ~= b.type then
			if a.type == EntryType.SECTION_HEADER then
				return true
			end
			if b.type == EntryType.SECTION_HEADER then
				return false
			end
		end

		-- Then by score
		if a.score ~= b.score then
			return a.score > b.score
		end

		-- Finally by name
		return a.ordinal < b.ordinal
	end)

	-- Create picker
	pickers
		.new(opts, {
			prompt_title = "📁 Projects",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.display,
						ordinal = entry.ordinal,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				title = "Project Details",
				define_preview = function(self, entry)
					if entry.value.type == EntryType.PROJECT then
						local lines = PreviewBuilder.build_project_preview(entry.value.data)
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
						vim.api.nvim_buf_set_option(self.state.bufnr, "filetype", "markdown")
					else
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { entry.value.display })
					end
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection and selection.value.type == EntryType.PROJECT then
						local project = selection.value.data
						-- Open projects file at project location
						local proj_file = fs.get_projects_file()
						if proj_file then
							vim.cmd("edit " .. vim.fn.fnameescape(proj_file))
							vim.api.nvim_win_set_cursor(0, { project.line_num, 0 })
						end
					end
				end)

				-- Task view for project
				map("i", "<C-t>", function()
					local selection = action_state.get_selected_entry()
					if selection and selection.value.type == EntryType.PROJECT then
						actions.close(prompt_bufnr)
						M.project_tasks(vim.tbl_extend("force", opts, {
							project = selection.value.data,
						}))
					end
				end)

				return true
			end,
		})
		:find()
end

-- Today's digest view
function M.today_digest(opts)
	opts = opts or {}

	-- Load all data
	calendar.load()
	projects.load()

	local entries = {}
	local today = os.date("%Y-%m-%d")
	local now = os.time()

	-- Add today header
	table.insert(entries, EntryBuilder.create_header_entry("TODAY - " .. os.date("%A, %B %d"), "0000"))

	-- Get today's calendar entries
	local today_entries = calendar.get_entries_for_date(today)
	for _, entry in ipairs(today_entries) do
		table.insert(entries, EntryBuilder.create_calendar_entry(entry, today))
	end

	-- Get today's project tasks
	local project_tasks = calendar.get_project_tasks_for_date(today)
	for _, task in ipairs(project_tasks) do
		table.insert(entries, EntryBuilder.create_project_task_entry(task, task.project or "Unknown"))
	end

	-- Add upcoming section (next 7 days)
	table.insert(entries, EntryBuilder.create_header_entry("UPCOMING", "1000"))

	local upcoming_events = calendar.get_upcoming_events(7)
	for _, event in ipairs(upcoming_events) do
		if event.date ~= today then
			table.insert(entries, EntryBuilder.create_calendar_entry(event.entry, event.date))
		end
	end

	-- Sort entries (preserving header positions)
	table.sort(entries, function(a, b)
		-- Headers use ordinal for sorting
		if a.type == EntryType.SECTION_HEADER or b.type == EntryType.SECTION_HEADER then
			return a.ordinal < b.ordinal
		end

		-- Within sections, sort by score
		return a.score > b.score
	end)

	-- Create picker with custom display
	pickers
		.new(opts, {
			prompt_title = "📋 Today's Digest",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					local displayer = entry_display.create({
						separator = " ",
						items = {
							{ width = 3 },
							{ width = 8 },
							{ remaining = true },
						},
					})

					local make_display = function(e)
						local icon = ""
						local time = ""

						if e.value.type == EntryType.SECTION_HEADER then
							return e.value.display
						elseif e.value.type == EntryType.CALENDAR_EVENT then
							icon = e.value.data.task_status and e.value.data.task_status.symbol or "📅"
							time = e.value.attributes.at or ""
						elseif e.value.type == EntryType.PROJECT_TASK then
							icon = e.value.task_status and e.value.task_status.symbol or "☐"
							time = e.value.attributes.at or ""
						end

						return displayer({
							icon,
							time,
							e.value.display,
						})
					end

					return {
						value = entry,
						display = make_display,
						ordinal = entry.ordinal,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				title = "Details",
				define_preview = function(self, entry)
					local lines = {}
					if entry.value.type == EntryType.CALENDAR_EVENT then
						lines = PreviewBuilder.build_calendar_preview(entry.value)
					elseif entry.value.type == EntryType.PROJECT_TASK then
						lines = { "Task from project: " .. (entry.value.project or "Unknown") }
						table.insert(lines, "")
						table.insert(lines, entry.value.display)
					else
						lines = { entry.value.display }
					end
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						local entry = selection.value
						if entry.type == EntryType.CALENDAR_EVENT then
							-- Open calendar at date
							local cal_file = fs.get_file_path("calendar.zortex")
							if cal_file then
								vim.cmd("edit " .. vim.fn.fnameescape(cal_file))
							end
						elseif entry.type == EntryType.PROJECT_TASK then
							-- Open project file
							local proj_file = fs.get_projects_file()
							if proj_file then
								vim.cmd("edit " .. vim.fn.fnameescape(proj_file))
							end
						end
					end
				end)
				return true
			end,
		})
		:find()
end

-- Project tasks view
function M.project_tasks(opts)
	opts = opts or {}
	local project = opts.project

	if not project then
		vim.notify("No project specified", vim.log.levels.ERROR)
		return
	end

	local entries = {}

	-- Add project header
	table.insert(entries, EntryBuilder.create_header_entry(project.name, "0000"))

	-- Add all tasks
	for i, task in ipairs(project.tasks) do
		local entry = EntryBuilder.create_project_task_entry(task, project.name)
		entry.task_index = i
		table.insert(entries, entry)
	end

	-- Sort by score
	table.sort(entries, function(a, b)
		if a.type == EntryType.SECTION_HEADER then
			return true
		end
		if b.type == EntryType.SECTION_HEADER then
			return false
		end
		return a.score > b.score
	end)

	-- Create picker
	pickers
		.new(opts, {
			prompt_title = "📋 Tasks: " .. project.name,
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.display,
						ordinal = entry.ordinal,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				title = "Task Details",
				define_preview = function(self, entry)
					if entry.value.type == EntryType.PROJECT_TASK then
						local task = entry.value.data
						local lines = {
							"Task: " .. task.display_text,
							"Status: " .. (task.status and task.status.name or "Incomplete"),
							"",
						}

						if task.attributes.priority then
							table.insert(lines, "Priority: " .. task.attributes.priority)
						end
						if task.attributes.due then
							table.insert(lines, "Due: " .. task.attributes.due)
						end
						if task.attributes.at then
							table.insert(lines, "Time: " .. task.attributes.at)
						end

						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					end
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection and selection.value.type == EntryType.PROJECT_TASK then
						-- Open at task location
						local proj_file = fs.get_projects_file()
						if proj_file then
							vim.cmd("edit " .. vim.fn.fnameescape(proj_file))
							local task = selection.value.data
							if task.line_num then
								vim.api.nvim_win_set_cursor(0, { task.line_num, 0 })
							end
						end
					end
				end)
				return true
			end,
		})
		:find()
end

-- Area overview with XP integration
function M.areas(opts)
	opts = opts or {}

	-- Get area stats from XP system
	local area_stats = xp.get_area_stats()
	local entries = {}

	for area_path, stats in pairs(area_stats) do
		local entry = {
			type = "area",
			path = area_path,
			stats = stats,
			display = string.format(
				"🎯 %s - Level %d (%.0f%% to next)",
				area_path,
				stats.level,
				stats.progress * 100
			),
			ordinal = area_path,
			score = stats.xp,
		}
		table.insert(entries, entry)
	end

	-- Sort by XP (highest first)
	table.sort(entries, function(a, b)
		return a.score > b.score
	end)

	-- Create picker
	pickers
		.new(opts, {
			prompt_title = "🎯 Areas & Progress",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.display,
						ordinal = entry.ordinal,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				title = "Area Statistics",
				define_preview = function(self, entry)
					local stats = entry.value.stats
					local lines = {
						"Area: " .. entry.value.path,
						string.rep("─", 40),
						"",
						string.format("Level: %d", stats.level),
						string.format("Total XP: %d", stats.xp),
						string.format("Progress to Level %d: %.1f%%", stats.level + 1, stats.progress * 100),
						string.format("XP to Next Level: %d", stats.xp_to_next),
					}
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
		})
		:find()
end

return M
