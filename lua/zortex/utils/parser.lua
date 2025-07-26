-- utils/parser.lua - Consolidated parsing logic for Zortex
local M = {}

local constants = require("zortex.constants")
local datetime = require("zortex.utils.datetime")

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
-- Code Block Detection
-- =============================================================================

local CodeBlockTracker = {}
CodeBlockTracker.__index = CodeBlockTracker

function CodeBlockTracker:new()
	return setmetatable({
		in_code_block = false,
		fence_pattern = nil,
	}, self)
end

function CodeBlockTracker:update(line)
	-- Check for code fence (``` or ~~~)
	local fence = line:match("^(%`%`%`+)") or line:match("^(~~~+)")

	if fence then
		if self.in_code_block and fence == self.fence_pattern then
			-- End of code block
			self.in_code_block = false
			self.fence_pattern = nil
		elseif not self.in_code_block then
			-- Start of code block
			self.in_code_block = true
			self.fence_pattern = fence
		end
	end

	return self.in_code_block
end

function CodeBlockTracker:is_in_code_block()
	return self.in_code_block
end

-- Export for use by other modules
M.CodeBlockTracker = CodeBlockTracker

-- =============================================================================
-- Section Detection & Parsing
-- =============================================================================

function M.detect_section_type(line, in_code_block)
	-- Skip section detection if we're in a code block
	if in_code_block then
		return constants.SECTION_TYPE.TEXT
	end

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

function M.get_section_priority(line, in_code_block)
	local section_type = M.detect_section_type(line, in_code_block)
	local heading_level = nil

	if section_type == constants.SECTION_TYPE.HEADING then
		heading_level = M.get_heading_level(line)
	end

	return constants.SECTION_HIERARCHY.get_priority(section_type, heading_level)
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

function M.is_bold_heading(line)
	return line:match(constants.PATTERNS.BOLD_HEADING) ~= nil or line:match(constants.PATTERNS.BOLD_HEADING_ALT) ~= nil
end

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
-- Task Parsing
-- =============================================================================

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
-- Attribute Parsing (consolidated from attributes.lua)
-- =============================================================================

-- Type parsers for attributes
local attribute_parsers = {
	string = function(v)
		return M.trim(v)
	end,
	number = function(v)
		return tonumber(v)
	end,
	boolean = function()
		return true
	end,

	duration = datetime.parse_durations,

	date = datetime.parse_date,

	time = datetime.parse_time,

	datetime = datetime.parse_datetime,

	progress = function(v)
		local completed, total = v:match("(%d+)/(%d+)")
		if completed and total then
			return { completed = tonumber(completed), total = tonumber(total) }
		end
		return nil
	end,

	list = function(v)
		local items = {}
		for item in v:gmatch("[^,]+") do
			table.insert(items, M.trim(item))
		end
		return items
	end,

	enum = function(v, allowed_values)
		for _, allowed in ipairs(allowed_values) do
			if v == allowed then
				return v
			end
		end
		return nil
	end,
}

-- Parse @key(value) attributes from text
function M.parse_attributes(text, schema)
	local attrs = {}
	local contexts = {}

	-- Pattern for @key(value)
	text = text:gsub("@(%w+)%s*%(([^)]*)%)", function(key, value)
		key = key:lower()
		if schema and schema[key] then
			local parser = attribute_parsers[schema[key].type]
			if parser then
				local parsed = parser(value, schema[key].values)
				if parsed ~= nil then
					attrs[key] = parsed
				end
			end
		end
		return ""
	end)

	-- Pattern for bare @key
	text = text:gsub("@(%w+)", function(key)
		key = key:lower()

		-- Check duration shortcuts
		local dur_num, dur_unit = key:match("^(%d+%.?%d*)([hdmw])$")
		if dur_num and dur_unit then
			attrs.dur = attribute_parsers.duration(key)
			return ""
		end

		-- Check priority shortcuts
		local pri = key:match("^p([123])$")
		if pri then
			attrs.p = pri
			return ""
		end

		local imp = key:match("^i([123])$")
		if imp then
			attrs.i = imp
			return ""
		end

		-- Boolean flags
		if schema and schema[key] and schema[key].type == "boolean" then
			attrs[key] = true
		else
			-- Otherwise it's a context
			table.insert(contexts, key)
		end

		return ""
	end)

	if #contexts > 0 then
		attrs.context = contexts
	end

	return attrs, M.trim(text:gsub("%s+", " "))
end

-- Extract specific attribute
function M.extract_attribute(line, key)
	if not line or not key then
		return nil
	end
	return line:match("@" .. key .. "%(([^)]+)%)")
end

-- Update attribute value
function M.update_attribute(line, key, value)
	if not line or not key then
		return line
	end

	local pattern = "@" .. key .. "%(([^)]+)%)"
	local replacement = "@" .. key .. "(" .. tostring(value) .. ")"

	if line:match(pattern) then
		return line:gsub(pattern, replacement, 1)
	else
		-- Add attribute
		local space = line:match("%s$") and "" or " "
		return line .. space .. replacement
	end
end

-- Remove attribute
function M.remove_attribute(line, key)
	if not line or not key then
		return line
	end

	return line:gsub("@" .. key .. "%(([^)]+)%)", ""):gsub("%s+", " "):gsub("%s$", "")
