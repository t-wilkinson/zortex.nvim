-- utils/parser.lua - Link grammar, plus the line-level helpers most callers need
--
-- What a line or an inline span *is* is decided by core/syntax (the one
-- Zortex parser). This module keeps the grammar of link definitions
-- ("[Article/#Heading/:Label]" -> typed components) and thin helpers over
-- core/syntax for callers that work on single lines.
local M = {}

local syntax = require("zortex.core.syntax")

-- =============================================================================
-- Strings
-- =============================================================================

M.trim = syntax.trim
M.strip_attributes = syntax.strip_attributes
M.split_query = syntax.split_query
M.parse_header = syntax.parse_header

function M.escape_pattern(text)
	if not text then
		return ""
	end
	return (text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

--- Case-insensitive membership test for header names / tags.
function M.list_has(list, value)
	if not list or not value then
		return false
	end
	value = value:lower()
	for _, v in ipairs(list) do
		if v:lower() == value then
			return true
		end
	end
	return false
end

function M.extract_article_name(line)
	local name = line:match("^@@(.+)")
	return name and M.trim(name) or nil
end

-- =============================================================================
-- Tasks (see core/item)
-- =============================================================================

--- The task on a line (an Item with a checkbox), or nil.
function M.parse_task(line, context)
	if not line then
		return nil
	end
	return require("zortex.core.item").task(line, { context = context })
end

function M.is_task_line(line)
	local it = line and syntax.item(line)
	if not (it and it.mark) then
		return false, false
	end
	return true, (it.mark == "x" or it.mark == "X")
end

-- =============================================================================
-- Links on a line
-- =============================================================================

-- Old-style link info for a syntax span (features/links, link_index, OKR)
local function link_info(line, span)
	local full = line:sub(span.s + 1, span.e)
	local info = { full_match_text = full, col = span.s + 1 }
	local t = span.type
	if t == "footnote_ref" then
		info.type, info.ref_id, info.display_text = "footnote", span.id, full
	elseif t == "markdown" then
		info.type, info.display_text, info.url = "markdown", span.text, span.url
	elseif t == "live_link" or t == "link" then
		info.type, info.display_text, info.definition = t, span.definition, span.definition
	elseif t == "tag_search" then
		info.type, info.display_text = "tag_search", span.content
		info.terms, info.query_type = span.terms, span.query_type
	elseif t == "url" then
		info.type, info.url, info.display_text = "website", span.url, span.url
	elseif t == "filepath" then
		info.type, info.path, info.display_text = "filepath", span.path, span.path
	elseif t == "attribute" and (span.key == "a" or span.key == "area") and span.value then
		-- @a(4.1) / @area(...) link to the area
		local area = require("zortex.utils.attributes").attribute_parsers.area(span.value)[1]
		if not area then
			return nil
		end
		info.type, info.display_text, info.definition = "link", area.definition, area.definition
	else
		return nil
	end
	return info
end

--- The link (any kind) under 0-based byte column `col`, or nil:
--- { type, display_text, definition?, url?, ref_id?, terms?, query_type?, path?, full_match_text, col }
function M.extract_link_at(line, col)
	local span = syntax.span_at(line, col)
	return span and link_info(line, span) or nil
end

--- Every link on a line, in order (same shape as extract_link_at).
function M.extract_all_links(line)
	local out = {}
	syntax.walk_spans(syntax.inline(line), function(span)
		local info = link_info(line, span)
		if info then
			out[#out + 1] = info
		end
	end)
	return out
end

-- =============================================================================
-- Link definitions
-- =============================================================================

-- Enhanced parse_link_component that handles attributes
function M.parse_link_component(component)
	if not component or component == "" then
		return nil
	end

	local first_char = component:sub(1, 1)

	-- Extract the base text without attributes
	local base_text = component
	local attributes = {}

	-- Check if component has attributes (contains @key(...))
	local attr_pattern = "@(%w+)%s*%(([^)]*)%)"
	for key, value in component:gmatch(attr_pattern) do
		attributes[key] = value
	end

	-- ---------------------------------------------------------------
	-- Infix operators: "term1 + term2" (OR), "term1 & term2" (AND)
	-- Detected before prefix checks. Spaces around the operator are
	-- required so that "c++" or "r&d" aren't mis-parsed.
	-- ---------------------------------------------------------------
	-- Infix operators apply to untyped components only, so "#R & D" stays a
	-- heading and "#4 Learning & Education" is not an AND query.
	local typed = first_char == "#" or first_char == ":" or first_char == "-" or first_char == "*"
	local query_type, tags = M.split_query(component)
	if not typed and query_type ~= "single" and #tags >= 2 then
		return {
			type = query_type .. "_query",
			tags = tags,
			text = component,
			original = component,
			attributes = attributes,
		}
	end

	-- ---------------------------------------------------------------
	-- Prefix-based parsing (original syntax, also serves as fallback)
	-- ---------------------------------------------------------------
	if first_char == "@" then
		return { type = "tag", text = component:sub(2), original = component, attributes = attributes }
	elseif first_char == "#" then
		local text = component:sub(2)
		if text:sub(1, 1) == " " then
			text = text:sub(2)
		end
		-- Remove attributes from the heading text
		text = text:gsub(attr_pattern, ""):gsub("%s+", " "):gsub("%s*$", "")
		return { type = "heading", text = text, original = component, attributes = attributes }
	elseif first_char == ":" then
		local text = component:sub(2)
		-- Remove attributes from the label text
		text = text:gsub(attr_pattern, ""):gsub("%s+", " "):gsub("%s*$", "")
		return { type = "label", text = text, original = component, attributes = attributes }
	elseif first_char == "-" then
		return { type = "listitem", text = component:sub(2), original = component, attributes = attributes }
	elseif first_char == "*" then
		return { type = "highlight", text = component:sub(2), original = component, attributes = attributes }
	elseif first_char == "%" then
		return { type = "query", text = component:sub(2), original = component, attributes = attributes }
	elseif first_char == "+" then
		-- Legacy OR Query: +term1+term2
		local tags = {}
		local clean_text = component:gsub(attr_pattern, ""):gsub("%s+", " "):gsub("%s*$", "")
		for tag in clean_text:gmatch("%+([^%+]+)") do
			table.insert(tags, M.trim(tag))
		end
		return { type = "or_query", tags = tags, text = clean_text, original = component, attributes = attributes }
	elseif first_char == "&" then
		-- Legacy AND Query: &term1&term2
		local tags = {}
		local clean_text = component:gsub(attr_pattern, ""):gsub("%s+", " "):gsub("%s*$", "")
		for tag in clean_text:gmatch("&([^&]+)") do
			table.insert(tags, M.trim(tag))
		end
		return { type = "and_query", tags = tags, text = clean_text, original = component, attributes = attributes }
	else
		-- Article - remove attributes from the text
		local text = component:gsub(attr_pattern, ""):gsub("%s+", " "):gsub("%s*$", "")
		return { type = "article", text = text, original = component, attributes = attributes }
	end
end

--- Split a link definition into raw component strings, ignoring "/" inside
--- parentheses (attribute values). Strips outer brackets.
---@return string[] components, "global"|"local" scope
function M.split_link(definition)
	definition = M.trim(definition or "")
	if definition:sub(1, 1) == "[" and definition:sub(-1) == "]" then
		definition = definition:sub(2, -2)
	end
	local scope = "global"
	if definition:sub(1, 1) == "/" then
		scope = "local"
		definition = definition:sub(2)
	end

	local components, current, depth = {}, "", 0
	for i = 1, #definition do
		local char = definition:sub(i, i)
		if char == "(" then
			depth = depth + 1
			current = current .. char
		elseif char == ")" then
			depth = depth - 1
			current = current .. char
		elseif char == "/" and depth == 0 then
			if current ~= "" then
				table.insert(components, M.trim(current))
			end
			current = ""
		else
			current = current .. char
		end
	end
	if current ~= "" then
		table.insert(components, M.trim(current))
	end
	return components, scope
end

-- parse_link_definition: components typed by parse_link_component
function M.parse_link_definition(definition)
	if not definition or definition == "" then
		return nil
	end

	local components, scope = M.split_link(definition)
	local result = { scope = scope, components = {} }
	definition = table.concat(components, "/")

	-- Parse each component
	for _, component in ipairs(components) do
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

return M
