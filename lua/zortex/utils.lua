-- Enhanced Data management for the Zortex system with XP functionality.
-- Handles calendar, projects, OKRs, areas, and XP calculations.

local M = {}
local config = require("config")

-- =============================================================================
-- Constants
-- =============================================================================

M.CALENDAR_FILE = "calendar.zortex"
M.PROJECTS_FILE = "projects.zortex"
M.AREAS_FILE = "areas.zortex"
M.OKR_FILE = "okr.zortex"
M.VISION_FILE = "vision.zortex"
M.ARCHIVE_PROJECTS_FILE = "z/archive.projects.zortex"

-- Task status definitions
M.TASK_STATUS = {
	["[ ]"] = { symbol = "☐", name = "Incomplete", hl = "Comment" },
	["[x]"] = { symbol = "☑", name = "Complete", hl = "String" },
	["[~]"] = { symbol = "◐", name = "In Progress", hl = "WarningMsg" },
	["[@]"] = { symbol = "⏸", name = "Paused", hl = "Comment" },
}

-- =============================================================================
-- State
-- =============================================================================

local state = {
	-- Calendar data
	raw_data = {},
	parsed_data = {},

	-- Multi-file cache
	file_cache = {},

	-- Graph data for XP calculation
	okr_graph = nil,
	link_cache = {},
}

-- =============================================================================
-- Helper Functions
-- =============================================================================

--- Deep copy a table to prevent mutation of original data.
function M.deepcopy(orig)
	local orig_type = type(orig)
	local copy
	if orig_type == "table" then
		copy = {}
		for orig_key, orig_value in next, orig, nil do
			copy[M.deepcopy(orig_key)] = M.deepcopy(orig_value)
		end
		setmetatable(copy, M.deepcopy(getmetatable(orig)))
	else
		copy = orig
	end
	return copy
end

--- Parse a date string (YYYY-MM-DD) or (MM-DD-YYYY) into a table.
function M.parse_date(date_str)
	if not date_str then
		return nil
	end

	-- 1) YYYY-MM-DD
	local y, m, d = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if y then
		return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
	end

	-- 2) MM-DD-YYYY
	local m2, d2, y2 = date_str:match("^(%d%d)%-(%d%d)%-(%d%d%d%d)$")
	if m2 then
		return { year = tonumber(y2), month = tonumber(m2), day = tonumber(d2) }
	end

	return nil
end

--- Parse time string into hour and minute
function M.parse_time(time_str)
	if not time_str then
		return nil
	end

	-- Try HH:MM format
	local hour, min = time_str:match("^(%d%d?):(%d%d)$")
	if hour then
		return { hour = tonumber(hour), min = tonumber(min) }
	end

	-- Try HH:MMam/pm format
	hour, min = time_str:match("^(%d%d?):(%d%d)([ap]m)$")
	if hour then
		local h = tonumber(hour)
		local pm = time_str:match("pm$")
		if pm and h ~= 12 then
			h = h + 12
		elseif not pm and h == 12 then
			h = 0
		end
		return { hour = h, min = tonumber(min) }
	end

	-- Try HH:MM am/pm format
	hour, min = time_str:match("^(%d%d?):(%d%d)%s+([ap]m)$")
	if hour then
		local h = tonumber(hour)
		local pm = time_str:match("pm$")
		if pm and h ~= 12 then
			h = h + 12
		elseif not pm and h == 12 then
			h = 0
		end
		return { hour = h, min = tonumber(min) }
	end

	return nil
end

--- Parse datetime string (date + optional time)
function M.parse_datetime(dt_str, default_date)
	if not dt_str then
		return nil
	end

	-- Try to parse as date + time
	local date_part, time_part = dt_str:match("^(%d%d%d%d%-%d%d%-%d%d)%s+(.+)$")
	if date_part and time_part then
		local date = M.parse_date(date_part)
		local time = M.parse_time(time_part)
		if date and time then
			date.hour = time.hour
			date.min = time.min
			return date
		end
	end

	-- Try to parse as date only
	local date = M.parse_date(dt_str)
	if date then
		date.hour = 0
		date.min = 0
		return date
	end

	-- Try to parse as time only (use default date)
	local time = M.parse_time(dt_str)
	if time and default_date then
		local date = M.parse_date(default_date)
		if date then
			date.hour = time.hour
			date.min = time.min
			return date
		end
	end

	return nil
end

--- Parse duration string (e.g., "1.5h", "30min", "2d")
local function parse_duration(dur_str)
	if not dur_str then
		return nil
	end

	local num, unit = dur_str:match("^(%d+%.?%d*)%s*(%w+)$")
	if not num then
		-- Try without space
		num, unit = dur_str:match("^(%d+%.?%d*)(%w+)$")
	end

	if num then
		num = tonumber(num)
		unit = unit:lower()

		-- Convert to minutes
		if unit == "m" or unit == "min" or unit == "mins" or unit == "minute" or unit == "minutes" then
			return num
		elseif unit == "h" or unit == "hr" or unit == "hrs" or unit == "hour" or unit == "hours" then
			return num * 60
		elseif unit == "d" or unit == "day" or unit == "days" then
			return num * 60 * 24
		end
	end

	-- Special case for "0" without units
	if dur_str == "0" then
		return 0
	end

	return nil
