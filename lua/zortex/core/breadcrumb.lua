-- core/breadcrumb.lua - Unified breadcrumb/link representation for Zortex
local M = {}

local constants = require("zortex.constants")

-- =============================================================================
-- Breadcrumb Types
-- =============================================================================

M.LinkType = {
	ARTICLE = "article", -- Just article name
	PARTIAL = "partial", -- Partial path (article + some sections)
	FULL = "full", -- Complete path to specific section
	LINE = "line", -- Specific line reference
}

-- =============================================================================
-- Breadcrumb Segment
-- =============================================================================

local Segment = {}
Segment.__index = Segment

function Segment:new(data)
	return setmetatable({
		type = data.type, -- constants.SECTION_TYPE.*
		text = data.text, -- Display text
		level = data.level, -- For headings
		line_num = data.line_num, -- Start line
		end_line = data.end_line, -- End line (optional)
		file = data.file, -- File path (optional)
	}, self)
end

-- Convert segment to link component
function Segment:to_link_component()
	if self.type == constants.SECTION_TYPE.ARTICLE then
		return self.text
	elseif self.type == constants.SECTION_TYPE.HEADING then
		return "#" .. self.text
	elseif self.type == constants.SECTION_TYPE.BOLD_HEADING then
		return "*" .. self.text
	elseif self.type == constants.SECTION_TYPE.LABEL then
		return ":" .. self.text
	elseif self.type == constants.SECTION_TYPE.TAG then
		return "@" .. self.text
	else
		return self.text
	end
end

-- =============================================================================
-- Breadcrumb Class
-- =============================================================================

local Breadcrumb = {}
Breadcrumb.__index = Breadcrumb
M.Breadcrumb = Breadcrumb

function Breadcrumb:new(data)
	return setmetatable({
		segments = data.segments or {}, -- Array of Segment objects
		link_type = data.link_type, -- LinkType
		file = data.file, -- Source file
		target_line = data.target_line, -- Specific line for LINE type
		scope = data.scope or "global", -- "global" or "local"
	}, self)
end

-- Create breadcrumb from section path (as returned by parser.build_section_path)
function Breadcrumb.from_section_path(section_path, file)
	local segments = {}

	for _, section in ipairs(section_path) do
		table.insert(
			segments,
			Segment:new({
				type = section.type,
				text = section.text or section.display,
				level = section.level,
				line_num = section.lnum or section.start_line,
				end_line = section.end_line,
			})
		)
	end

	-- Determine link type
	local link_type = M.LinkType.PARTIAL
	if #segments == 0 then
		link_type = M.LinkType.ARTICLE
	elseif section_path.is_complete then
		link_type = M.LinkType.FULL
	end

	return Breadcrumb:new({
		segments = segments,
		link_type = link_type,
		file = file,
	})
end

-- Create breadcrumb from parsed link
function Breadcrumb.from_link(link_def, file)
	if not link_def or not link_def.components then
		return nil
	end

	local segments = {}
	for _, comp in ipairs(link_def.components) do
		local segment_type = constants.SECTION_TYPE.TEXT

		-- Map component types to section types
		if comp.type == "article" then
			segment_type = constants.SECTION_TYPE.ARTICLE
		elseif comp.type == "heading" then
			segment_type = constants.SECTION_TYPE.HEADING
		elseif comp.type == "label" then
			segment_type = constants.SECTION_TYPE.LABEL
		elseif comp.type == "tag" then
			segment_type = constants.SECTION_TYPE.TAG
		elseif comp.type == "highlight" then
			-- Could be bold heading
			segment_type = constants.SECTION_TYPE.BOLD_HEADING
		end

		table.insert(
			segments,
			Segment:new({
				type = segment_type,
				text = comp.text,
			})
		)
	end

	return Breadcrumb:new({
		segments = segments,
		link_type = #segments == 1 and M.LinkType.ARTICLE or M.LinkType.PARTIAL,
		file = file,
		scope = link_def.scope,
	})
end

-- Create breadcrumb for specific line
function Breadcrumb.from_line(file, line_num, section_path)
	local bc = section_path and Breadcrumb.from_section_path(section_path, file) or Breadcrumb:new({ file = file })
	bc.link_type = M.LinkType.LINE
	bc.target_line = line_num
	return bc
end

