-- Projects data management for the Zortex system.
-- Handles loading, parsing, and querying project entries from projects.zortex

local M = {}
local Utils = require("zortex.calendar.utils")

-- =============================================================================
-- State
-- =============================================================================

local state = {
	-- Stores raw project data
	projects = {},
	-- Stores file header lines (article name, tags, etc.)
	header_lines = {},
}

-- =============================================================================
-- Private Helper Functions
-- =============================================================================

--- Parse a task line for attributes
local function parse_task(task_text)
	local parsed = {
		raw_text = task_text,
		display_text = task_text,
		task_status = nil,
		attributes = {},
		type = "task",
	}

	local working_text = task_text

	-- Check for task status (same format as calendar tasks)
	local status_pattern = "^(%[.%])%s+(.+)$"
	local status_key, remaining_text = working_text:match(status_pattern)
	if status_key then
		-- Import task status definitions from data module
		if Utils.TASK_STATUS[status_key] then
			parsed.task_status = Utils.TASK_STATUS[status_key]
			parsed.task_status.key = status_key
			working_text = remaining_text
		end
	end

	-- Check for time prefix (HH:MM) or time range (HH:MM-HH:MM)
	local from_time, to_time, rest = working_text:match("^(%d%d?:%d%d)%-(%d%d?:%d%d)%s+(.+)$")
	if from_time and to_time then
		parsed.attributes.from = from_time
		parsed.attributes.to = to_time
		parsed.attributes.at = from_time
		working_text = rest
	else
		local time_prefix, rest_of_line = working_text:match("^(%d%d?:%d%d)%s+(.+)$")
		if time_prefix then
			parsed.attributes.at = time_prefix
			working_text = rest_of_line
		end
	end

	-- Parse attributes with parentheses
	local paren_attributes = {
		at = "@at%(([^)]+)%)",
		due = "@due%(([^)]+)%)",
		from = "@from%(([^)]+)%)",
		to = "@to%(([^)]+)%)",
		repeating = "@repeat%(([^)]+)%)",
	}

	for attr_name, pattern in pairs(paren_attributes) do
		local value = working_text:match(pattern)
		if value then
			parsed.attributes[attr_name] = value
			working_text = working_text:gsub(pattern, "")
		end
	end

	-- Clean up display text
	parsed.display_text = working_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

	return parsed
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Load and parse the projects file
function M.load()
	local path = Utils.get_file_path(Utils.PROJECTS_FILE)
	if not path then
		return
	end

	-- Reset state
	state.projects = {}
	state.header_lines = {}

	if vim.fn.filereadable(path) == 0 then
		return
	end

	local lines = {}
	for line in io.lines(path) do
		table.insert(lines, line)
	end

	local current_area = nil
	local current_project = nil
	local in_header = true
	local i = 1

	while i <= #lines do
		local line = lines[i]

		-- Check if we're still in the header (before first heading)
		if in_header and line:match("^#+ ") then
			in_header = false
		end

		if in_header then
			table.insert(state.header_lines, line)
		else
			-- Parse area (# heading)
			local area_name = line:match("^# (.+)$")
			if area_name then
				current_area = {
					name = area_name,
					projects = {},
					line_num = i,
				}
				table.insert(state.projects, current_area)
				current_project = nil
			else
				-- Parse project (## heading)
				local project_name = line:match("^## (.+)$")
				if project_name and current_area then
					current_project = {
						name = project_name,
						area = current_area.name,
						tasks = {},
						resources = {},
						notes = {},
						line_num = i,
					}
					table.insert(current_area.projects, current_project)
				elseif current_project then
					-- Parse content under project
					-- Check for task patterns
					local task_match = line:match("^%s*%- %[.%] .+")
						or line:match("^%s*%[.%] .+")
						or line:match("^%s*%- %d%d?:%d%d .+")
						or line:match("^%s*%d%d?:%d%d .+")

					if task_match then
						-- Extract the task content
						local task_text = line:match("^%s*%- (.+)$") or line:match("^%s*(.+)$")
						if task_text then
							local parsed_task = parse_task(task_text)
							parsed_task.project = current_project.name
							parsed_task.area = current_area.name
							parsed_task.line_num = i
							table.insert(current_project.tasks, parsed_task)
						end
					elseif line:match("%S") then
						-- Non-empty line that's not a task
						if line:match("^%s*%- ") then
							-- Resource or note
							table.insert(current_project.resources, {
								text = line:match("^%s*%- (.+)$"),
								line_num = i,
							})
						else
							-- General note
							table.insert(current_project.notes, {
								text = line,
								line_num = i,
							})
						end
					end
				end
			end
		end
		i = i + 1
	end
end

--- Get all tasks with date/time attributes
function M.get_dated_tasks()
	local dated_tasks = {}

	for _, area in ipairs(state.projects) do
		for _, project in ipairs(area.projects) do
			for _, task in ipairs(project.tasks) do
				-- Check if task has any date/time attributes
				if task.attributes.at or task.attributes.due or task.attributes.from or task.attributes.to then
					table.insert(dated_tasks, task)
				end
			end
		end
	end

	return dated_tasks
end

--- Get tasks for a specific date
function M.get_tasks_for_date(date_str)
	local tasks_for_date = {}
	local target_date = Utils.parse_date(date_str)
	if not target_date then
		return tasks_for_date
	end

	for _, area in ipairs(state.projects) do
		for _, project in ipairs(area.projects) do
			for _, task in ipairs(project.tasks) do
				local include_task = false

				-- Check @due attribute
				if task.attributes.due then
					local due_dt = Utils.parse_datetime(task.attributes.due)
					if due_dt then
						local due_str = string.format("%04d-%02d-%02d", due_dt.year, due_dt.month, due_dt.day)
						if due_str == date_str then
							include_task = true
						end
					end
				end

				-- Check @at attribute (for specific time on a date)
				if task.attributes.at and task.attributes.at:match("%d%d%d%d%-%d%d%-%d%d") then
					local at_dt = Utils.parse_datetime(task.attributes.at)
					if at_dt then
						local at_str = string.format("%04d-%02d-%02d", at_dt.year, at_dt.month, at_dt.day)
						if at_str == date_str then
							include_task = true
						end
					end
				end

				-- Check date range (@from/@to)
				if task.attributes.from or task.attributes.to then
					local from_dt = task.attributes.from and Utils.parse_datetime(task.attributes.from)
					local to_dt = task.attributes.to and Utils.parse_datetime(task.attributes.to)

					if from_dt or to_dt then
						local target_time = os.time(target_date)
						local from_time = from_dt and os.time(from_dt) or 0
						local to_time = to_dt and os.time(to_dt) or math.huge

						if target_time >= from_time and target_time <= to_time then
							include_task = true
						end
					end
				end

				if include_task then
					table.insert(tasks_for_date, task)
				end
			end
		end
	end

	return tasks_for_date
end

--- Get all projects organized by area
function M.get_all_projects()
	return state.projects
end

--- Get file header lines
function M.get_header_lines()
	return state.header_lines
end

return M