end

--- Parse notification durations list
local function parse_notification_durations(notify_str)
	if not notify_str then
		return { 0 } -- Default: notify at event time
	end

	local durations = {}
	for dur in notify_str:gmatch("([^,]+)") do
		dur = dur:match("^%s*(.-)%s*$") -- trim
		local mins = parse_duration(dur)
		if mins then
			table.insert(durations, mins)
		end
	end

	return #durations > 0 and durations or { 0 }
end

-- Get the full path to a zortex file.
function M.get_file_path(file)
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir then
		vim.notify("g:zortex_notes_dir not set", vim.log.levels.ERROR)
		return nil
	end
	if not notes_dir:match("/$") then
		notes_dir = notes_dir .. "/"
	end
	return notes_dir .. file
end

-- =============================================================================
-- Multi-file Utilities
-- =============================================================================

--- Load a zortex file and cache its content
function M.load_file(filename)
	if state.file_cache[filename] then
		return state.file_cache[filename]
	end

	local path = M.get_file_path(filename)
	if not path or vim.fn.filereadable(path) == 0 then
		return nil
	end

	local content = {}
	for line in io.lines(path) do
		table.insert(content, line)
	end

	state.file_cache[filename] = content
	return content
end

--- Clear file cache
function M.clear_file_cache()
	state.file_cache = {}
	state.link_cache = {}
	state.okr_graph = nil
end

