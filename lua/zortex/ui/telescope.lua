-- ui/telescope.lua - Telescope integration for Zortex
local M = {}

local calendar = require("zortex.modules.calendar")
local projects = require("zortex.modules.projects")
local parser = require("zortex.core.parser")

-- =============================================================================
-- Helper Functions
-- =============================================================================

local function get_date_display_info(date_str)
	local date_obj = parser.parse_date(date_str)
	if not date_obj then
		return nil
	end

	local time = os.time(date_obj)
	local today = os.time()
	local today_str = os.date("%Y-%m-%d", today)

	-- Calculate relative position
	local days_diff = math.floor((time - today) / 86400)
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
		time = time,
		display_date = os.date("%A, %B %d, %Y", time),
		short_date = os.date("%a, %b %d", time),
		relative = relative_str,
		days_diff = days_diff,
		is_today = date_str == today_str,
	}
end

local function format_entry_for_telescope(entry)
	local parts = {}

	-- Add time if available
	if entry.attributes.from and entry.attributes.to then
		table.insert(parts, string.format("%s-%s", entry.attributes.from, entry.attributes.to))
	elseif entry.attributes.at then
		table.insert(parts, entry.attributes.at)
	end

	-- Add status icon for tasks
	if entry.type == "task" and entry.task_status then
		table.insert(parts, entry.task_status.symbol)
	elseif entry.type == "event" then
		table.insert(parts, "📅")
	end

	-- Add main text
	table.insert(parts, entry.display_text)

	-- Add indicators
	local indicators = {}
	if entry.original_date then
		table.insert(indicators, "🔁")
	end
	if entry.attributes.notification_enabled then
		table.insert(indicators, "🔔")
	end
	if #indicators > 0 then
		table.insert(parts, table.concat(indicators, " "))
	end

	return table.concat(parts, " ")
end

-- =============================================================================
-- Today's Digest View
-- =============================================================================