-- Convert breadcrumb to link text
function Breadcrumb:to_link()
	local parts = {}

	-- Add scope prefix if local
	local prefix = self.scope == "local" and "/" or ""

	-- Build component string
	for _, segment in ipairs(self.segments) do
		table.insert(parts, segment:to_link_component())
	end

	return prefix .. table.concat(parts, "/")
end

-- Convert breadcrumb to display string
function Breadcrumb:to_display(separator)
	separator = separator or " › "
	local parts = {}

	for _, segment in ipairs(self.segments) do
		table.insert(parts, segment.text)
	end

	return table.concat(parts, separator)
end

-- Get article name (first segment if it's an article)
function Breadcrumb:get_article()
	if #self.segments > 0 and self.segments[1].type == constants.SECTION_TYPE.ARTICLE then
		return self.segments[1].text
	end
	return nil
end

-- Get target section (last segment)
function Breadcrumb:get_target()
	if #self.segments > 0 then
		return self.segments[#self.segments]
	end
	return nil
end

-- Check if breadcrumb matches another (for deduplication)
function Breadcrumb:matches(other)
	if not other or self.file ~= other.file then
		return false
	end

	if self.link_type == M.LinkType.LINE or other.link_type == M.LinkType.LINE then
		return self.target_line == other.target_line
	end

	if #self.segments ~= #other.segments then
		return false
	end

	for i, segment in ipairs(self.segments) do
		local other_seg = other.segments[i]
		if segment.type ~= other_seg.type or segment.text ~= other_seg.text then
			return false
		end
	end

	return true
end

-- Clone breadcrumb
function Breadcrumb:clone()
	local segments = {}
	for _, seg in ipairs(self.segments) do
		table.insert(segments, Segment:new(seg))
	end

	return Breadcrumb:new({
		segments = segments,
		link_type = self.link_type,
		file = self.file,
		target_line = self.target_line,
		scope = self.scope,
	})
end

-- Extend breadcrumb with additional segment
function Breadcrumb:extend(segment_data)
	local new_bc = self:clone()
	table.insert(new_bc.segments, Segment:new(segment_data))

	-- Update link type
	if new_bc.link_type == M.LinkType.ARTICLE then
		new_bc.link_type = M.LinkType.PARTIAL
	end

	return new_bc
end

-- Truncate breadcrumb to N segments
function Breadcrumb:truncate(n)
	if n >= #self.segments then
		return self:clone()
	end

	local new_bc = self:clone()
	while #new_bc.segments > n do
		table.remove(new_bc.segments)
	end

	-- Update link type
	if #new_bc.segments == 1 and new_bc.segments[1].type == constants.SECTION_TYPE.ARTICLE then
		new_bc.link_type = M.LinkType.ARTICLE
	else
		new_bc.link_type = M.LinkType.PARTIAL
	end

	return new_bc
end

-- =============================================================================
-- Breadcrumb Resolution
-- =============================================================================

-- Resolve a partial breadcrumb to full breadcrumb using document
function M.resolve_breadcrumb(breadcrumb, doc)
	-- Implementation would search through doc to find matching path
	-- and fill in missing line numbers, end lines, etc.
	-- This is a placeholder for the actual implementation
	return breadcrumb
end

-- =============================================================================
-- Breadcrumb Cache (for recently used breadcrumbs)
-- =============================================================================

local BreadcrumbCache = {
	cache = {}, -- file -> array of breadcrumbs
	max_per_file = 20,
}

function BreadcrumbCache:add(breadcrumb)
	if not breadcrumb.file then
		return
	end

	self.cache[breadcrumb.file] = self.cache[breadcrumb.file] or {}
	local file_cache = self.cache[breadcrumb.file]

	-- Check for duplicates
	for i, cached in ipairs(file_cache) do
		if cached:matches(breadcrumb) then
			-- Move to front
			table.remove(file_cache, i)
			table.insert(file_cache, 1, breadcrumb)
			return
		end
	end

	-- Add new
	table.insert(file_cache, 1, breadcrumb)

	-- Limit size
	while #file_cache > self.max_per_file do
		table.remove(file_cache)
	end
end

function BreadcrumbCache:get_recent(file, limit)
	local file_cache = self.cache[file] or {}
	limit = limit or 10

	local results = {}
	for i = 1, math.min(limit, #file_cache) do
		table.insert(results, file_cache[i])
	end

	return results
end

M.cache = BreadcrumbCache

return M
