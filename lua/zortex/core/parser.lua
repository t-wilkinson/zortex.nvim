-- core/parser.lua - Unified parsing logic for Zortex
local M = {}

local constants = require("zortex.constants")
local config = require("zortex.core.config")

-- =============================================================================
-- Section Types (unified from search.lua)
-- =============================================================================

M.SectionType = {
	ARTICLE = 1,
	TAG = 2,
	HEADING = 3,
	BOLD_HEADING = 4,
	LABEL = 5,
	TEXT = 6,
}

-- =============================================================================
-- String Utilities
-- =============================================================================

function M.trim(str)
	return str:match("^%s*(.-)%s*$") or ""
end

function M.escape_pattern(text)
	if not text then
		return ""
	end
	return text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

-- =============================================================================
-- Section Detection (unified)
-- =============================================================================

function M.detect_section_type(line)
	if not line or line == "" then
		return M.SectionType.TEXT
	end

	-- Article title (@@...)
	if line:match("^@@") then
		return M.SectionType.ARTICLE
	end

	-- Tags/aliases (@...)
	if line:match("^@[^@]") then
		return M.SectionType.TAG
	end

	-- Markdown headings (#...)
	if line:match("^%s*#+%s") then
		return M.SectionType.HEADING
	end

	-- Bold headings (**text** or **text**:)
	if line:match("^%*%*[^%*]+%*%*:?$") then
		return M.SectionType.BOLD_HEADING
	end

	-- Labels (word(s): ...)
	if line:match("^%w[^:]+:") then
		return M.SectionType.LABEL
	end

	return M.SectionType.TEXT
end

-- Get heading level from line
function M.get_heading_level(line)
	local hashes = line:match("^(#+)")
	return hashes and #hashes or 0
end

-- Parse heading (returns level and text)
function M.parse_heading(line)
	local level, text = line:match("^(#+)%s+(.+)$")
	if level and text then
		return {
			level = #level,
			text = M.trim(text),
			raw = line,
		}
	end
	return nil
end

-- Check if line is a bold heading
function M.is_bold_heading(line)
	return line:match("^%*%*[^%*]+%*%*:?$") ~= nil
end

-- =============================================================================
-- Section Boundaries (unified)
-- =============================================================================

function M.find_section_end(lines, start_idx, section_type)
	if start_idx > #lines then
		return #lines
	end

	local start_line = lines[start_idx]

	-- Article/tag sections span the entire file
	if section_type == M.SectionType.ARTICLE or section_type == M.SectionType.TAG then
		return #lines
	end

	-- Heading sections end at next heading of same or higher level
	if section_type == M.SectionType.HEADING then
		local level = M.get_heading_level(start_line)
		for i = start_idx + 1, #lines do
			local line_type = M.detect_section_type(lines[i])
			if line_type == M.SectionType.HEADING then
				local next_level = M.get_heading_level(lines[i])
				if next_level <= level then
					return i - 1
				end
			end
		end
		return #lines
	end

	-- Bold heading sections end at next heading or bold heading
	if section_type == M.SectionType.BOLD_HEADING then
		for i = start_idx + 1, #lines do
			local line_type = M.detect_section_type(lines[i])
			if line_type == M.SectionType.HEADING or line_type == M.SectionType.BOLD_HEADING then
				return i - 1
			end
		end
		return #lines
	end

	-- Label sections end at next heading, bold heading, or empty line
	if section_type == M.SectionType.LABEL then
		for i = start_idx + 1, #lines do
			if lines[i] == "" then
				return i - 1
			end
			local line_type = M.detect_section_type(lines[i])
			if line_type == M.SectionType.HEADING or line_type == M.SectionType.BOLD_HEADING then
				return i - 1
			end
		end
		return #lines
	end

	-- Text sections are single lines
	return start_idx
end

-- =============================================================================
-- Time/Date Parsing (unified from calendar/utils.lua)
-- =============================================================================

function M.parse_date(date_str)
	if not date_str then
		return nil
	end

	-- YYYY-MM-DD
	local y, m, d = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if y then
		return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
	end

	-- MM-DD-YYYY
	local m2, d2, y2 = date_str:match("^(%d%d)%-(%d%d)%-(%d%d%d%d)$")
	if m2 then
		return { year = tonumber(y2), month = tonumber(m2), day = tonumber(d2) }
	end

	return nil
end

function M.parse_time(time_str)
	if not time_str then
		return nil
	end

	-- HH:MM format
	local hour, min = time_str:match("^(%d%d?):(%d%d)$")
	if hour then
		return { hour = tonumber(hour), min = tonumber(min) }
	end

	-- HH:MM am/pm formats
	hour, min = time_str:match("^(%d%d?):(%d%d)%s*([ap]m)$")
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

function M.parse_datetime(dt_str, default_date)
	if not dt_str then
		return nil
	end

	-- Try date + time
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

	-- Try date only
	local date = M.parse_date(dt_str)
	if date then
		date.hour = 0
		date.min = 0
		return date
	end

	-- Try time only with default date
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

function M.months_between(date1, date2)
	return (date2.year - date1.year) * 12 + (date2.month - date1.month)
end

-- =============================================================================
-- Attribute Parsing (unified)
-- =============================================================================

-- Generic attribute parser
function M.parse_attributes(text, definitions)
	local attrs = {}
	local remaining_text = text

	for _, def in ipairs(definitions) do
		local captures = { string.match(remaining_text, def.pattern) }
		if #captures > 0 then
			local value
			if def.transform then
				value = def.transform(unpack(captures))
			elseif def.value ~= nil then
				value = def.value
			else
				value = captures[1]
			end

			attrs[def.name] = value

			-- Remove matched pattern
			local full_match = remaining_text:match(def.pattern)
			if full_match then
				remaining_text = remaining_text:gsub(M.escape_pattern(full_match), "", 1)
			end
		end
	end

	remaining_text = M.trim(remaining_text):gsub("%s%s+", " ")
	return attrs, remaining_text
end

-- Parse duration string (e.g., "1.5h", "30min", "2d")
function M.parse_duration(dur_str)
	if not dur_str then
		return nil
	end

	local num, unit = dur_str:match("^(%d+%.?%d*)%s*(%w+)$")
	if not num then
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

	-- Special case for "0"
	if dur_str == "0" then
		return 0
	end

	return nil
end

-- Parse task attributes (enhanced)
function M.parse_task_attributes(line)
	local cfg = config.get("xp") or config.defaults.xp

	-- Define all possible attributes
	local definitions = {
		-- XP-related attributes
		{
			name = "size",
			pattern = "@(%w+)",
			transform = function(size)
				return (cfg.task_sizes and cfg.task_sizes[size]) and size or nil
			end,
		},
		{
			name = "priority",
			pattern = "@p([123])",
			transform = function(p)
				return "p" .. p
			end,
		},
		{
			name = "importance",
			pattern = "@i([123])",
			transform = function(i)
				return "i" .. i
			end,
		},
		{
			name = "duration",
			pattern = "@(%d+%.?%d*[hmd])",
			transform = function(dur)
				return M.parse_duration(dur)
			end,
		},
		{
			name = "estimation",
			pattern = "@est%(([^)]+)%)",
			transform = function(dur)
				return M.parse_duration(dur)
			end,
		},

		-- Time/date attributes
		{
			name = "at",
			pattern = "@at%(([^)]+)%)",
		},
		{
			name = "due",
			pattern = "@due%(([^)]+)%)",
		},
		{
			name = "from",
			pattern = "@from%(([^)]+)%)",
		},
		{
			name = "to",
			pattern = "@to%(([^)]+)%)",
		},
		{
			name = "repeating",
			pattern = "@repeat%(([^)]+)%)",
		},

		-- Other attributes
		{
			name = "done_date",
			pattern = "@done%((%d%d%d%d%-%d%d%-%d%d)%)",
		},
		{
			name = "context",
			pattern = "@(%w+)",
		},
	}

	local attrs, _ = M.parse_attributes(line, definitions)

	-- Set default size if not found
	if not attrs.size then
		attrs.size = cfg.default_task_size or "md"
	end

	return attrs
end

-- Parse project attributes
function M.parse_project_attributes(line)
	local cfg = config.get("xp") or config.defaults.xp

	local definitions = {
		-- Size
		{
			name = "size",
			pattern = "@(%w+)",
			transform = function(size)
				return (cfg.project_sizes and cfg.project_sizes[size]) and size or nil
			end,
		},
		-- Priority
		{
			name = "priority",
			pattern = "@p([123])",
			transform = function(p)
				return "p" .. p
			end,
		},
		-- Importance
		{
			name = "importance",
			pattern = "@i([123])",
			transform = function(i)
				return "i" .. i
			end,
		},
		-- Duration
		{
			name = "duration",
			pattern = "@(%d+%.?%d*[hmd])",
			transform = function(dur)
				return M.parse_duration(dur)
			end,
		},
		-- Estimation
		{
			name = "estimation",
			pattern = "@est%(([^)]+)%)",
			transform = function(dur)
				return M.parse_duration(dur)
			end,
		},
		-- Done date
		{
			name = "done_date",
			pattern = "@done%((%d%d%d%d%-%d%d%-%d%d)%)",
		},
		-- Progress
		{
			name = "progress",
			pattern = "@progress%((%d+)/(%d+)%)",
			transform = function(completed, total)
				return {
					completed = tonumber(completed),
					total = tonumber(total),
				}
			end,
		},
		-- XP
		{
			name = "xp",
			pattern = "@xp%((%d+)%)",
		},
	}

	local attrs, _ = M.parse_attributes(line, definitions)

	-- Set default size if not found
	if not attrs.size then
		attrs.size = cfg.default_project_size or "md"
	end

	return attrs
end

-- =============================================================================
-- Task Parsing
-- =============================================================================

function M.is_task_line(line)
	local unchecked = line:match("^%s*%- %[ %]")
	local checked = line:match("^%s*%- %[[xX]%]")
	return (unchecked or checked) ~= nil, checked ~= nil
end

function M.get_task_text(line)
	return line:match("^%s*%- %[.%] (.+)$")
end

function M.get_task_state(line)
	if line:match("^%s*%- %[ %]") then
		return "todo"
	elseif line:match("^%s*%- %[[xX]%]") then
		return "done"
	else
		return "not_task"
	end
end

-- Parse task status (enhanced from calendar)
M.TASK_STATUS = {
	["[ ]"] = { symbol = "☐", name = "Incomplete", hl = "Comment" },
	["[x]"] = { symbol = "☑", name = "Complete", hl = "String" },
	["[X]"] = { symbol = "☑", name = "Complete", hl = "String" },
	["[~]"] = { symbol = "◐", name = "In Progress", hl = "WarningMsg" },
	["[@]"] = { symbol = "⏸", name = "Paused", hl = "Comment" },
}

function M.parse_task_status(line)
	local status_key = line:match("^%s*%- (%[.%])")
	if status_key and M.TASK_STATUS[status_key] then
		local status = vim.tbl_extend("force", M.TASK_STATUS[status_key], { key = status_key })
		return status
	end
	return nil
end

-- =============================================================================
-- OKR Parsing
-- =============================================================================

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

-- =============================================================================
-- Link Parsing
-- =============================================================================

-- Extract link at position
function M.extract_link_at(line, cursor_col)
	-- 1. Check for footnote references
	local offset = 0
	while offset < #line do
		local s, e, ref_id = string.find(line, "%[%^([A-Za-z0-9_.-]+)%]", offset + 1)
		if not s then
			break
		end
		if cursor_col >= (s - 1) and cursor_col < e then
			return {
				type = "footnote",
				ref_id = ref_id,
				display_text = string.sub(line, s, e),
				full_match_text = string.sub(line, s, e),
			}
		end
		offset = e
	end

	-- 2. Check for markdown-style links
	offset = 0
	while offset < #line do
		local s, e, text, url = string.find(line, "%[([^%]]*)%]%(([^%)]+)%)", offset + 1)
		if not s then
			break
		end
		if cursor_col >= (s - 1) and cursor_col < e then
			return {
				type = "markdown",
				display_text = text,
				url = url,
				full_match_text = string.sub(line, s, e),
			}
		end
		offset = e
	end

	-- 3. Check for zortex-style links
	offset = 0
	while offset < #line do
		local s, e = string.find(line, "%[([^%]]+)%]", offset + 1)
		if not s then
			break
		end

		if cursor_col >= (s - 1) and cursor_col < e then
			local content = string.sub(line, s + 1, e - 1)

			-- Skip if this is a footnote
			if content:sub(1, 1) == "^" then
				offset = e
				goto continue
			end

			return {
				type = "link",
				display_text = content,
				definition = content,
				full_match_text = string.sub(line, s, e),
			}
		end

		::continue::
		offset = e
	end

	-- 4. Check for URLs
	offset = 0
	while offset < #line do
		local s, e = string.find(line, "https?://[^%s%]%)};]+", offset + 1)
		if not s then
			break
		end
		if cursor_col >= (s - 1) and cursor_col < e then
			local url = string.sub(line, s, e)
			return {
				type = "website",
				url = url,
				display_text = url,
				full_match_text = url,
			}
		end
		offset = e
	end

	-- 5. Check for file paths
	offset = 0
	while offset < #line do
		local s, e, path = string.find(line, "([~%.]/[^%s]+)", offset + 1)
		if not s then
			s, e, path = string.find(line, "(/[^%s]+)", offset + 1)
		end
		if not s then
			break
		end
		if cursor_col >= (s - 1) and cursor_col < e then
			return {
				type = "filepath",
				path = path,
				display_text = path,
				full_match_text = path,
			}
		end
		offset = e
	end

	return nil
end

-- Extract all links from a line
function M.extract_all_links(line)
	local links = {}
	local offset = 0

	while offset < #line do
		local link = M.extract_link_at(line, offset)
		if link then
			table.insert(links, link)
			-- Move past this link
			local _, end_pos = line:find(M.escape_pattern(link.full_match_text), offset + 1)
			offset = end_pos or offset + 1
		else
			offset = offset + 1
		end
	end

	return links
end

-- Parse link component
function M.parse_link_component(component)
	if not component or component == "" then
		return nil
	end

	local first_char = component:sub(1, 1)

	if first_char == "@" then
		return { type = "tag", text = component:sub(2), original = component }
	elseif first_char == "#" then
		local text = component:sub(2)
		if text:sub(1, 1) == " " then
			text = text:sub(2)
		end
		return { type = "heading", text = text, original = component }
	elseif first_char == ":" then
		return { type = "label", text = component:sub(2), original = component }
	elseif first_char == "-" then
		return { type = "listitem", text = component:sub(2), original = component }
	elseif first_char == "*" then
		return { type = "highlight", text = component:sub(2), original = component }
	elseif first_char == "%" then
		return { type = "query", text = component:sub(2), original = component }
	else
		return { type = "article", text = component, original = component }
	end
end

-- Parse link definition
function M.parse_link_definition(definition)
	if not definition or definition == "" then
		return nil
	end

	definition = M.trim(definition)

	local result = {
		scope = "global",
		components = {},
	}

	-- Check for local scope
	if definition:sub(1, 1) == "/" then
		result.scope = "local"
		definition = definition:sub(2)
	end

	-- Split by / to get components
	for component in definition:gmatch("[^/]+") do
		component = M.trim(component)
		if component ~= "" then
			local comp_info = M.parse_link_component(component)
			if comp_info then
				table.insert(result.components, comp_info)
			end
		end
	end

	-- If no components but we have a definition, it's an article link
	if #result.components == 0 and definition ~= "" then
		table.insert(result.components, {
			type = "article",
			text = definition,
			original = definition,
		})
	end

	return result
end

-- Check if project is linked in text
function M.is_project_linked(text, project_name)
	local links = M.extract_all_links(text)

	for _, link_info in ipairs(links) do
		if link_info.type == "link" then
			local parsed = M.parse_link_definition(link_info.definition)
			if parsed and #parsed.components > 0 then
				for _, component in ipairs(parsed.components) do
					if component.type == "article" and component.text:lower() == project_name:lower() then
						return true
					end
				end
			end
		end
	end

	return false
end

-- Extract area links from text
function M.extract_area_links(text)
	local area_paths = {}
	local links = M.extract_all_links(text)

	for _, link_info in ipairs(links) do
		if link_info.type == "link" then
			local parsed = M.parse_link_definition(link_info.definition)
			if parsed and #parsed.components > 0 then
				local first = parsed.components[1]
				if first.type == "article" and (first.text == "A" or first.text == "Areas") then
					local path_parts = {}
					for i = 2, #parsed.components do
						local comp = parsed.components[i]
						if comp.type == "heading" or comp.type == "label" then
							table.insert(path_parts, comp.text)
						end
					end

					if #path_parts > 0 then
						local path = table.concat(path_parts, "/")
						table.insert(area_paths, path)
					end
				end
			end
		end
	end

	return area_paths
end

-- =============================================================================
-- Article/File Parsing
-- =============================================================================

function M.extract_article_name(line)
	local name = line:match("^@@(.+)")
	if name then
		return M.trim(name)
	end
	return nil
end

function M.extract_tags_from_lines(lines, max_lines)
	max_lines = max_lines or 15
	local tags = {}
	local seen = {}

	for i = 1, math.min(max_lines, #lines) do
		local line = lines[i]
		-- Check for tags (@tag) and aliases (@@alias)
		if line:match("^@+%w+") then
			if not seen[line] then
				table.insert(tags, line)
				seen[line] = true
			end
		end
	end

	return tags
end

return M