function M.today_digest(opts)
	opts = opts or {}

	-- Load data
	calendar.load()
	projects.load()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local previewers = require("telescope.previewers")

	local entries = {}
	local today = os.date("%Y-%m-%d")

	-- Section: Today
	table.insert(entries, {
		type = "header",
		display = "═══ TODAY ═══",
		ordinal = "0000",
	})

	-- Today's calendar entries
	local today_entries = calendar.get_entries_for_date(today)
	for _, entry in ipairs(today_entries) do
		table.insert(entries, {
			type = "calendar_entry",
			entry = entry,
			display = format_entry_for_telescope(entry),
			ordinal = "0001" .. (entry.attributes.at or "0000") .. entry.display_text,
			date = today,
		})
	end

	-- Today's project tasks
	local project_tasks = calendar.get_project_tasks_for_date(today)
	for _, task in ipairs(project_tasks) do
		local display = ""
		if task.attributes.at then
			display = task.attributes.at .. " "
		end
		display = display .. (task.status and task.status.symbol or "☐") .. " "
		display = display .. task.display_text .. " [" .. task.project .. "]"

		table.insert(entries, {
			type = "project_task",
			task = task,
			display = display,
			ordinal = "0002" .. (task.attributes.at or "0000") .. task.display_text,
			date = today,
		})
	end

	-- Section: This Week
	table.insert(entries, {
		type = "header",
		display = "═══ THIS WEEK ═══",
		ordinal = "0100",
	})

	-- Get entries for next 7 days
	for days = 1, 7 do
		local date = os.date("%Y-%m-%d", os.time() + (days * 86400))
		local date_info = get_date_display_info(date)
		local date_entries = calendar.get_entries_for_date(date)
		local date_tasks = calendar.get_project_tasks_for_date(date)

		if #date_entries > 0 or #date_tasks > 0 then
			-- Add date header
			table.insert(entries, {
				type = "date_header",
				display = string.format("── %s%s ──", date_info.short_date, date_info.relative),
				ordinal = "01" .. string.format("%02d", days) .. "0000",
				date = date,
			})

			-- Add entries for this date
			for _, entry in ipairs(date_entries) do
				table.insert(entries, {
					type = "calendar_entry",
					entry = entry,
					display = "  " .. format_entry_for_telescope(entry),
					ordinal = "01" .. string.format("%02d", days) .. "01" .. (entry.attributes.at or "0000"),
					date = date,
				})
			end

			for _, task in ipairs(date_tasks) do
				local display = "  " .. (task.status and task.status.symbol or "☐") .. " "
				display = display .. task.display_text .. " [" .. task.project .. "]"

				table.insert(entries, {
					type = "project_task",
					task = task,
					display = display,
					ordinal = "01" .. string.format("%02d", days) .. "02" .. (task.attributes.at or "0000"),
					date = date,
				})
			end
		end
	end

	-- Create picker
	pickers
		.new(opts, {
			prompt_title = "Today's Digest",
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
						table.insert(lines, e.display)
					elseif e.type == "calendar_entry" then
						table.insert(lines, "Type: " .. e.entry.type:upper())
						table.insert(lines, "Date: " .. e.date)
						if e.entry.attributes.at then
							table.insert(lines, "Time: " .. e.entry.attributes.at)
						end
						table.insert(lines, "")
						table.insert(lines, e.entry.display_text)

						if e.entry.attributes and next(e.entry.attributes) then
							table.insert(lines, "")
							table.insert(lines, "Attributes:")
							for k, v in pairs(e.entry.attributes) do
								if k ~= "notification_durations" then
									table.insert(lines, "  " .. k .. ": " .. tostring(v))
								end
							end
						end
					elseif e.type == "project_task" then
						table.insert(lines, "Project: " .. e.task.project)
						table.insert(lines, "Date: " .. e.date)
						if e.task.attributes.at then
							table.insert(lines, "Time: " .. e.task.attributes.at)
						end
						table.insert(lines, "")
						table.insert(lines, e.task.display_text)
					end

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
				end)
				return true
			end,
		})
		:find()
end

-- =============================================================================
-- Calendar Search
-- =============================================================================

function M.calendar(opts)
	opts = opts or {}
	calendar.load()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	local all_entries = calendar.get_all_entries()
	local results = {}

	-- Build entries with date information
	for date_str, date_entries in pairs(all_entries) do
		local date_info = get_date_display_info(date_str)
		if date_info and #date_entries > 0 then
			table.insert(results, {
				date = date_str,
				display = string.format("📅 %s%s", date_info.display_date, date_info.relative),
				ordinal = date_str .. " " .. date_info.display_date,
				time = date_info.time,
				days_diff = date_info.days_diff,
				is_today = date_info.is_today,
				entries = date_entries,
			})
		end
	end

	-- Sort by date (today first, then future, then past)
	table.sort(results, function(a, b)
		if a.is_today then
			return true
		end
		if b.is_today then
			return false
		end

		-- Both future or both past
		if (a.days_diff >= 0) == (b.days_diff >= 0) then
			-- Future: closest first, Past: most recent first
			return math.abs(a.days_diff) < math.abs(b.days_diff)
		end

		-- One future, one past: future first
		return a.days_diff >= 0
	end)

	pickers
		.new(opts, {
			prompt_title = "Calendar Entries",
			finder = finders.new_table({
				results = results,
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
				title = "Day Preview",
				define_preview = function(self, entry)
					local lines = { entry.value.display, string.rep("─", 40), "" }

					-- Sort entries by time
					local sorted = vim.deepcopy(entry.value.entries)
					table.sort(sorted, function(a, b)
						local time_a = a.attributes.at or a.attributes.from or "00:00"
						local time_b = b.attributes.at or b.attributes.from or "00:00"
						return time_a < time_b
					end)

					-- Group by type
					local events, tasks, notes = {}, {}, {}
					for _, e in ipairs(sorted) do
						if e.type == "event" then
							table.insert(events, e)
						elseif e.type == "task" then
							table.insert(tasks, e)
						else
							table.insert(notes, e)
						end
					end

					-- Display groups
					if #events > 0 then
						table.insert(lines, "📅 Events:")
						for _, e in ipairs(events) do
							table.insert(lines, "  " .. format_entry_for_telescope(e))
						end
						table.insert(lines, "")
					end

					if #tasks > 0 then
						table.insert(lines, "✓ Tasks:")
						for _, e in ipairs(tasks) do
							table.insert(lines, "  " .. format_entry_for_telescope(e))
						end
						table.insert(lines, "")
					end

					if #notes > 0 then
						table.insert(lines, "📝 Notes:")
						for _, e in ipairs(notes) do
							table.insert(lines, "  • " .. e.display_text)
						end
					end

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)

					if selection then
						-- Open calendar UI at this date
						local cal_ui = require("zortex.ui.calendar")
						cal_ui.open()
						local date_obj = parser.parse_date(selection.value.date)
						if date_obj then
							cal_ui.set_date(date_obj.year, date_obj.month, date_obj.day)
						end
					end
				end)
				return true
			end,
		})
		:find()
