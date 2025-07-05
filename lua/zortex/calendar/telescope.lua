-- Enhanced Telescope integration for Zortex system
-- Provides searchable views of calendar entries, projects, and daily digests

local M = {}

local Utils = require("zortex.calendar.utils")
local projects = require("zortex.calendar.projects")

-- =============================================================================
-- Helper Functions
-- =============================================================================

--- Parse OKR files to find linked projects
local function parse_okr_links()
	local linked_projects = {}
	local notes_dir = vim.g.zortex_notes_dir
	local extension = vim.g.zortex_extension or ".zortex"

	-- Parse objectives.zortex and keyresults.zortex
	local okr_files = { "objectives", "keyresults" }

	for _, filename in ipairs(okr_files) do
		local filepath = notes_dir .. "/" .. filename .. extension
		if vim.fn.filereadable(filepath) == 1 then
			for line in io.lines(filepath) do
				-- Look for project links in various formats
				-- [Projects/#ProjectName] or [P/#ProjectName]
				local project_name = line:match("%[Projects?/#([^%]]+)%]")
				if not project_name then
					project_name = line:match("%[P/#([^%]]+)%]")
				end

				if project_name then
					linked_projects[project_name] = true
				end
			end
		end
	end

	return linked_projects
end

--- Calculate task priority score for sorting
local function calculate_task_score(task, okr_linked_projects)
	local score = 0

	-- Priority scoring
	if task.attributes and task.attributes.priority then
		if task.attributes.priority == "p1" then
			score = score + 100
		elseif task.attributes.priority == "p2" then
			score = score + 50
		elseif task.attributes.priority == "p3" then
			score = score + 25
		end
	end

	-- Due date scoring
	if task.attributes and task.attributes.due then
		local due_dt = Utils.parse_datetime(task.attributes.due)
		if due_dt then
			local due_time = os.time(due_dt)
			local now = os.time()
			local days_until = (due_time - now) / 86400

			if days_until < 0 then
				score = score + 200 -- Overdue
			elseif days_until < 1 then
				score = score + 150 -- Due today
			elseif days_until < 3 then
				score = score + 75 -- Due soon
			elseif days_until < 7 then
				score = score + 30 -- Due this week
			end
		end
	end

	-- Heat scoring (if available from XP system)
	if task.heat then
		score = score + (task.heat * 20)
	end

	-- OKR linkage scoring
	if okr_linked_projects[task.project] then
		score = score + 80
	end

	-- Task status penalty (completed tasks score lower)
	if task.task_status and task.task_status.key == "[x]" then
		score = score - 100
	end

	return score
end

--- Get date display info
local function get_date_display_info(date_str)
	local y, m, d = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
	if not y then
		return nil
	end

	local date_obj = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
	local today = os.time()
	local today_str = os.date("%Y-%m-%d", today)

	-- Calculate relative position
	local days_diff = math.floor((date_obj - today) / 86400)
	local relative_str = ""

	if date_str == today_str then
		relative_str = " (Today)"
	elseif days_diff == 1 then
		relative_str = " (Tomorrow)"
	elseif days_diff == -1 then
		relative_str = " (Yesterday)"
	elseif days_diff > 1 and days_diff <= 7 then
		relative_str = string.format(" (In %d days)", days_diff)
	elseif days_diff < -1 and days_diff >= -7 then
		relative_str = string.format(" (%d days ago)", -days_diff)
	end

	return {
		date_obj = date_obj,
		display_date = os.date("%A, %B %d, %Y", date_obj),
		short_date = os.date("%a, %b %d", date_obj),
		relative = relative_str,
		days_diff = days_diff,
		is_today = date_str == today_str,
	}
end

-- =============================================================================
-- Today's Digest View
-- =============================================================================

--- Create a telescope view for today's digest and upcoming events
function M.telescope_today_digest(opts)
	opts = opts or {}

	-- Load data
	Utils.load()
	projects.load()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	local entries = {}
	local today = os.date("%Y-%m-%d")
	local now = os.time()
	local week_from_now = now + (7 * 86400)

	-- Get today's entries
	local today_entries = Utils.get_entries_for_date(today)
	local today_tasks = projects.get_tasks_for_date(today)

	-- Add section header for today
	table.insert(entries, {
		type = "header",
		display = "═══ TODAY ═══",
		ordinal = "0000", -- Ensure headers sort first
	})

	-- Add today's calendar entries
	for _, entry in ipairs(today_entries) do
		local time_str = ""
		if entry.attributes.from and entry.attributes.to then
			time_str = string.format("%s-%s ", entry.attributes.from, entry.attributes.to)
		elseif entry.attributes.at then
			time_str = entry.attributes.at .. " "
		end

		local icon = "📅"
		if entry.type == "task" then
			icon = entry.task_status and entry.task_status.symbol or "☐"
		elseif entry.attributes.notification_enabled then
			icon = "🔔"
		end

		table.insert(entries, {
			type = "calendar_entry",
			entry = entry,
			display = string.format("%s %s%s", icon, time_str, entry.display_text),
			ordinal = "0001" .. (time_str or "0000") .. entry.display_text,
			date = today,
			time = time_str,
		})
	end

	-- Add today's project tasks
	for _, task in ipairs(today_tasks) do
		local time_str = ""
		if task.attributes.at then
			time_str = task.attributes.at .. " "
		end

		local icon = task.task_status and task.task_status.symbol or "☐"

		table.insert(entries, {
			type = "project_task",
			task = task,
			display = string.format("%s %s%s [%s]", icon, time_str, task.display_text, task.project),
			ordinal = "0002" .. (time_str or "0000") .. task.display_text,
			date = today,
			time = time_str,
		})
	end

	-- Add upcoming events (next 7 days)
	local upcoming_dates = {}
	for days = 1, 7 do
		local date = os.date("%Y-%m-%d", now + (days * 86400))
		table.insert(upcoming_dates, date)
	end

	-- Add section header for upcoming
	table.insert(entries, {
		type = "header",
		display = "═══ UPCOMING THIS WEEK ═══",
		ordinal = "0100",
	})

	-- Process each upcoming date
	for _, date_str in ipairs(upcoming_dates) do
		local date_info = get_date_display_info(date_str)
		local date_entries = Utils.get_entries_for_date(date_str)
		local date_tasks = projects.get_tasks_for_date(date_str)

		-- Only add date header if there are entries
		if #date_entries > 0 or #date_tasks > 0 then
			table.insert(entries, {
				type = "date_header",
				display = string.format("── %s%s ──", date_info.short_date, date_info.relative),
				ordinal = "01" .. string.format("%02d", date_info.days_diff) .. "0000",
				date = date_str,
			})

			-- Add calendar entries for this date
			for _, entry in ipairs(date_entries) do
				local time_str = ""
				if entry.attributes.from and entry.attributes.to then
					time_str = string.format("%s-%s ", entry.attributes.from, entry.attributes.to)
				elseif entry.attributes.at then
					time_str = entry.attributes.at .. " "
				end

				local icon = "📅"
				if entry.type == "task" then
					icon = entry.task_status and entry.task_status.symbol or "☐"
				elseif entry.attributes.notification_enabled then
					icon = "🔔"
				end

				table.insert(entries, {
					type = "calendar_entry",
					entry = entry,
					display = string.format("  %s %s%s", icon, time_str, entry.display_text),
					ordinal = "01" .. string.format("%02d", date_info.days_diff) .. "01" .. (time_str or "0000"),
					date = date_str,
					time = time_str,
				})
			end

			-- Add project tasks for this date
			for _, task in ipairs(date_tasks) do
				local time_str = ""
				if task.attributes.at then
					time_str = task.attributes.at .. " "
				end

				local icon = task.task_status and task.task_status.symbol or "☐"

				table.insert(entries, {
					type = "project_task",
					task = task,
					display = string.format("  %s %s%s [%s]", icon, time_str, task.display_text, task.project),
					ordinal = "01" .. string.format("%02d", date_info.days_diff) .. "02" .. (time_str or "0000"),
					date = date_str,
					time = time_str,
				})
			end
		end
	end

	-- Also check for items with date ranges that span into the week
	local all_entries = Utils.get_all_parsed_entries()

	table.insert(entries, {
		type = "header",
		display = "═══ ONGOING/RANGED EVENTS ═══",
		ordinal = "0200",
	})

	local ranged_items = {}
	for date_str, date_entries in pairs(all_entries) do
		for _, entry in ipairs(date_entries) do
			if entry.attributes.from or entry.attributes.to then
				local from_dt = Utils.parse_datetime(entry.attributes.from, date_str)
				local to_dt = Utils.parse_datetime(entry.attributes.to, date_str)

				if from_dt or to_dt then
					local from_time = from_dt and os.time(from_dt) or now
					local to_time = to_dt and os.time(to_dt) or week_from_now

					-- Check if range overlaps with our time window
					if from_time <= week_from_now and to_time >= now then
						local range_str = ""
						if from_dt and to_dt then
							range_str =
								string.format("%s to %s", os.date("%m/%d", from_time), os.date("%m/%d", to_time))
						elseif from_dt then
							range_str = string.format("From %s", os.date("%m/%d", from_time))
						else
							range_str = string.format("Until %s", os.date("%m/%d", to_time))
						end

						table.insert(ranged_items, {
							type = "ranged_entry",
							entry = entry,
							display = string.format("  📅 %s: %s", range_str, entry.display_text),
							ordinal = "0201" .. string.format("%010d", from_time),
							from_time = from_time,
							to_time = to_time,
							range_str = range_str,
						})
					end
				end
			end
		end
	end

	-- Sort and add ranged items
	table.sort(ranged_items, function(a, b)
		return a.from_time < b.from_time
	end)
	for _, item in ipairs(ranged_items) do
		table.insert(entries, item)
	end

	-- Create the picker
	pickers
		.new(opts, {
			prompt_title = "Today's Digest & Upcoming Events",
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
				title = "Details",
				define_preview = function(self, entry)
					local lines = {}
					local e = entry.value

					if e.type == "header" or e.type == "date_header" then
						-- Headers don't need preview
						table.insert(lines, e.display)
					elseif e.type == "calendar_entry" then
						-- Calendar entry preview
						local entry_data = e.entry
						table.insert(lines, "Type: Calendar Entry")
						table.insert(lines, "Date: " .. e.date)
						if e.time and e.time ~= "" then
							table.insert(lines, "Time: " .. e.time:gsub("^%s+", ""):gsub("%s+$", ""))
						end
						table.insert(lines, "")
						table.insert(lines, "Content:")
						table.insert(lines, "  " .. entry_data.display_text)

						-- Show attributes
						if entry_data.attributes and next(entry_data.attributes) then
							table.insert(lines, "")
							table.insert(lines, "Attributes:")
							for key, value in pairs(entry_data.attributes) do
								if key ~= "notification_durations" then
									table.insert(lines, string.format("  %s: %s", key, tostring(value)))
								end
							end
						end

						-- Show if recurring
						if entry_data.is_recurring_instance then
							table.insert(lines, "")
							table.insert(lines, "🔁 This is a recurring event")
						end
					elseif e.type == "project_task" then
						-- Project task preview
						local task = e.task
						table.insert(lines, "Type: Project Task")
						table.insert(lines, "Project: " .. task.project)
						table.insert(lines, "Area: " .. (task.area or "Unknown"))
						table.insert(lines, "Date: " .. e.date)
						if e.time and e.time ~= "" then
							table.insert(lines, "Time: " .. e.time:gsub("^%s+", ""):gsub("%s+$", ""))
						end
						table.insert(lines, "")
						table.insert(lines, "Task:")
						table.insert(lines, "  " .. task.display_text)

						-- Show attributes
						if task.attributes and next(task.attributes) then
							table.insert(lines, "")
							table.insert(lines, "Attributes:")
							for key, value in pairs(task.attributes) do
								table.insert(lines, string.format("  %s: %s", key, tostring(value)))
							end
						end
					elseif e.type == "ranged_entry" then
						-- Ranged entry preview
						local entry_data = e.entry
						table.insert(lines, "Type: Ranged Event")
						table.insert(lines, "Range: " .. e.range_str)
						table.insert(lines, "")
						table.insert(lines, "Content:")
						table.insert(lines, "  " .. entry_data.display_text)

						if entry_data.attributes and next(entry_data.attributes) then
							table.insert(lines, "")
							table.insert(lines, "Attributes:")
							for key, value in pairs(entry_data.attributes) do
								table.insert(lines, string.format("  %s: %s", key, tostring(value)))
							end
						end
					end

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					-- For now, just close the picker
					-- Could implement navigation to specific dates/tasks later
					actions.close(prompt_bufnr)
				end)
				return true
			end,
		})
		:find()
