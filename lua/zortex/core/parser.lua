-- core/parser.lua - Unified parsing logic for Zortex with normalized section handling
local M = {}

local constants = require("zortex.constants")

-- =============================================================================
-- Section Types & Detection
-- =============================================================================

function M.detect_section_type(line)
	if not line or line == "" then
		return constants.SECTION_TYPE.TEXT
	end
	if line:match(constants.PATTERNS.ARTICLE_TITLE) then
		return constants.SECTION_TYPE.ARTICLE
	end
	if line:match(constants.PATTERNS.TAG_LINE) then
		return constants.SECTION_TYPE.TAG
	end
	if line:match(constants.PATTERNS.HEADING) then
		return constants.SECTION_TYPE.HEADING
	end
	if line:match(constants.PATTERNS.BOLD_HEADING) or line:match(constants.PATTERNS.BOLD_HEADING_ALT) then
		return constants.SECTION_TYPE.BOLD_HEADING
	end
	-- Label pattern must not contain sentence periods (". ")
	local potential_label = line:match("^([^:]+):$")
	if potential_label and not potential_label:match("%.%s") then
		return constants.SECTION_TYPE.LABEL
	end
	return constants.SECTION_TYPE.TEXT
end

-- Get the effective priority of a section
function M.get_section_priority(line)
	local section_type = M.detect_section_type(line)
	local heading_level = nil

	if section_type == constants.SECTION_TYPE.HEADING then
		heading_level = M.get_heading_level(line)
	end

	return constants.SECTION_HIERARCHY.get_priority(section_type, heading_level)
end

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
-- Heading Parsing
-- =============================================================================

function M.get_heading_level(line)
	local hashes = line:match(constants.PATTERNS.HEADING_LEVEL)
	return hashes and #hashes or 0
end

function M.parse_heading(line)
	local level, text = line:match(constants.PATTERNS.HEADING)
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
	return line:match(constants.PATTERNS.BOLD_HEADING) ~= nil or line:match(constants.PATTERNS.BOLD_HEADING_ALT) ~= nil
end

-- Parse bold heading
function M.parse_bold_heading(line)
	local text = line:match(constants.PATTERNS.BOLD_HEADING)
	if not text then
		text = line:match(constants.PATTERNS.BOLD_HEADING_ALT)
	end
	if text then
		return {
			text = M.trim(text),
			raw = line,
		}
	end
	return nil
end

-- Parse label
function M.parse_label(line)
	local text = line:match("^([^:]+):$")
	if text and not text:match("%.%s") then
		return {
			text = M.trim(text),
			raw = line,
		}
	end
	return nil
end

-- =============================================================================
-- Section Boundary Detection (Unified)
-- =============================================================================

-- Find where a section ends based on hierarchy rules
function M.find_section_end(lines, start_lnum, section_type, heading_level)
	local num_lines = #lines
	local start_priority = constants.SECTION_HIERARCHY.get_priority(section_type, heading_level)

	-- Articles go to end of file
	if section_type == constants.SECTION_TYPE.ARTICLE then
		return num_lines
	end

	-- Tags are single-line
	if section_type == constants.SECTION_TYPE.TAG then
		return start_lnum
	end

	-- For other sections, find the next section of equal or higher priority
	for i = start_lnum + 1, num_lines do
		local line = lines[i]
		local line_section_type = M.detect_section_type(line)

		if line_section_type ~= constants.SECTION_TYPE.TEXT and line_section_type ~= constants.SECTION_TYPE.TAG then
			local line_heading_level = nil
			if line_section_type == constants.SECTION_TYPE.HEADING then
				line_heading_level = M.get_heading_level(line)
			end

			local line_priority = constants.SECTION_HIERARCHY.get_priority(line_section_type, line_heading_level)

			-- If we found a section of equal or higher priority, the current section ends here
			if line_priority <= start_priority then
				return i - 1
			end
		end
	end

	return num_lines
end

-- =============================================================================
-- Section Path Building (for breadcrumbs)
-- =============================================================================

-- Build complete section path from start to target line
function M.build_section_path(lines, target_lnum)
	local path = {}
	local section_stack = {} -- Stack of active sections with their priorities

	for lnum = 1, target_lnum do
		local line = lines[lnum]
		local section_type = M.detect_section_type(line)

		if section_type ~= constants.SECTION_TYPE.TEXT and section_type ~= constants.SECTION_TYPE.TAG then
			local heading_level = nil
			if section_type == constants.SECTION_TYPE.HEADING then
				heading_level = M.get_heading_level(line)
			end

			local priority = constants.SECTION_HIERARCHY.get_priority(section_type, heading_level)

			-- Pop sections from stack that this section would close
			while #section_stack > 0 and section_stack[#section_stack].priority >= priority do
				table.remove(section_stack)
			end

			-- Create section info
			local section_info = {
				type = section_type,
				priority = priority,
				lnum = lnum,
				raw = line,
			}

			-- Add type-specific info
			if section_type == constants.SECTION_TYPE.ARTICLE then
				section_info.text = M.extract_article_name(line)
				section_info.display = section_info.text
			elseif section_type == constants.SECTION_TYPE.HEADING then
				local heading = M.parse_heading(line)
				section_info.level = heading.level
				section_info.text = heading.text
				section_info.display = string.rep("#", heading.level) .. " " .. heading.text
			elseif section_type == constants.SECTION_TYPE.BOLD_HEADING then
				local bold = M.parse_bold_heading(line)
				section_info.text = bold.text
				section_info.display = "**" .. bold.text .. "**"
			elseif section_type == constants.SECTION_TYPE.LABEL then
				local label = M.parse_label(line)
				section_info.text = label.text
				section_info.display = label.text .. ":"
			end

			-- Add to stack
			table.insert(section_stack, section_info)
		end
	end

	-- Convert stack to path
	for _, section in ipairs(section_stack) do
		table.insert(path, {
			type = section.type,
			text = section.text,
			display = section.display,
			lnum = section.lnum,
			level = section.level, -- for headings
			priority = section.priority,
		})
	end

	return path
end

-- =============================================================================
-- Task Parsing
-- =============================================================================

---Return whether the line is a task and whether it is completed.
function M.is_task_line(line)
	if not line then
		return false, false
	end
	local mark = line:match(constants.PATTERNS.TASK_CHECKBOX)
	if not mark then
		return false, false
	end
	return true, (mark == "x" or mark == "X")
end

function M.parse_task_status(line)
	local status_key = line:match(constants.PATTERNS.TASK_STATUS_KEY)
	if status_key and constants.TASK_STATUS[status_key] then
		local status = vim.tbl_extend("force", {}, constants.TASK_STATUS[status_key])
		status.key = status_key
		return status
	end
	return nil
end

function M.get_task_text(line)
	return line:match(constants.PATTERNS.TASK_TEXT)
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
		offset = e or 0
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
		offset = e or 0
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
				offset = e or 0
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
		offset = e or 0
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
		offset = e or 0
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
		offset = e or 0
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
