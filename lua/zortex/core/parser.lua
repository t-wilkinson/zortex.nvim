-- core/parser.lua - Unified parsing logic for Zortex
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
	if line:match(constants.PATTERNS.BOLD_HEADING) then
		return constants.SECTION_TYPE.BOLD_HEADING
	end
	if line:match(constants.PATTERNS.LABEL) then
		return constants.SECTION_TYPE.LABEL
	end
	return constants.SECTION_TYPE.TEXT
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
	return line:match("^%*%*[^%*]+%*%*:?$") ~= nil
end

-- =============================================================================
-- Task Parsing
-- =============================================================================

function M.is_task_line(line)
	return line:match(constants.PATTERNS.TASK_PREFIX) ~= nil
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
