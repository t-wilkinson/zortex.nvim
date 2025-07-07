-- utils.lua - Shared utilities for Zortex system
local M = {}

-- =============================================================================
-- Task Attribute Parsing
-- =============================================================================

--- Parse task attributes from a line
-- @param line string The line to parse
-- @param config table Configuration with task_sizes and default_task_size
-- @return table Attributes table with size, priority, importance, duration, estimation
function M.parse_task_attributes(line, config)
	local attrs = {
		size = config.default_task_size or "md",
		priority = nil,
		importance = nil,
		duration = nil,
		estimation = nil,
	}

	-- Parse size
	for size, _ in pairs(config.task_sizes or {}) do
		if line:match("@" .. size .. "%s") or line:match("@" .. size .. "$") then
			attrs.size = size
			break
		end
	end

	-- Parse priority
	local priority = line:match("@p(%d)")
	if priority then
		attrs.priority = "p" .. priority
	end

	-- Parse importance
	local importance = line:match("@i(%d)")
	if importance then
		attrs.importance = "i" .. importance
	end

	-- Parse duration (e.g., @2h, @30m)
	local duration_match = line:match("@(%d+)([hm])")
	if duration_match then
		local amount, unit = line:match("@(%d+)([hm])")
		attrs.duration = unit == "h" and tonumber(amount) * 60 or tonumber(amount)
	end

	-- Parse estimation (e.g., @est(2h), @est(30m))
	local est_match = line:match("@est%((%d+)([hm])%)")
	if est_match then
		local amount, unit = line:match("@est%((%d+)([hm])%)")
		attrs.estimation = unit == "h" and tonumber(amount) * 60 or tonumber(amount)
	end

	return attrs
end

-- =============================================================================
-- Navigation Helpers
-- =============================================================================

--- Find current project heading by searching backwards
-- @param bufnr number Buffer number (0 for current)
-- @return string|nil Project heading or nil if not found
function M.find_current_project(bufnr)
	bufnr = bufnr or 0
	local current_line = vim.fn.line(".")
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, current_line, false)

	-- Search backwards for a project heading
	for i = #lines, 1, -1 do
		local heading = lines[i]:match("^#+ (.+)$")
		if heading then
			return heading
		end
	end

	return nil
end

--- Get all headings from a buffer
-- @param bufnr number Buffer number (0 for current)
-- @return table Array of {level, text, lnum} tables
function M.get_all_headings(bufnr)
	bufnr = bufnr or 0
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local headings = {}

	for lnum, line in ipairs(lines) do
		local level = 0
		local i = 1
		while i <= #line and line:sub(i, i) == "#" do
			level = level + 1
			i = i + 1
		end

		if level > 0 and (line:sub(level + 1, level + 1) == " " or level == #line) then
			local text = line:sub(level + 1):match("^%s*(.-)%s*$")
			table.insert(headings, {
				level = level,
				text = text,
				lnum = lnum,
			})
		end
	end

	return headings
end

-- =============================================================================
-- File Operations
-- =============================================================================

--- Read file lines with error handling
-- @param filepath string Path to file
-- @return table|nil Array of lines or nil on error
function M.read_file_lines(filepath)
	local file = io.open(filepath, "r")
	if not file then
		return nil
	end

	local lines = {}
	for line in file:lines() do
		table.insert(lines, line)
	end
	file:close()

	return lines
end

--- Find files in directory with pattern
-- @param dir string Directory path
-- @param pattern string Lua pattern to match filenames
-- @return table Array of full file paths
function M.find_files(dir, pattern)
	local files = {}
	local scandir = vim.loop.fs_scandir(dir)
	if not scandir then
		return files
	end

	while true do
		local name, type = vim.loop.fs_scandir_next(scandir)
		if not name then
			break
		end

		if type == "file" and name:match(pattern) then
			local full_path = dir .. "/" .. name
			table.insert(files, full_path)
		end
	end

	return files
end

-- =============================================================================
-- String Utilities
-- =============================================================================

--- Trim whitespace from string
-- @param str string String to trim
-- @return string Trimmed string
function M.trim(str)
	return str:match("^%s*(.-)%s*$") or ""
end

--- Escape string for Lua pattern matching
-- @param text string Text to escape
-- @return string Escaped text
function M.escape_pattern(text)
	if not text then
		return ""
	end
	return text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

-- =============================================================================
-- Date/Time Utilities
-- =============================================================================

--- Parse date from OKR objective line format
-- @param line string Line containing "## SPAN YYYY MM Title"
-- @return table|nil Table with {span, year, month, title} or nil
function M.parse_okr_date(line)
	local span, year, month, title = line:match("^## ([%w]+) (%d+) (%d+) (.+)$")
	if span then
		return {
			span = span,
			year = tonumber(year),
			month = tonumber(month),
			title = title,
		}
	end
	return nil
end

--- Calculate months between two dates
-- @param date1 table Date with year and month fields
-- @param date2 table Date with year and month fields
-- @return number Months difference
function M.months_between(date1, date2)
	return (date2.year - date1.year) * 12 + (date2.month - date1.month)
end

-- =============================================================================
-- Task/Project Utilities
-- =============================================================================

--- Check if a line is a task
-- @param line string Line to check
-- @return boolean, boolean Is task, Is completed
function M.is_task_line(line)
	local unchecked = line:match("^%s*%- %[ %]")
	local checked = line:match("^%s*%- %[x%]") or line:match("^%s*%- %[X%]")

	return (unchecked or checked) ~= nil, checked ~= nil
end

--- Extract task text from task line
-- @param line string Task line
-- @return string|nil Task text without checkbox
function M.get_task_text(line)
	local text = line:match("^%s*%- %[.%] (.+)$")
	return text
end

--- Get task completion state
-- @param line string Task line
-- @return string "todo", "done", or "not_task"
function M.get_task_state(line)
	if line:match("^%s*%- %[ %]") then
		return "todo"
	elseif line:match("^%s*%- %[x%]") or line:match("^%s*%- %[X%]") then
		return "done"
	else
		return "not_task"
	end
end

-- =============================================================================
-- Link Utilities (helpers for working with links.lua)
-- =============================================================================

--- Check if a project is linked in the given text
-- @param text string Text to search in
-- @param project_name string Project name to search for
-- @return boolean True if project is linked
function M.is_project_linked(text, project_name)
	local links = require("zortex.links")

	-- TODO: refactor as necessary to use links module to check if project is linked
	-- We might have to pass the full project heading path and check if the link would match the project path.
	return false
end

--- Extract all links from a line
-- @param line string Line to extract links from
-- @return table Array of link info tables
function M.extract_all_links(line)
	local links = require("zortex.links")
	local found_links = {}
	local offset = 0

	while offset < #line do
		local link_info = links.extract_link(line, offset)
		if link_info then
			table.insert(found_links, link_info)
			-- Move offset past this link
			local _, end_pos = line:find(M.escape_pattern(link_info.full_match_text), offset + 1)
			offset = end_pos or offset + 1
		else
			offset = offset + 1
		end
	end

	return found_links
end

return M