end

-- =============================================================================
-- Link Parsing
-- =============================================================================

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

-- =============================================================================
-- Other Parsing Functions
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
-- Sections
-- =============================================================================

--  Build the section "breadcrumb" that leads to a given buffer line
---Return an ordered list of section‑objects that enclose `target_lnum`.
---Each element contains everything the rest of the code already expects:
---• `lnum`  – where the section starts
---• `type`  – one of constants.SECTION_TYPE.*
---• `priority`– numeric hierarchy value (lower ⇒ higher level)
---• `level`  – heading level (only for `HEADING`)
---• `text`    – raw text that represents the section (article title, heading,
---               bold heading, or label)
---• `display` – text to show in breadcrumbs / Telescope lists
---@param lines        string[]  -- full buffer ‑ 1‑indexed
---@param target_lnum  integer   -- line the user/caller is interested in
---@return table[]               -- top‑down path  (article → … → innermost)
function M.build_section_path(lines, target_lnum)
	if not lines or not target_lnum or target_lnum < 1 then
		return {}
	end

	local path = {} ---@type table[]   -- final result (ordered)
	local stack = {} ---@type table[]   -- working stack while we scan
	local insert = table.insert
	local remove = table.remove

	-- Track code blocks
	local code_tracker = CodeBlockTracker:new()

	for lnum = 1, math.min(target_lnum, #lines) do
		local line = lines[lnum]
		local in_code_block = code_tracker:update(line)
		local section_type = M.detect_section_type(line, in_code_block)

		-- Skip plain text / tag‑only lines
		if section_type ~= constants.SECTION_TYPE.TEXT and section_type ~= constants.SECTION_TYPE.TAG then
			local heading_level = nil
			if section_type == constants.SECTION_TYPE.HEADING then
				heading_level = M.get_heading_level(line)
			end

			local priority = constants.SECTION_HIERARCHY.get_priority(section_type, heading_level)

			-- Maintain a proper hierarchy: pop anything that is at the same
			-- or deeper level than the current header we just met
			while #stack > 0 and stack[#stack].priority >= priority do
				remove(stack)
			end

			-- Build a section object recognised by the rest of the codebase
			local section = {
				lnum = lnum,
				type = section_type,
				priority = priority,
				level = heading_level,
				text = nil, -- filled in below
			}

			if section_type == constants.SECTION_TYPE.ARTICLE then
				section.text = M.extract_article_name(line) or "Article"
			elseif section_type == constants.SECTION_TYPE.HEADING then
				local h = M.parse_heading(line)
				section.text = h and h.text or M.trim(line:gsub("^#+%s*", ""))
				section.level = h and h.level or heading_level
			elseif section_type == constants.SECTION_TYPE.BOLD_HEADING then
				local bh = M.parse_bold_heading(line)
				section.text = bh and bh.text or M.trim(line:gsub("%*+", ""))
			elseif section_type == constants.SECTION_TYPE.LABEL then
				local lbl = M.parse_label(line)
				section.text = lbl and lbl.text or line:gsub(":$", "")
			end

			-- Fallback so that `format_breadcrumb()` always has something to show
			section.display = section.text or ("<unknown@" .. lnum .. ">")

			insert(stack, section)
		end
	end

	-- The stack already holds the correct order (outer → inner)
	for i, s in ipairs(stack) do
		path[i] = s
	end
	return path
end

--- Find the start of a section by searching backwards from a line.
--- Searches upwards from `start_lnum` to find the first line that defines a
--- section with a priority that is less than or equal to (i.e., higher than
--- or the same level as) the given `priority`.
function M.find_section_start(lines, start_lnum, section_type, heading_level)
	local priority = constants.SECTION_HIERARCHY.get_priority(section_type, heading_level)
	if not lines or not start_lnum or not priority then
		return nil
	end

	-- Track code blocks backwards
	local code_tracker = CodeBlockTracker:new()
	-- First pass: determine code block state at start_lnum
	for lnum = 1, start_lnum do
		code_tracker:update(lines[lnum])
	end

	for lnum = start_lnum, 1, -1 do
		local line = lines[lnum]
		if line then
			-- We need to track backwards for code blocks
			-- This is a simplification - in practice you might need a more sophisticated approach
			local in_code_block = lnum < start_lnum and code_tracker:is_in_code_block() or false

			local line_priority = M.get_section_priority(line, in_code_block)

			-- `get_section_priority` returns 999 for non-section lines,
			-- so this check correctly ignores them unless a very high
			-- priority is passed in.
			if line_priority <= priority then
				return lnum
			end
		end
	end

	return nil -- No containing section found
end

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

	-- Track code blocks
	local code_tracker = CodeBlockTracker:new()
	-- First pass: determine code block state at start_lnum
	for lnum = 1, start_lnum do
		code_tracker:update(lines[lnum])
	end

	-- For other sections, find the next section of equal or higher priority
	for i = start_lnum + 1, num_lines do
		local line = lines[i]
		local in_code_block = code_tracker:update(line)
		local line_section_type = M.detect_section_type(line, in_code_block)

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

return M