end

-- =============================================================================
-- Projects Search
-- =============================================================================

function M.projects(opts)
	opts = opts or {}
	projects.load()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	local all_projects = projects.get_all_projects()
	local results = {}

	-- Calculate stats for each project
	for _, project in ipairs(all_projects) do
		local stats = projects.get_project_stats(project)
		local progress = stats.total_tasks > 0 and string.format(" (%d/%d)", stats.completed_tasks, stats.total_tasks)
			or ""

		table.insert(results, {
			project = project,
			stats = stats,
			display = string.format("📁 %s%s", project.name, progress),
			ordinal = project.name,
		})
	end

	-- Sort by completion rate (least complete first)
	table.sort(results, function(a, b)
		return a.stats.completion_rate < b.stats.completion_rate
	end)

	pickers
		.new(opts, {
			prompt_title = "Projects",
			finder = finders.new_table({
				results = results,
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
					local p = entry.value.project
					local s = entry.value.stats

					-- Header
					table.insert(lines, "Project: " .. p.name)
					table.insert(lines, "Level: " .. string.rep("#", p.level))
					table.insert(lines, "")

					-- Progress
					if s.total_tasks > 0 then
						table.insert(
							lines,
							string.format(
								"Progress: %d/%d (%.0f%%)",
								s.completed_tasks,
								s.total_tasks,
								s.completion_rate * 100
							)
						)

						-- Progress bar
						local bar_width = 30
						local filled = math.floor(s.completion_rate * bar_width)
						local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)
						table.insert(lines, "[" .. bar .. "]")
						table.insert(lines, "")
					end

					-- Attributes
					if p.attributes and next(p.attributes) then
						table.insert(lines, "Attributes:")
						for k, v in pairs(p.attributes) do
							table.insert(lines, "  " .. k .. ": " .. tostring(v))
						end
						table.insert(lines, "")
					end

					-- Tasks
					if #p.tasks > 0 then
						table.insert(lines, "Tasks:")
						for i, task in ipairs(p.tasks) do
							if i > 10 then
								table.insert(lines, "  ... and " .. (#p.tasks - 10) .. " more")
								break
							end
							local status = task.status and task.status.symbol or "☐"
							table.insert(lines, "  " .. status .. " " .. task.display_text)
						end
					end

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)

					if selection then
						-- Open projects file at project location
						local path = require("zortex.core.filesystem").get_file_path("projects.zortex")
						if path then
							vim.cmd("edit " .. vim.fn.fnameescape(path))
							vim.api.nvim_win_set_cursor(0, { selection.value.project.line_num, 0 })
						end
					end
				end)
				return true
			end,
		})
		:find()
end

return M