end

-- =============================================================================
-- Project Search with Complex Sorting
-- =============================================================================

--- Project search with intelligent sorting
function M.telescope_projects(opts)
	opts = opts or {}

	-- Load data
	projects.load()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	-- Get OKR-linked projects
	local okr_linked = parse_okr_links()

	-- Build entries with scoring
	local entries = {}
	local all_projects = projects.get_all_projects()

	for _, area in ipairs(all_projects) do
		for _, project in ipairs(area.projects) do
			-- Calculate project score based on its tasks
			local project_score = 0
			local task_count = #project.tasks
			local completed_count = 0
			local has_priority = false
			local has_due_today = false
			local is_okr_linked = okr_linked[project.name] or false

			-- Analyze tasks
			for _, task in ipairs(project.tasks) do
				local task_score = calculate_task_score(task, okr_linked)
				project_score = project_score + task_score

				if task.task_status and task.task_status.key == "[x]" then
					completed_count = completed_count + 1
				end

				if task.attributes then
					if task.attributes.priority then
						has_priority = true
					end

					if task.attributes.due then
						local due_dt = Utils.parse_datetime(task.attributes.due)
						if due_dt then
							local due_date = os.date("%Y-%m-%d", os.time(due_dt))
							if due_date == os.date("%Y-%m-%d") then
								has_due_today = true
							end
						end
					end
				end
			end

			-- Average task score
			if task_count > 0 then
				project_score = project_score / task_count
			end

			-- Boost for OKR linkage
			if is_okr_linked then
				project_score = project_score + 100
			end

			-- Penalty for mostly completed projects
			if task_count > 0 then
				local completion_ratio = completed_count / task_count
				if completion_ratio > 0.8 then
					project_score = project_score * 0.5
				end
			end

			-- Build display string with indicators
			local indicators = {}
			if is_okr_linked then
				table.insert(indicators, "OKR")
			end
			if has_priority then
				table.insert(indicators, "PRIORITY")
			end
			if has_due_today then
				table.insert(indicators, "DUE")
			end

			local indicator_str = ""
			if #indicators > 0 then
				indicator_str = " [" .. table.concat(indicators, ",") .. "]"
			end

			local progress = task_count > 0 and string.format(" (%d/%d)", completed_count, task_count) or ""

			table.insert(entries, {
				type = "project",
				project = project,
				area = area,
				display = string.format("📁 %s%s%s - %s", project.name, progress, indicator_str, area.name),
				ordinal = project.name .. " " .. area.name,
				score = project_score,
				task_count = task_count,
				completed_count = completed_count,
				is_okr_linked = is_okr_linked,
				has_priority = has_priority,
				has_due_today = has_due_today,
			})
		end
	end

	-- Sort by score (highest first)
	table.sort(entries, function(a, b)
		return a.score > b.score
	end)

	-- Create the picker
	pickers
		.new(opts, {
			prompt_title = "Projects (Sorted by Priority)",
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
					local lines = {}
					local e = entry.value
					local project = e.project

					-- Header
					table.insert(lines, "Project: " .. project.name)
					table.insert(lines, "Area: " .. e.area.name)
					table.insert(lines, string.format("Score: %.1f", e.score))

					-- Indicators
					local status = {}
					if e.is_okr_linked then
						table.insert(status, "✓ Linked to OKR")
					end
					if e.has_priority then
						table.insert(status, "⚡ Has priority tasks")
					end
					if e.has_due_today then
						table.insert(status, "📅 Tasks due today")
					end

					if #status > 0 then
						table.insert(lines, "")
						for _, s in ipairs(status) do
							table.insert(lines, s)
						end
					end

					-- Progress
					table.insert(lines, "")
					table.insert(
						lines,
						string.format("Progress: %d/%d tasks completed", e.completed_count, e.task_count)
					)
					if e.task_count > 0 then
						local pct = (e.completed_count / e.task_count) * 100
						local bar_width = 30
						local filled = math.floor(pct / 100 * bar_width)
						local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)
						table.insert(lines, string.format("[%s] %.0f%%", bar, pct))
					end

					-- Tasks
					if #project.tasks > 0 then
						table.insert(lines, "")
						table.insert(lines, "Tasks:")
						table.insert(lines, string.rep("─", 40))

						-- Sort tasks by score for preview
						local sorted_tasks = vim.deepcopy(project.tasks)
						for _, task in ipairs(sorted_tasks) do
							task._score =
								calculate_task_score(task, e.is_okr_linked and { [project.name] = true } or {})
						end
						table.sort(sorted_tasks, function(a, b)
							return a._score > b._score
						end)

						-- Show top tasks
						local max_tasks = 10
						for i, task in ipairs(sorted_tasks) do
							if i > max_tasks then
								table.insert(lines, string.format("  ... and %d more tasks", #sorted_tasks - max_tasks))
								break
							end

							local line = "  "
							if task.task_status then
								line = line .. task.task_status.symbol .. " "
							end
							line = line .. task.display_text

							-- Add task indicators
							local indicators = {}
							if task.attributes then
								if task.attributes.priority then
									table.insert(indicators, task.attributes.priority)
								end
								if task.attributes.at then
									table.insert(indicators, "🕐 " .. task.attributes.at)
								end
								if task.attributes.due then
									table.insert(indicators, "📅 " .. task.attributes.due)
								end
							end

							if #indicators > 0 then
								line = line .. " (" .. table.concat(indicators, ", ") .. ")"
							end

							table.insert(lines, line)
						end
					end

					-- Resources
					if #project.resources > 0 then
						table.insert(lines, "")
						table.insert(lines, "Resources:")
						table.insert(lines, string.rep("─", 40))
						for _, resource in ipairs(project.resources) do
							table.insert(lines, "  - " .. resource.text)
						end
					end

					-- Notes
					if #project.notes > 0 then
						table.insert(lines, "")
						table.insert(lines, "Notes:")
						table.insert(lines, string.rep("─", 40))
						for _, note in ipairs(project.notes) do
							table.insert(lines, "  " .. note.text)
						end
					end

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						local e = selection.value
						-- Open projects file at the project location
						local path = Utils.get_file_path(Utils.PROJECTS_FILE)
						if path then
							vim.cmd("edit " .. vim.fn.fnameescape(path))
							vim.api.nvim_win_set_cursor(0, { e.project.line_num, 0 })
						end
					end
				end)
				return true
			end,
		})
		:find()
