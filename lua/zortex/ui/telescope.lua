-- telescope.lua - Telescope integration for Zortex
local M = {}

local telescope = require("telescope")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local conf = require("telescope.config").values
local previewers = require("telescope.previewers")

local parser = require("zortex.core.parser")
local calendar = require("zortex.features.calendar")
local projects = require("zortex.features.projects")

-- =============================================================================
-- Calendar Search
-- =============================================================================

function M.calendar(opts)
	opts = opts or {}

	-- Ensure calendar is loaded
	calendar.load()

	-- Gather all calendar entries
	local entries = {}
	local all_entries = calendar.get_all_entries()

	-- Convert to flat list for telescope
	for date_str, date_entries in pairs(all_entries) do
		for _, entry in ipairs(date_entries) do
			local display_parts = { date_str }

			-- Add time if available
			if entry.attributes.at then
				table.insert(display_parts, entry.attributes.at)
			end

			-- Add task status
			if entry.task_status then
				table.insert(display_parts, entry.task_status.symbol)
			end

			-- Add display text
			table.insert(display_parts, entry.display_text)

			table.insert(entries, {
				date = date_str,
				entry = entry,
				display = table.concat(display_parts, " │ "),
				ordinal = date_str .. " " .. entry.display_text,
			})
		end
	end

	-- Sort by date (newest first)
	table.sort(entries, function(a, b)
		return a.date > b.date
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
				title = "Entry Details",
				define_preview = function(self, entry)
					local value = entry.value
					local lines = {
						"Date: " .. value.date,
						"Type: " .. value.entry.type,
						"",
						"Content:",
						value.entry.raw_text,
						"",
						"Attributes:",
					}

					-- Add attributes
					for k, v in pairs(value.entry.attributes) do
						table.insert(lines, string.format("  %s: %s", k, tostring(v)))
					end

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					-- Could open calendar file at specific date
					vim.cmd("edit " .. vim.g.zortex_notes_dir .. "/calendar.zortex")
				end)
				return true
			end,
		})
		:find()
end

-- =============================================================================
-- Projects Browser
-- =============================================================================

function M.projects(opts)
	opts = opts or {}

	-- Ensure projects are loaded
	projects.load()

	-- Get all projects
	local all_projects = projects.get_all_projects()
	local entries = {}

	for _, project in ipairs(all_projects) do
		local stats = projects.get_project_stats(project)

		-- Build display
		local display_parts = {
			string.rep("  ", project.level - 1) .. project.name,
		}

		-- Add progress
		if stats.total_tasks > 0 then
			table.insert(display_parts, string.format("[%d/%d]", stats.completed_tasks, stats.total_tasks))
		end

		-- Add attributes
		if project.attributes.priority then
			table.insert(display_parts, project.attributes.priority)
		end

		table.insert(entries, {
			project = project,
			stats = stats,
			display = table.concat(display_parts, " "),
			ordinal = project.name,
		})
	end

	pickers
		.new(opts, {
			prompt_title = "Projects",
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
					local project = entry.value.project
					local stats = entry.value.stats
					local lines = {
						"Project: " .. project.name,
						"Level: " .. project.level,
						"Line: " .. project.line_num,
						"",
						"Statistics:",
						"  Total tasks: " .. stats.total_tasks,
						"  Completed: " .. stats.completed_tasks,
						"  Completion: " .. string.format("%.1f%%", stats.completion_rate * 100),
						"",
						"Tasks:",
					}

					-- Add tasks
					for _, task in ipairs(project.tasks) do
						local status = task.completed and "[x]" or "[ ]"
						table.insert(lines, string.format("  %s %s", status, task.display_text))
					end

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)

					-- Open projects file at project location
					vim.cmd("edit " .. vim.g.zortex_notes_dir .. "/projects.zortex")
					vim.fn.cursor(selection.value.project.line_num, 1)
				end)
				return true
			end,
		})
		:find()
end

-- =============================================================================
-- Today's Digest
-- =============================================================================

function M.today_digest(opts)
	opts = opts or {}

	local today = os.date("%Y-%m-%d")
	local entries = {}

	-- Get calendar entries for today
	local cal_entries = calendar.get_entries_for_date(today)
	for _, entry in ipairs(cal_entries) do
		table.insert(entries, {
			source = "Calendar",
			type = entry.type,
			time = entry.attributes.at,
			text = entry.display_text,
			completed = entry.task_status and entry.task_status.key == "[x]",
			entry = entry,
		})
	end

	-- Get project tasks due today
	local project_tasks = calendar.get_project_tasks_for_date(today)
	for _, task in ipairs(project_tasks) do
		table.insert(entries, {
			source = "Projects",
			type = "task",
			time = task.attributes.at,
			text = task.display_text,
			completed = task.completed,
			project = task.project,
			task = task,
		})
	end

	-- Sort by time
	table.sort(entries, function(a, b)
		local a_time = a.time or "00:00"
		local b_time = b.time or "00:00"
		return a_time < b_time
	end)

	-- Build display entries
	local display_entries = {}
	for _, item in ipairs(entries) do
		local display_parts = {}

		-- Time
		table.insert(display_parts, item.time or "     ")

		-- Status
		if item.type == "task" then
			table.insert(display_parts, item.completed and "[x]" or "[ ]")
		else
			table.insert(display_parts, "   ")
		end

		-- Source
		table.insert(display_parts, string.format("[%s]", item.source))

		-- Text
		table.insert(display_parts, item.text)

		-- Project name for project tasks
		if item.project then
			table.insert(display_parts, "(" .. item.project .. ")")
		end

		table.insert(display_entries, {
			value = item,
			display = table.concat(display_parts, " "),
			ordinal = (item.time or "") .. " " .. item.text,
		})
	end

	-- Add summary at top
	local summary = {
		value = { type = "summary" },
		display = string.format("=== Today's Digest: %s (%d items) ===", today, #entries),
		ordinal = "",
	}
	table.insert(display_entries, 1, summary)

	pickers
		.new(opts, {
			prompt_title = "Today's Digest",
			finder = finders.new_table({
				results = display_entries,
				entry_maker = function(entry)
					return entry
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = false,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					if selection and selection.value.type ~= "summary" then
						actions.close(prompt_bufnr)

						-- Open appropriate file
						if selection.value.source == "Calendar" then
							vim.cmd("edit " .. vim.g.zortex_notes_dir .. "/calendar.zortex")
						else
							vim.cmd("edit " .. vim.g.zortex_notes_dir .. "/projects.zortex")
							if selection.value.task and selection.value.task.line_num then
								vim.fn.cursor(selection.value.task.line_num, 1)
							end
						end
					end
				end)
				return true
			end,
		})
		:find()
end

-- =============================================================================
-- Upcoming Events
-- =============================================================================

function M.upcoming_events(opts)
	opts = opts or {}
	local days_ahead = opts.days or 7

	local events = calendar.get_upcoming_events(days_ahead)
	local entries = {}

	for _, event_data in ipairs(events) do
		local entry = event_data.entry
		local display_parts = {
			event_data.date,
			entry.attributes.at or "     ",
			entry.display_text,
		}

		table.insert(entries, {
			value = event_data,
			display = table.concat(display_parts, " │ "),
			ordinal = event_data.date .. " " .. (entry.attributes.at or "") .. " " .. entry.display_text,
		})
	end

	pickers
		.new(opts, {
			prompt_title = string.format("Upcoming Events (%d days)", days_ahead),
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return entry
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = false,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					vim.cmd("edit " .. vim.g.zortex_notes_dir .. "/calendar.zortex")
				end)
				return true
			end,
		})
		:find()
end

return M
