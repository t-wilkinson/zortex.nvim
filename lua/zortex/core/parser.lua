-- core/parser.lua - Consolidated parsing logic for Zortex
local M = {}

local constants = require("zortex.constants")
local config = require("zortex.config")

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
-- Attribute Parsing
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

-- Parse task attributes
function M.parse_task_attributes(line)
	local cfg = config.get("xp") or config.defaults.xp
	local size_pattern = "@(%w+)"

	-- Check for valid size
	local function is_valid_size(size)
		return cfg.task_sizes[size] ~= nil
	end

	local definitions = {
		-- Size (only valid sizes)
		{
			name = "size",
			pattern = size_pattern,
			transform = function(size)
				return is_valid_size(size) and size or nil
			end,
		},
		-- Priority
		{
			name = "priority",
			pattern = constants.PATTERNS.PRIORITY,
			transform = function(p)
				return "p" .. p
			end,
		},
		-- Importance
		{
			name = "importance",
			pattern = constants.PATTERNS.IMPORTANCE,
			transform = function(i)
				return "i" .. i
			end,
		},
		-- Duration
		{
			name = "duration",
			pattern = constants.PATTERNS.DURATION,
			transform = function(amount, unit)
				return unit == "h" and tonumber(amount) * 60 or tonumber(amount)
			end,
		},
		-- Estimation
		{
			name = "estimation",
			pattern = constants.PATTERNS.ESTIMATION,
			transform = function(amount, unit)
				return unit == "h" and tonumber(amount) * 60 or tonumber(amount)
			end,
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

	local function is_valid_size(size)
		return cfg.project_sizes[size] ~= nil
	end

	local definitions = {
		-- Size
		{
			name = "size",
			pattern = "@(%w+)",
			transform = function(size)
				return is_valid_size(size) and size or nil
			end,
		},
		-- Priority
		{
			name = "priority",
			pattern = constants.PATTERNS.PRIORITY,
			transform = function(p)
				return "p" .. p
			end,
		},
		-- Importance
		{
			name = "importance",
			pattern = constants.PATTERNS.IMPORTANCE,
			transform = function(i)
				return "i" .. i
			end,
		},
		-- Duration
		{
			name = "duration",
			pattern = constants.PATTERNS.DURATION,
			transform = function(amount, unit)
				return unit == "h" and tonumber(amount) * 60 or tonumber(amount)
			end,
		},
		-- Estimation
		{
			name = "estimation",
			pattern = constants.PATTERNS.ESTIMATION,
			transform = function(amount, unit)
				return unit == "h" and tonumber(amount) * 60 or tonumber(amount)
			end,
		},
		-- Done date
		{
			name = "done_date",
			pattern = constants.PATTERNS.DONE_DATE,
		},
		-- Progress
		{
			name = "progress",
			pattern = constants.PATTERNS.PROGRESS,
			transform = function(completed, total)
				return {
					completed = tonumber(completed),
					total = tonumber(total),
				}
			end,
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
-- Heading Parsing
-- =============================================================================

function M.get_heading_level(line)
	local level = 0
	for i = 1, #line do
		if line:sub(i, i) == "#" then
			level = level + 1
		else
			break
		end
	end

	-- Only count as heading if followed by space or end of string
	if level > 0 and (line:sub(level + 1, level + 1) == " " or level == #line) then
		return level
	end
	return 0
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

function M.is_bold_heading(line)
	return line:match(constants.PATTERNS.BOLD_HEADING) ~= nil
end

-- =============================================================================
-- Task Parsing
-- =============================================================================

function M.is_task_line(line)
	local unchecked = line:match(constants.PATTERNS.TASK_UNCHECKED)
	local checked = line:match(constants.PATTERNS.TASK_CHECKED)
	return (unchecked or checked) ~= nil, checked ~= nil
end

function M.get_task_text(line)
	return line:match(constants.PATTERNS.TASK_TEXT)
end

function M.get_task_state(line)
	if line:match(constants.PATTERNS.TASK_UNCHECKED) then
		return "todo"
	elseif line:match(constants.PATTERNS.TASK_CHECKED) then
		return "done"
	else
		return "not_task"
	end
end

-- =============================================================================
-- Date Parsing
-- =============================================================================

function M.parse_okr_date(line)
	local span, year, month, title = line:match(constants.PATTERNS.OKR_DATE)
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

function M.months_between(date1, date2)
	return (date2.year - date1.year) * 12 + (date2.month - date1.month)
end

-- =============================================================================
-- Link Parsing
-- =============================================================================

-- Extract link at position
function M.extract_link_at(line, cursor_col)
	-- 1. Check for footnote references
	local offset = 0
	while offset < #line do
		local s, e, ref_id = string.find(line, constants.PATTERNS.FOOTNOTE, offset + 1)
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
		local s, e, text, url = string.find(line, constants.PATTERNS.MARKDOWN_LINK, offset + 1)
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
		local s, e = string.find(line, constants.PATTERNS.LINK, offset + 1)
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
		local s, e = string.find(line, constants.PATTERNS.URL, offset + 1)
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
		local s, e, path = string.find(line, constants.PATTERNS.FILEPATH, offset + 1)
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

return M