--- Parse a link reference (e.g., [Article name], [@Tag], [#Heading], [Areas/...])
function M.parse_link(link_text)
	-- Remove brackets
	local inner = link_text:match("^%[(.-)%]$")
	if not inner then
		return nil
	end

	-- Check for area links
	local is_area_link = false
	if inner:match("^Areas/") or inner:match("^A/") then
		is_area_link = true
		-- Normalize A/ to Areas/
		inner = inner:gsub("^A/", "Areas/")
	end

	local parts = vim.split(inner, "/", { plain = true })
	local parsed_parts = {}

	for _, part in ipairs(parts) do
		local link_type, value

		if part:match("^@") then
			link_type = "tag"
			value = part:sub(2)
		elseif part:match("^#") then
			link_type = "heading"
			value = part:sub(2)
		elseif part:match("^:") then
			link_type = "label"
			value = part:sub(2)
		elseif part:match("^%*") then
			link_type = "highlight"
			value = part:sub(2)
		elseif part:match("^%%") then
			link_type = "query"
			value = part:sub(2)
		else
			link_type = "article"
			value = part
		end

		table.insert(parsed_parts, {
			type = link_type,
			value = value,
			raw = part,
		})
	end

	return {
		raw = link_text,
		parts = parsed_parts,
		is_global = inner:match("^%.%.%."),
		is_local = inner:match("^/"),
		is_area = is_area_link,
	}
end

--- Find all links in a line of text
function M.find_links_in_line(line)
	local links = {}
	for link in line:gmatch("%[([^%]]+)%]") do
		local parsed = M.parse_link("[" .. link .. "]")
		if parsed then
			table.insert(links, parsed)
		end
	end
	return links
end

--- Find target in file content based on link type
function M.find_link_target(content, link_part)
	for i, line in ipairs(content) do
		if link_part.type == "article" then
			-- Check for article declarations
			if line:match("^@@%s*" .. vim.pesc(link_part.value) .. "%s*$") then
				return { line = i, text = line }
			end
		elseif link_part.type == "tag" then
			-- Check for tags
			if line:match("^@%s*" .. vim.pesc(link_part.value) .. "%s*$") then
				return { line = i, text = line }
			end
		elseif link_part.type == "heading" then
			-- Check for headings (any level)
			if line:match("^#+%s+" .. vim.pesc(link_part.value) .. "%s*$") then
				return { line = i, text = line }
			end
		elseif link_part.type == "label" then
			-- Check for labels
			if line:match("^" .. vim.pesc(link_part.value) .. ":") then
				return { line = i, text = line }
			end
		elseif link_part.type == "highlight" then
			-- Check for highlighted text
			if line:match("%*%*?_?" .. vim.pesc(link_part.value) .. "_?%*%*?") then
				return { line = i, text = line }
			end
		elseif link_part.type == "query" then
			-- Check for any matching text
			if line:match(vim.pesc(link_part.value)) then
				return { line = i, text = line }
			end
		end
	end
	return nil
end

-- =============================================================================
-- Calendar Entry Parsing (from original utils.lua)
-- =============================================================================

--- Parse a single entry line for attributes and task status.
function M.parse_entry(entry_text, date_context)
	local parsed = {
		raw_text = entry_text,
		display_text = entry_text,
		task_status = nil,
		attributes = {},
		type = "note", -- default type
		date_context = date_context,
	}

	local working_text = entry_text

	-- 1. Check for task status
	local status_pattern = "^(%[.%])%s+(.+)$"
	local status_key, remaining_text = working_text:match(status_pattern)
	if status_key and M.TASK_STATUS[status_key] then
		parsed.task_status = M.TASK_STATUS[status_key]
		parsed.task_status.key = status_key
		parsed.type = "task"
		working_text = remaining_text
	end

	-- 2. Check for time prefix (HH:MM) or time range (HH:MM-HH:MM)
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

	-- 3. Parse all attributes
	-- XP-related attributes
	local xp_amount = working_text:match("@xp%((%d+%.?%d*)%)")
	if xp_amount then
		parsed.attributes.xp = tonumber(xp_amount)
		working_text = working_text:gsub("@xp%(%d+%.?%d*%)", "")
	end

	-- Check for final XP (never recalculated)
	local final_xp = working_text:match("@xp:final%((%d+%.?%d*)%)")
	if final_xp then
		parsed.attributes.xp = tonumber(final_xp)
		parsed.attributes.xp_final = true
		working_text = working_text:gsub("@xp:final%(%d+%.?%d*%)", "")
	end

	-- Size attributes
	local size = working_text:match("@(xs|sm|md|lg|xl)%s") or working_text:match("@(xs|sm|md|lg|xl)$")
	if size then
		parsed.attributes.size = size
		working_text = working_text:gsub("@" .. size, "")
	end

	-- Priority and importance
	local priority = working_text:match("@p([123])%s") or working_text:match("@p([123])$")
	if priority then
		parsed.attributes.priority = "p" .. priority
		working_text = working_text:gsub("@p" .. priority, "")
	end

	local importance = working_text:match("@i([123])%s") or working_text:match("@i([123])$")
	if importance then
		parsed.attributes.importance = "i" .. importance
		working_text = working_text:gsub("@i" .. importance, "")
	end

	-- Duration/estimation
	local est = working_text:match("@est%(([^)]+)%)")
	if est then
		parsed.attributes.estimation = parse_duration(est)
		working_text = working_text:gsub("@est%([^)]+%)", "")
	end

	local duration = working_text:match("@(%d+%.?%d*[hmd])")
	if duration then
		parsed.attributes.duration = parse_duration(duration)
		working_text = working_text:gsub("@" .. vim.pesc(duration), "")
	end

	-- Other attributes with parentheses
	local paren_attributes = {
		at = "@at%(([^)]+)%)",
		due = "@due%(([^)]+)%)",
		from = "@from%(([^)]+)%)",
		to = "@to%(([^)]+)%)",
		repeating = "@repeat%(([^)]+)%)",
		notify = "@notify%(([^)]+)%)",
		n = "@n%(([^)]+)%)",
		event = "@event%(([^)]+)%)",
	}

	for attr_name, pattern in pairs(paren_attributes) do
		local value = working_text:match(pattern)
		if value then
			if attr_name == "notify" or attr_name == "n" or attr_name == "event" then
				parsed.attributes.notification_enabled = true
				parsed.attributes.notification_durations = parse_notification_durations(value)
			elseif not (attr_name == "at" and parsed.attributes.at) then
				parsed.attributes[attr_name] = value
			end
			working_text = working_text:gsub(pattern, "")
		end
	end

	-- Handle attributes without parentheses
	if working_text:match("@n%s") or working_text:match("@n$") then
		parsed.attributes.notification_enabled = true
		parsed.attributes.notification_durations = parsed.attributes.notification_durations or { 0 }
		working_text = working_text:gsub("@n", "")
	end

	if working_text:match("@event%s") or working_text:match("@event$") then
		parsed.attributes.notification_enabled = true
		parsed.attributes.notification_durations = parsed.attributes.notification_durations or { 0 }
		working_text = working_text:gsub("@event", "")
	end

	if working_text:match("@notify%s") or working_text:match("@notify$") then
		parsed.attributes.notification_enabled = true
		parsed.attributes.notification_durations = parsed.attributes.notification_durations or { 0 }
		working_text = working_text:gsub("@notify", "")
	end

	-- Context
	local context = working_text:match("@(%w+)")
	if context and not context:match("^[pxi]%d") then
		parsed.attributes.context = context
		working_text = working_text:gsub("@" .. context, "")
	end

	-- 4. Determine final entry type
	if parsed.attributes.at or parsed.attributes.notification_enabled then
		parsed.type = "event"
	end

	-- 5. Extract links
	parsed.links = M.find_links_in_line(working_text)

	-- 6. Clean up display text
	parsed.display_text = working_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

	return parsed
end

-- =============================================================================
-- OKR Graph Building
-- =============================================================================

--- Parse OKR file and build graph structure
function M.build_okr_graph()
	if state.okr_graph then
		return state.okr_graph
	end

	local content = M.load_file(M.OKR_FILE)
	if not content then
		return nil
	end

	local graph = {
		objectives = {},
		key_results = {},
		current_objectives = {},
		previous_objectives = {},
	}

	local current_section = nil
	local current_objective = nil
	local in_key_result = false

	for i, line in ipairs(content) do
		-- Section headers
		if line:match("^# Current%s*$") then
			current_section = "current"
		elseif line:match("^# Previous%s*$") then
			current_section = "previous"
		-- Objective pattern: ## <span> YYYY MM Title
		elseif line:match("^## ") then
			local span, year, month, title = line:match("^## (%w+) (%d%d%d%d) (%d%d) (.+)$")
			if span and year and month and title then
				current_objective = {
					span = span,
					year = tonumber(year),
					month = tonumber(month),
					title = title,
					key_results = {},
					line = i,
					is_current = (current_section == "current"),
				}

				table.insert(graph.objectives, current_objective)
				if current_section == "current" then
					table.insert(graph.current_objectives, current_objective)
				else
					table.insert(graph.previous_objectives, current_objective)
				end
			end
		-- Key results and their project links
		elseif current_objective then
			-- Check if this is a key result (KR-1, KR-2, etc.)
			if line:match("^%s*%-%s*KR%-%d+:") then
				local kr_text = line:match("^%s*%-%s*KR%-%d+:%s*(.+)$")
				if kr_text then
					local key_result = {
						text = kr_text,
						objective = current_objective,
						projects = {},
						line = i,
					}

					-- Find project links in the key result
					local links = M.find_links_in_line(kr_text)
					for _, link in ipairs(links) do
						table.insert(key_result.projects, link)
					end

					table.insert(current_objective.key_results, key_result)
					table.insert(graph.key_results, key_result)
				end
			end
		end
	end

	state.okr_graph = graph
	return graph
end

-- =============================================================================
-- XP Calculation
-- =============================================================================

--- Get all area links for a project, including inherited ones from parent projects
function M.get_project_areas(project_content, project_level, start_line)
	local areas = {}
	local area_priority = {} -- Track priority (1 = direct, 2 = parent, 3 = grandparent, etc.)

	-- Helper to add areas with priority
	local function add_areas_with_priority(links, priority)
		for _, link in ipairs(links) do
			if link.is_area then
				local area_path = link.raw:gsub("^%[", ""):gsub("%]$", "")
				if not area_priority[area_path] or priority < area_priority[area_path] then
					area_priority[area_path] = priority
					areas[area_path] = priority
				end
			end
		end
	end

	-- First, get areas from the current project heading line
	local current_links = M.find_links_in_line(project_content[start_line])
	add_areas_with_priority(current_links, 1)

	-- Look upward for parent project headings
	local current_priority = 2
	for i = start_line - 1, 1, -1 do
		local line = project_content[i]
		local level, heading = line:match("^(#+)%s+(.+)$")
		if level and #level < project_level then
			-- Found a parent heading
			local parent_links = M.find_links_in_line(line)
			add_areas_with_priority(parent_links, current_priority)
			current_priority = current_priority + 1
		end
	end

	-- Convert to sorted list by priority
	local sorted_areas = {}
	for area, priority in pairs(areas) do
		table.insert(sorted_areas, { area = area, priority = priority })
	end
	table.sort(sorted_areas, function(a, b)
		return a.priority < b.priority
	end)

	return sorted_areas
end

--- Parse special XP tag at top of archive file
function M.parse_special_xp_tag(content)
	-- Look for @XP(...) in the first few lines
	for i = 1, math.min(#content, 10) do
		local xp = content[i]:match("@XP%((%d+%.?%d*)%)")
		if xp then
			return tonumber(xp), i
		end
	end
	return nil, nil
end

--- Update special XP tag in content
function M.update_special_xp_tag(content, new_xp)
	local current_xp, line_idx = M.parse_special_xp_tag(content)

	if line_idx then
		-- Update existing tag
		content[line_idx] = content[line_idx]:gsub("@XP%(%d+%.?%d*%)", "@XP(" .. new_xp .. ")")
	else
		-- Add new tag after article declarations and tags
		local insert_idx = 1

		-- Skip past @@ declarations and @ tags
		for i, line in ipairs(content) do
			if line:match("^@@") or line:match("^@[^X]") then
				insert_idx = i + 1
			elseif line:match("^%s*$") then
				-- Continue past empty lines
				insert_idx = i + 1
			else
				break
			end
		end

		-- Insert the XP tag
		table.insert(content, insert_idx, "@XP(" .. new_xp .. ")")
	end

	return content
end

--- Calculate XP for a project and all its sub-projects
function M.calculate_project_tree_xp(content, start_line, project_level, force_recalc)
	local total_xp = 0
	local cfg = config.current.xp
	local project_name = content[start_line]:match("^#+%s+(.+)$")

	-- Clean project name
	project_name = project_name:gsub("%s*@xp%(%d+%.?%d*%)%s*$", "")
	project_name = project_name:gsub("%s*@xp:final%(%d+%.?%d*%)%s*$", "")

	-- Check if this project has final XP
	local final_xp = content[start_line]:match("@xp:final%((%d+%.?%d*)%)")
	if final_xp and not force_recalc then
		return tonumber(final_xp)
	end

	-- Find project boundaries
	local project_end = #content
	for i = start_line + 1, #content do
		local level = content[i]:match("^(#+)")
		if level and #level <= project_level then
			project_end = i - 1
			break
		end
	end

	-- Collect tasks and sub-projects
	local tasks = {}
	local sub_projects_xp = 0

	for i = start_line + 1, project_end do
		local line = content[i]

		-- Check for sub-project headings
		local sub_level, sub_heading = line:match("^(#+)%s+(.+)$")
		if sub_level and #sub_level > project_level then
			-- Calculate sub-project XP recursively
			local sub_xp = M.calculate_project_tree_xp(content, i, #sub_level, force_recalc)
			sub_projects_xp = sub_projects_xp + sub_xp

			-- Skip to end of this sub-project
			for j = i + 1, project_end do
				local next_level = content[j]:match("^(#+)")
				if next_level and #next_level <= #sub_level then
					i = j - 1
					break
				end
			end
		else
			-- Parse as potential task
			local parsed = M.parse_entry(line, nil)
			if parsed.task_status then
				table.insert(tasks, parsed)
			end
		end
	end

	-- Calculate base project XP
	local project_xp = M.calculate_project_xp(project_name, tasks)

	-- Add sub-projects XP
	total_xp = project_xp + sub_projects_xp

	return total_xp
end

--- Recalculate XP for current project or all projects
function M.recalculate_xp(force_all)
	local filename = vim.fn.expand("%:t")
	if filename ~= M.ARCHIVE_PROJECTS_FILE then
		vim.notify("This command only works in archive.projects.zortex", vim.log.levels.ERROR)
		return
	end

	local content = {}
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	for _, line in ipairs(lines) do
		table.insert(content, line)
	end

	if force_all then
		-- Recalculate all projects
		local total_xp = 0
		local updates = {}

		for i, line in ipairs(content) do
			local level, heading = line:match("^(#+)%s+(.+)$")
			if level and #level == 1 then
				-- Top-level project
				local project_xp = M.calculate_project_tree_xp(content, i, 1, true)
				total_xp = total_xp + project_xp

				-- Update the heading with new XP
				local clean_heading = heading:gsub("%s*@xp%(%d+%.?%d*%)%s*$", "")
				clean_heading = clean_heading:gsub("%s*@xp:final%(%d+%.?%d*%)%s*$", "")

				-- Preserve final status if it existed
				if heading:match("@xp:final%(") then
					updates[i] = level .. " " .. clean_heading .. " @xp:final(" .. project_xp .. ")"
				else
					updates[i] = level .. " " .. clean_heading .. " @xp(" .. project_xp .. ")"
				end
			end
		end

		-- Apply updates
		for line_num, new_content in pairs(updates) do
			content[line_num] = new_content
		end

		-- Update special XP tag
		content = M.update_special_xp_tag(content, total_xp)

		-- Write back to buffer
		vim.api.nvim_buf_set_lines(0, 0, -1, false, content)
		vim.notify(string.format("Recalculated all projects. Total XP: %d", total_xp), vim.log.levels.INFO)
	else
		-- Find current project
		local cursor_line = vim.fn.line(".")
		local project_line = nil
		local project_level = nil

		-- Look for heading at or above cursor
		for i = cursor_line, 1, -1 do
			local level, heading = content[i]:match("^(#+)%s+(.+)$")
			if level then
				project_line = i
				project_level = #level
				break
			end
		end

		if not project_line then
			vim.notify("No project heading found", vim.log.levels.ERROR)
			return
		end

		-- Calculate XP for this project tree
		local project_xp = M.calculate_project_tree_xp(content, project_line, project_level, true)

		-- Update the heading
		local level, heading = content[project_line]:match("^(#+)%s+(.+)$")
		local clean_heading = heading:gsub("%s*@xp%(%d+%.?%d*%)%s*$", "")
		clean_heading = clean_heading:gsub("%s*@xp:final%(%d+%.?%d*%)%s*$", "")

		-- Preserve final status if it existed
		if heading:match("@xp:final%(") then
			content[project_line] = level .. " " .. clean_heading .. " @xp:final(" .. project_xp .. ")"
		else
			content[project_line] = level .. " " .. clean_heading .. " @xp(" .. project_xp .. ")"
		end

		-- If this was a top-level project, recalculate total
		if project_level == 1 then
			local total_xp = 0
			for i, line in ipairs(content) do
				local lvl, _ = line:match("^(#)%s+")
				if lvl then
					local xp = line:match("@xp%((%d+%.?%d*)%)") or line:match("@xp:final%((%d+%.?%d*)%)")
					if xp then
						total_xp = total_xp + tonumber(xp)
					end
				end
			end
			content = M.update_special_xp_tag(content, total_xp)
		end

		-- Write back to buffer
		vim.api.nvim_buf_set_lines(0, 0, -1, false, content)
		vim.notify(string.format("Recalculated project XP: %d", project_xp), vim.log.levels.INFO)
	end
end

--- Calculate temporal penalty based on OKR age
function M.calculate_temporal_penalty(objective)
	if objective.is_current then
		return config.get("xp.temporal_penalties.current") or 1.0
	end

	local current_time = os.time()
	local obj_time = os.time({
		year = objective.year,
		month = objective.month,
		day = 1,
	})

	local months_diff = math.floor((current_time - obj_time) / (30 * 24 * 60 * 60))

	if months_diff <= 3 then
		return config.get("xp.temporal_penalties.recent") or 0.8
	elseif months_diff <= 12 then
		return config.get("xp.temporal_penalties.past_year") or 0.6
	else
		return config.get("xp.temporal_penalties.old") or 0.4
	end
end

--- Find all OKRs connected to a project
function M.find_connected_okrs(project_name)
	local graph = M.build_okr_graph()
	if not graph then
		return {}
	end

	local connected_okrs = {}

	for _, kr in ipairs(graph.key_results) do
		for _, link in ipairs(kr.projects) do
			-- Check if any part of the link matches the project name
			for _, part in ipairs(link.parts) do
				if part.type == "article" and part.value == project_name then
					table.insert(connected_okrs, {
						objective = kr.objective,
						key_result = kr,
					})
					break
				end
			end
		end
	end

	return connected_okrs
end

--- Calculate XP for a single task
function M.calculate_task_xp(task)
	local cfg = config.current.xp

	-- Base XP
	local base_xp = cfg.base_xp.task or 10

	-- Size multiplier
	local size = task.attributes.size or cfg.default_task_size or "md"
	local size_mult = cfg.task_sizes[size] and cfg.task_sizes[size].xp_multiplier or 1.0

	-- Priority multiplier
	local priority = task.attributes.priority or "default"
	local priority_mult = cfg.priority_multipliers[priority] or cfg.priority_multipliers.default or 0.9

	-- Importance multiplier
	local importance = task.attributes.importance or "default"
	local importance_mult = cfg.importance_multipliers[importance] or cfg.importance_multipliers.default or 0.9

	-- Duration-based adjustment
	local duration_mult = 1.0
	if task.attributes.duration or task.attributes.estimation then
		local minutes = task.attributes.duration or task.attributes.estimation
		local expected_minutes = cfg.task_sizes[size] and cfg.task_sizes[size].duration or 60
		-- Give bonus XP for tasks that took longer than expected
		duration_mult = math.max(0.5, math.min(2.0, minutes / expected_minutes))
	end

	-- Calculate total
	local total_xp = base_xp * size_mult * priority_mult * importance_mult * duration_mult

	-- Apply pre-calculated XP if it exists
	if task.attributes.xp then
		return task.attributes.xp
	end

	return math.floor(total_xp + 0.5) -- Round to nearest integer
end

--- Calculate XP for a project based on its tasks and connections
function M.calculate_project_xp(project_name, tasks, project_areas)
	local cfg = config.current.xp

	-- Base project XP
	local base_xp = cfg.base_xp.project or 50

	-- Sum up task XP
	local task_xp = 0
	for _, task in ipairs(tasks or {}) do
		if task.task_status and task.task_status.key == "[x]" then
			task_xp = task_xp + M.calculate_task_xp(task)
		end
	end

	-- Check OKR connections
	local connected_okrs = M.find_connected_okrs(project_name)
	local okr_multiplier = 1.0
	local best_span_mult = 1.0
	local best_temporal_mult = 1.0

	if #connected_okrs > 0 then
		okr_multiplier = cfg.base_xp.okr_connected_bonus or 2.0

		-- Find best multipliers from connected OKRs
		for _, connection in ipairs(connected_okrs) do
			local span_mult = cfg.span_multipliers[connection.objective.span] or 1.0
			local temporal_mult = M.calculate_temporal_penalty(connection.objective)

			best_span_mult = math.max(best_span_mult, span_mult)
			best_temporal_mult = math.max(best_temporal_mult, temporal_mult)
		end
	end

	-- Calculate total project XP
	local total_xp = (base_xp + task_xp) * okr_multiplier * best_span_mult * best_temporal_mult

	-- Apply area-based skill transfer if areas are provided
	if project_areas and #project_areas > 0 then
		-- Areas are already sorted by priority
		-- For now, we don't modify XP based on areas, but this could be extended
		-- to distribute XP across multiple skill areas
	end

	return math.floor(total_xp + 0.5)
end

-- =============================================================================
-- Project Archiving
-- =============================================================================

--- Archive a project to the archive file
function M.archive_project(project_name)
	local projects_content = M.load_file(M.PROJECTS_FILE)
	if not projects_content then
		vim.notify("Could not load projects file", vim.log.levels.ERROR)
		return false
	end

	-- Find the project in the content
	local project_start = nil
	local project_end = nil
	local project_level = nil

	for i, line in ipairs(projects_content) do
		-- Check for project heading
		local level, heading = line:match("^(#+)%s+(.+)$")
		if level and heading then
			-- Remove any existing @xp attribute for comparison
			local clean_heading = heading:gsub("%s*@xp%(%d+%.?%d*%)%s*$", "")
			clean_heading = clean_heading:gsub("%s*@xp:final%(%d+%.?%d*%)%s*$", "")

			if clean_heading == project_name then
				project_start = i
				project_level = #level
			elseif project_start and #level <= project_level then
				-- Found next heading at same or higher level
				project_end = i - 1
				break
			end
		end
	end

	if not project_start then
		vim.notify("Project not found: " .. project_name, vim.log.levels.ERROR)
		return false
	end

	-- If we didn't find the end, it goes to the end of file
	if not project_end then
		project_end = #projects_content
	end

	-- Extract project content
	local project_lines = {}
	for i = project_start, project_end do
		table.insert(project_lines, projects_content[i])
	end

	-- Calculate XP for the entire project tree
	local project_xp = M.calculate_project_tree_xp(projects_content, project_start, project_level, false)

	-- Update project heading with XP
	project_lines[1] = project_lines[1]:gsub("%s*$", "") .. " @xp(" .. project_xp .. ")"

	-- Load or create archive file
	local archive_path = M.get_file_path(M.ARCHIVE_PROJECTS_FILE)
	local archive_dir = vim.fn.fnamemodify(archive_path, ":h")
	vim.fn.mkdir(archive_dir, "p")

	local archive_content = {}
	if vim.fn.filereadable(archive_path) == 1 then
		for line in io.lines(archive_path) do
			table.insert(archive_content, line)
		end
	end

	-- Find appropriate place to insert in archive
	local insert_idx = nil
	local after_metadata = false

	-- Look for first top-level heading
	for i, line in ipairs(archive_content) do
		if not after_metadata and not line:match("^@@") and not line:match("^@") and line:match("%S") then
			after_metadata = true
		end

		if after_metadata and line:match("^# ") then
			insert_idx = i
			break
		end
	end

	-- If no top-level heading found, append at end
	if not insert_idx then
		insert_idx = #archive_content + 1
	end

	-- Insert the archived project
	local new_archive = {}

	-- Copy content before insertion point
	for i = 1, insert_idx - 1 do
		table.insert(new_archive, archive_content[i])
	end

	-- Add archived project
	for _, line in ipairs(project_lines) do
		table.insert(new_archive, line)
	end
	table.insert(new_archive, "") -- Empty line after project

	-- Copy remaining content
	for i = insert_idx, #archive_content do
		table.insert(new_archive, archive_content[i])
	end

	-- Calculate total XP from all top-level projects
	local total_xp = 0
	for _, line in ipairs(new_archive) do
		local level, heading = line:match("^(#)%s+(.+)$")
		if level then
			-- Extract XP from top-level projects only
			local xp = heading:match("@xp%((%d+%.?%d*)%)") or heading:match("@xp:final%((%d+%.?%d*)%)")
			if xp then
				total_xp = total_xp + tonumber(xp)
			end
		end
	end

	-- Update special XP tag
	new_archive = M.update_special_xp_tag(new_archive, total_xp)

	-- Write archive file
	local archive_file = io.open(archive_path, "w")
	if not archive_file then
		vim.notify("Could not write to archive file", vim.log.levels.ERROR)
		return false
	end

	for _, line in ipairs(new_archive) do
		archive_file:write(line .. "\n")
	end
	archive_file:close()

	-- Remove project from original file
	local new_projects = {}
	for i = 1, project_start - 1 do
		table.insert(new_projects, projects_content[i])
	end
	for i = project_end + 1, #projects_content do
		table.insert(new_projects, projects_content[i])
	end

	-- Write updated projects file
	local projects_path = M.get_file_path(M.PROJECTS_FILE)
	local projects_file = io.open(projects_path, "w")
	if not projects_file then
		vim.notify("Could not update projects file", vim.log.levels.ERROR)
		return false
	end

	for _, line in ipairs(new_projects) do
		projects_file:write(line .. "\n")
	end
	projects_file:close()

	-- Clear cache
	M.clear_file_cache()

	vim.notify(
		string.format("Archived project '%s' with %d XP (Total: %d XP)", project_name, project_xp, total_xp),
		vim.log.levels.INFO
	)
	return true
end

-- =============================================================================
-- Calendar Loading/Saving (from original)
-- =============================================================================

--- Loads and parses the calendar data from the file.
function M.load()
	local path = M.get_file_path(M.CALENDAR_FILE)
	if not path then
		return
	end

	-- Reset state
	state.raw_data = {}
	state.parsed_data = {}

	if vim.fn.filereadable(path) == 0 then
		return
	end

	local current_date = nil
	for line in io.lines(path) do
		local m, d, y = line:match("^(%d%d)%-(%d%d)%-(%d%d%d%d):$")
		if m and d and y then
			current_date = string.format("%04d-%02d-%02d", y, m, d)
			state.raw_data[current_date] = {}
			state.parsed_data[current_date] = {}
		elseif current_date and line:match("^%s+%- ") then
			local entry_text = line:match("^%s+%- (.+)$")
			if entry_text then
				table.insert(state.raw_data[current_date], entry_text)
				table.insert(state.parsed_data[current_date], M.parse_entry(entry_text, current_date))
			end
		elseif current_date and line:match("^%s+%d%d?:%d%d ") then
			local entry_text = line:match("^%s+(.+)$")
			if entry_text then
				table.insert(state.raw_data[current_date], entry_text)
				table.insert(state.parsed_data[current_date], M.parse_entry(entry_text, current_date))
			end
		end
	end

	return state
end

--- Saves the current calendar data to the file.
function M.save()
	local path = M.get_file_path(M.CALENDAR_FILE)
	if not path then
		return false
	end

	local file = io.open(path, "w")
	if not file then
		vim.notify("Failed to open calendar file for writing", vim.log.levels.ERROR)
		return false
	end

	local dates = {}
	for date in pairs(state.raw_data) do
		table.insert(dates, date)
	end
	table.sort(dates)

	for _, date_str in ipairs(dates) do
		local entries = state.raw_data[date_str]
		if entries and #entries > 0 then
			local y, m, d = date_str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
			file:write(string.format("%s-%s-%s:\n", m, d, y))
			for _, entry in ipairs(entries) do
				file:write("  - " .. entry .. "\n")
			end
			file:write("\n")
		end
	end

	file:close()
	return true
end

--- Adds a new entry and saves the calendar.
function M.add_entry(date_str, entry_text)
	if not state.raw_data[date_str] then
		state.raw_data[date_str] = {}
		state.parsed_data[date_str] = {}
	end
	table.insert(state.raw_data[date_str], entry_text)
	table.insert(state.parsed_data[date_str], M.parse_entry(entry_text, date_str))
	M.save()
end

--- Gets all active entries for a given date, including recurring and ranged events.
function M.get_entries_for_date(date_str)
	local target_date_obj = M.parse_date(date_str)
	if not target_date_obj then
		return {}
	end
	local target_time = os.time(target_date_obj)

	local active_entries = {}
	local added_entries = {}

	-- 1. Add standard entries for the day
	if state.parsed_data[date_str] then
		for _, entry in ipairs(state.parsed_data[date_str]) do
			if not added_entries[entry.raw_text] then
				table.insert(active_entries, entry)
				added_entries[entry.raw_text] = true
			end
		end
	end

	-- 2. Check all other entries for recurring, ranged, or due attributes
	for original_date_str, entries in pairs(state.parsed_data) do
		local original_date_obj = M.parse_date(original_date_str)
		if original_date_obj then
			local original_time = os.time(original_date_obj)

			for _, entry in ipairs(entries) do
				if not added_entries[entry.raw_text] then
					local is_recurring, is_ranged = false, false

					-- Check for @repeat
					if entry.attributes.repeating and target_time > original_time then
						local repeat_val = entry.attributes.repeating:lower()
						local diff_days = math.floor((target_time - original_time) / 86400)
						if repeat_val == "daily" then
							is_recurring = true
						elseif repeat_val == "weekly" and diff_days > 0 and diff_days % 7 == 0 then
							is_recurring = true
						end
					end

					-- Check for @from/@to range
					if entry.attributes.from or entry.attributes.to then
						local from_dt = M.parse_datetime(entry.attributes.from, original_date_str)
						local to_dt = M.parse_datetime(entry.attributes.to, original_date_str)
						local from_time = from_dt and os.time(from_dt) or original_time
						local to_time = to_dt and os.time(to_dt) or from_time
						if target_time >= from_time and target_time <= to_time then
							is_ranged = true
						end
					end

					if is_recurring or is_ranged then
						local instance = M.deepcopy(entry)
						instance.is_recurring_instance = is_recurring
						instance.is_ranged_instance = is_ranged
						instance.effective_date = date_str
						table.insert(active_entries, instance)
						added_entries[entry.raw_text] = true
					end
				end

				-- Check for @due date
				if entry.attributes.due then
					local due_dt = M.parse_datetime(entry.attributes.due, original_date_str)
					if due_dt then
						local due_date_str = string.format("%04d-%02d-%02d", due_dt.year, due_dt.month, due_dt.day)
						if due_date_str == date_str and not added_entries[entry.raw_text] then
							local due_entry = M.deepcopy(entry)
							due_entry.is_due_date_instance = true
							due_entry.effective_date = date_str
							table.insert(active_entries, due_entry)
							added_entries[entry.raw_text] = true
						end
					end
				end
			end
		end
	end

	return active_entries
end

--- Returns all parsed entries, useful for Telescope.
function M.get_all_parsed_entries()
	return state.parsed_data
end

return M
