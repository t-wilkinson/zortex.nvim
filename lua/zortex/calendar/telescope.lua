-- Telescope integration for unified Zortex digest view
-- Provides searchable views of calendar entries and projects

local M = {}

local data = require("zortex.calendar.data")
local projects = require("zortex.calendar.projects")

--- Create a unified digest view with both calendar entries and projects
function M.telescope_digest(opts)
	opts = opts or {}

	-- Load data
	data.load()
	projects.load()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	-- Prepare entries
	local entries = {}

	-- Add calendar entries grouped by date
	local all_calendar = data.get_all_parsed_entries()
	for date_str, parsed_list in pairs(all_calendar) do
		local y, m, d = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
		if y then
			local date_obj = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
			local display_date = os.date("%A, %B %d, %Y", date_obj)
			local mm_dd_yyyy = os.date("%m-%d-%Y", date_obj)

			table.insert(entries, {
				type = "calendar_date",
				value = date_str,
				display = string.format("📅 %s", display_date),
				ordinal = display_date .. " " .. mm_dd_yyyy .. " " .. date_str,
				date_obj = date_obj,
				parsed_entries = parsed_list,
			})
		end
	end

	-- Add projects grouped by area
	local all_projects = projects.get_all_projects()
	for _, area in ipairs(all_projects) do
		for _, project in ipairs(area.projects) do
			-- Create display string showing project and area
			local task_count = #project.tasks
			local display = string.format("📁 %s [%s] (%d tasks)", project.name, area.name, task_count)

			table.insert(entries, {
				type = "project",
				value = project,
				display = display,
				ordinal = project.name .. " " .. area.name,
				area_name = area.name,
				project_name = project.name,
			})
		end
	end

	-- Sort entries: calendar dates (recent first), then projects
	table.sort(entries, function(a, b)
		if a.type == "calendar_date" and b.type == "calendar_date" then
			return a.date_obj > b.date_obj
		elseif a.type == "calendar_date" then
			return true
		elseif b.type == "calendar_date" then
			return false
		else
			-- Both are projects, sort alphabetically
			return a.ordinal < b.ordinal
		end
	end)

	pickers
		.new(opts, {
			prompt_title = "Zortex Digest",
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
				title = "Preview",
				define_preview = function(self, entry)
					local lines = {}
					local e = entry.value

					if e.type == "calendar_date" then
						-- Calendar date preview
						table.insert(lines, "Date: " .. e.display:gsub("^📅 ", ""))
						table.insert(lines, "")
						table.insert(lines, "Calendar Entries:")
						table.insert(lines, string.rep("─", 40))

						-- Show calendar entries for this date
						for _, parsed in ipairs(e.parsed_entries) do
							local line = "  "
							if parsed.attributes.at then
								line = line .. parsed.attributes.at .. " - "
							end
							if parsed.task_status then
								line = line .. parsed.task_status.symbol .. " "
							end
							line = line .. parsed.display_text

							if parsed.is_recurring_instance then
								line = line .. " 🔁"
							end
							if parsed.is_due_date_instance then
								line = line .. " ❗"
							end

							table.insert(lines, line)
						end

						-- Also show project tasks for this date
						local project_tasks = projects.get_tasks_for_date(e.value)
						if #project_tasks > 0 then
							table.insert(lines, "")
							table.insert(lines, "Project Tasks:")
							table.insert(lines, string.rep("─", 40))

							for _, task in ipairs(project_tasks) do
								local line = "  "
								if task.attributes.at then
									line = line .. task.attributes.at .. " - "
								end
								if task.task_status then
									line = line .. task.task_status.symbol .. " "
								end
								line = line .. task.display_text
								line = line .. " [" .. task.project .. "]"

								table.insert(lines, line)
							end
						end
					elseif e.type == "project" then
						-- Project preview
						local project = e.value
						table.insert(lines, "Project: " .. project.name)
						table.insert(lines, "Area: " .. e.area_name)
						table.insert(lines, "")

						if #project.tasks > 0 then
							table.insert(lines, "Tasks:")
							table.insert(lines, string.rep("─", 40))
							for _, task in ipairs(project.tasks) do
								local line = "  "
								if task.task_status then
									line = line .. task.task_status.symbol .. " "
								end
								line = line .. task.display_text

								-- Show task attributes
								local attrs = {}
								if task.attributes.at then
									table.insert(attrs, "🕐 " .. task.attributes.at)
								end
								if task.attributes.due then
									table.insert(attrs, "📅 " .. task.attributes.due)
								end
								if task.attributes.from then
									table.insert(attrs, "from: " .. task.attributes.from)
								end
								if task.attributes.to then
									table.insert(attrs, "to: " .. task.attributes.to)
								end
								if #attrs > 0 then
									line = line .. " (" .. table.concat(attrs, ", ") .. ")"
								end

								table.insert(lines, line)
							end
						end

						if #project.resources > 0 then
							table.insert(lines, "")
							table.insert(lines, "Resources:")
							table.insert(lines, string.rep("─", 40))
							for _, resource in ipairs(project.resources) do
								table.insert(lines, "  - " .. resource.text)
							end
						end

						if #project.notes > 0 then
							table.insert(lines, "")
							table.insert(lines, "Notes:")
							table.insert(lines, string.rep("─", 40))
							for _, note in ipairs(project.notes) do
								table.insert(lines, "  " .. note.text)
							end
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
						if e.type == "calendar_date" then
							-- Open calendar UI at this date
							local ui = require("zortex.calendar.ui")
							ui.open()
							-- Set the current date to the selected date
							local y, m, d = e.value:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
							if y then
								-- This is a bit hacky but works - we need to expose this in ui.lua
								vim.schedule(function()
									vim.api.nvim_feedkeys(
										vim.api.nvim_replace_termcodes(
											string.format(
												":lua require('zortex.calendar.ui').set_date(%s, %s, %s)<CR>",
												y,
												m,
												d
											),
											true,
											false,
											true
										),
										"n",
										false
									)
								end)
							end
						elseif e.type == "project" then
							-- Open projects file at the project location
							local path = projects.get_projects_path()
							if path then
								vim.cmd("edit " .. vim.fn.fnameescape(path))
								-- Jump to the project line
								vim.api.nvim_win_set_cursor(0, { e.value.line_num, 0 })
							end
						end
					end
				end)
				return true
			end,
		})
		:find()