end

-- =============================================================================
-- Calendar View (Chronological)
-- =============================================================================

--- Calendar view with chronological sorting
function M.telescope_calendar(opts)
	opts = opts or {}
	Utils.load()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	local all_parsed = Utils.get_all_parsed_entries()
	local entries = {}
	local today = os.date("%Y-%m-%d")
	local today_time = os.time()

	-- Build entries with date information
	for date_str, parsed_list in pairs(all_parsed) do
		local date_info = get_date_display_info(date_str)
		if date_info then
			table.insert(entries, {
				value = date_str,
				display = string.format("📅 %s%s", date_info.display_date, date_info.relative),
				ordinal = date_info.display_date .. " " .. date_str,
				date_obj = date_info.date_obj,
				days_diff = date_info.days_diff,
				is_today = date_info.is_today,
				parsed_entries = parsed_list,
			})
		end
	end

	-- Sort entries chronologically with special logic
	table.sort(entries, function(a, b)
		-- Today always comes first
		if a.is_today then
			return true
		end
		if b.is_today then
			return false
		end

		-- Both in future: closest to today first
		if a.days_diff >= 0 and b.days_diff >= 0 then
			return a.days_diff < b.days_diff
		end

		-- Both in past: most recent first
		if a.days_diff < 0 and b.days_diff < 0 then
			return a.days_diff > b.days_diff
		end

		-- One future, one past: future comes first
		return a.days_diff >= 0
	end)

	pickers
		.new(opts, {
			prompt_title = "Calendar Entries",
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
				title = "Day Digest",
				define_preview = function(self, entry)
					local lines = {
						"Date: " .. entry.value.display:gsub("^📅 ", ""),
						string.rep("─", 50),
						"",
					}

					-- Sort entries by time
					local sorted_entries = vim.deepcopy(entry.value.parsed_entries)
					table.sort(sorted_entries, function(a, b)
						local time_a = a.attributes.at or a.attributes.from or "00:00"
						local time_b = b.attributes.at or b.attributes.from or "00:00"
						return time_a < time_b
					end)

					-- Group by type
					local events = {}
					local tasks = {}
					local notes = {}

					for _, parsed in ipairs(sorted_entries) do
						if parsed.type == "event" or parsed.attributes.notification_enabled then
							table.insert(events, parsed)
						elseif parsed.type == "task" then
							table.insert(tasks, parsed)
						else
							table.insert(notes, parsed)
						end
					end

					-- Display events
					if #events > 0 then
						table.insert(lines, "📅 Events:")
						for _, parsed in ipairs(events) do
							local line = "  "
							if parsed.attributes.from and parsed.attributes.to then
								line = line .. string.format("%s-%s ", parsed.attributes.from, parsed.attributes.to)
							elseif parsed.attributes.at then
								line = line .. parsed.attributes.at .. " - "
							end
							line = line .. parsed.display_text

							if parsed.is_recurring_instance then
								line = line .. " 🔁"
							end

							table.insert(lines, line)
						end
						table.insert(lines, "")
					end

					-- Display tasks
					if #tasks > 0 then
						table.insert(lines, "✓ Tasks:")
						for _, parsed in ipairs(tasks) do
							local line = "  "
							if parsed.task_status then
								line = line .. parsed.task_status.symbol .. " "
							end
							if parsed.attributes.at then
								line = line .. parsed.attributes.at .. " - "
							end
							line = line .. parsed.display_text

							if parsed.is_due_date_instance then
								line = line .. " 📅"
							end

							table.insert(lines, line)
						end
						table.insert(lines, "")
					end

					-- Display notes
					if #notes > 0 then
						table.insert(lines, "📝 Notes:")
						for _, parsed in ipairs(notes) do
							table.insert(lines, "  • " .. parsed.display_text)
						end
					end

					-- Also show project tasks for this date
					projects.load()
					local project_tasks = projects.get_tasks_for_date(entry.value.value)
					if #project_tasks > 0 then
						table.insert(lines, "")
						table.insert(lines, "📁 Project Tasks:")
						for _, task in ipairs(project_tasks) do
							local line = "  "
							if task.task_status then
								line = line .. task.task_status.symbol .. " "
							end
							if task.attributes.at then
								line = line .. task.attributes.at .. " - "
							end
							line = line .. task.display_text
							line = line .. " [" .. task.project .. "]"
							table.insert(lines, line)
						end
					end

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						-- Open calendar UI at this date
						local ui = require("zortex.calendar.ui")
						ui.open()
						-- Set the current date to the selected date
						local y, m, d = selection.value.value:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
						if y then
							vim.schedule(function()
								ui.set_date(tonumber(y), tonumber(m), tonumber(d))
							end)
						end
					end
				end)
				return true
			end,
		})
		:find()
end

return M
