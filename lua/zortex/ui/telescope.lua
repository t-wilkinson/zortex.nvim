-- ui/telescope.lua - Telescope integration for Zortex
local M = {}

local calendar = require("zortex.modules.calendar")
local projects = require("zortex.modules.projects")
local parser = require("zortex.core.parser")
local xp = require("zortex.modules.xp")

-- =============================================================================
-- Helper Functions
-- =============================================================================

---Calculate a numeric score used for intelligent project sorting.
local function calculate_task_score(task)
	local score = 0
	-- Priority scoring
	if task.attributes and task.attributes.priority then
		local priority_scores = { p1 = 100, p2 = 50, p3 = 25 }
		score = score + (priority_scores[task.attributes.priority] or 0)
	end
	-- Due‑date scoring
	if task.attributes and task.attributes.due then
		local due_dt = parser.parse_datetime(task.attributes.due)
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
	-- Heat scoring from XP system
	local heat = xp.get_task_heat and xp.get_task_heat(task) or 0
	score = score + (heat * 20)
	-- Completed tasks score lower
	if task.completed then
		score = score - 100
	end
	return score
end

-- =============================================================================
-- Projects View with Intelligent Sorting
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

	local entries = {}
	local all_projects = projects.get_all_projects()

	for _, project in ipairs(all_projects) do
		-- Calculate project stats
		local stats = projects.get_project_stats(project)
		local project_score = 0
		local has_priority = false
		local has_due_today = false

		-- Analyse tasks
		for _, task in ipairs(project.tasks) do
			local task_score = calculate_task_score(task)
			project_score = project_score + task_score
			if task.attributes and task.attributes.priority then
				has_priority = true
			end
			if task.attributes and task.attributes.due then
				local due_dt = parser.parse_datetime(task.attributes.due)
				if due_dt then
					local due_date = os.date("%Y-%m-%d", os.time(due_dt))
					if due_date == os.date("%Y-%m-%d") then
						has_due_today = true
					end
				end
			end
		end

		-- Average task score
		if stats.total_tasks > 0 then
			project_score = project_score / stats.total_tasks
		end
		-- Penalty for mostly completed projects
		if stats.completion_rate > 0.8 then
			project_score = project_score * 0.5
		end

		-- Build display string using full path
		local path_str = projects.get_project_path(project)
		local indicators = {}
		if has_priority then
			table.insert(indicators, "PRIORITY")
		end
		if has_due_today then
			table.insert(indicators, "DUE")
		end
		local indicator_str = (#indicators > 0) and (" [" .. table.concat(indicators, ",") .. "]") or ""
		local progress = (stats.total_tasks > 0) and string.format(" (%d/%d)", stats.completed_tasks, stats.total_tasks)
			or ""

		table.insert(entries, {
			type = "project",
			project = project,
			display = string.format("📁 %s%s%s", path_str, progress, indicator_str),
			ordinal = path_str,
			score = project_score,
			stats = stats,
			has_priority = has_priority,
			has_due_today = has_due_today,
		})
	end

	-- Sort by score
	table.sort(entries, function(a, b)
		return a.score > b.score
	end)

	-- Create picker
	pickers
		.new(opts, {
			prompt_title = "Projects (Sorted by Priority)",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(entry)
					return { value = entry, display = entry.display, ordinal = entry.ordinal }
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				title = "Project Details",
				define_preview = function(self, entry)
					local lines = {}
					local e = entry.value
					local project, stats = e.project, e.stats
					table.insert(lines, "Project: " .. projects.get_project_path(project))
					table.insert(lines, string.format("Score: %.1f", e.score))
					if e.has_priority or e.has_due_today then
						table.insert(lines, "")
						if e.has_priority then
							table.insert(lines, "⚡ Has priority tasks")
						end
						if e.has_due_today then
							table.insert(lines, "📅 Tasks due today")
						end
					end
					table.insert(lines, "")
					table.insert(
						lines,
						string.format("Progress: %d/%d tasks completed", stats.completed_tasks, stats.total_tasks)
					)
					if stats.total_tasks > 0 then
						local pct = stats.completion_rate * 100
						local bar_width, filled = 30, math.floor(pct / 100 * 30)
						local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)
						table.insert(lines, string.format("[%s] %.0f%%", bar, pct))
					end
					if #project.tasks > 0 then
						table.insert(lines, "")
						table.insert(lines, "Tasks:")
						table.insert(lines, string.rep("─", 40))
						local sorted_tasks = vim.deepcopy(project.tasks)
						for _, task in ipairs(sorted_tasks) do
							task._score = calculate_task_score(task)
						end
						table.sort(sorted_tasks, function(a, b)
							return a._score > b._score
						end)
						for i, task in ipairs(sorted_tasks) do
							if i > 10 then
								table.insert(lines, string.format("  ... and %d more tasks", #sorted_tasks - 10))
								break
							end
							local line = "  "
								.. (task.completed and "☑" or "☐")
								.. " "
								.. (parser.get_task_text(task.raw_text) or task.display_text)
							local task_indicators = {}
							if task.attributes then
								if task.attributes.priority then
									table.insert(task_indicators, task.attributes.priority)
								end
								if task.attributes.at then
									table.insert(task_indicators, "🕐 " .. task.attributes.at)
								end
								if task.attributes.due then
									table.insert(task_indicators, "📅 " .. task.attributes.due)
								end
							end
							if #task_indicators > 0 then
								line = line .. " (" .. table.concat(task_indicators, ", ") .. ")"
							end
							table.insert(lines, line)
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
						local projects_file = require("zortex.core.filesystem").get_projects_file()
						if projects_file then
							vim.cmd("edit " .. vim.fn.fnameescape(projects_file))
							vim.api.nvim_win_set_cursor(0, { e.project.line_num, 0 })
						end
					end
				end)
				return true
			end,
		})
		:find()
end

return M