end

--- Calendar-only Telescope view (backward compatibility)
function M.telescope_calendar(opts)
	opts = opts or {}
	data.load()

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local all_parsed = data.get_all_parsed_entries()
	local entries = {}
	for date_str, parsed_list in pairs(all_parsed) do
		local y, m, d = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
		if y then
			local date_obj = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
			table.insert(entries, {
				value = date_str,
				display_date = os.date("%a, %b %d, %Y", date_obj),
				ordinal = date_obj,
				parsed_entries = parsed_list,
			})
		end
	end

	table.sort(entries, function(a, b)
		return a.ordinal > b.ordinal
	end)

	pickers
		.new(opts, {
			prompt_title = "Calendar Entries",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.display_date,
						ordinal = entry.display_date,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = require("telescope.previewers").new_buffer_previewer({
				title = "Entry Preview",
				define_preview = function(self, entry)
					local lines = { "Date: " .. entry.value.display_date, "" }
					for _, parsed in ipairs(entry.value.parsed_entries) do
						local line = "  "
						if parsed.attributes.at then
							line = line .. parsed.attributes.at .. " - "
						end
						if parsed.task_status then
							line = line .. parsed.task_status.symbol .. " "
						end
						line = line .. parsed.display_text
						table.insert(lines, line)
					end
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					-- Could implement jump to date here
				end)
				return true
			end,
		})
		:find()
end

return M
