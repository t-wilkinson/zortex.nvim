-- core/section.lua - first-class representation of document structure
local M = {}

local constants = require("zortex.constants")
local parser = require("zortex.utils.parser")

-- Section class
local Section = {}
Section.__index = Section

-- Create a new section
function Section:new(opts)
	local section = setmetatable({}, self)

	-- Required fields
	section.type = opts.type or constants.SECTION_TYPE.TEXT
	section.text = opts.text or ""
	section.start_line = opts.start_line or 1
	section.end_line = opts.end_line or section.start_line

	-- Optional fields
	section.level = opts.level -- For headings (1-6)
	section.raw_text = opts.raw_text -- Original line text

	-- Tree structure
	section.parent = nil
	section.children = {}

	-- Computed properties (lazy)
	section._path = nil
	section._id = nil
	section._breadcrumb = nil

	-- Content
	section.tasks = {}
	section.attributes = {}

	return section
end

-- Get unique identifier for this section
function Section:get_id()
	if not self._id then
		-- Generate based on path and text
		local path_parts = {}
		for _, ancestor in ipairs(self:get_path()) do
			table.insert(path_parts, ancestor.text)
		end
		table.insert(path_parts, self.text)
		self._id = table.concat(path_parts, "/"):gsub("%s+", "_"):lower()
	end
	return self._id
end

-- Get section priority (for hierarchy comparisons)
function Section:get_priority()
	return constants.SECTION_HIERARCHY.get_priority(self.type, self.level)
end

-- Check if this section can contain another section type
function Section:can_contain(other_section)
	return constants.SECTION_HIERARCHY.can_contain(self.type, self.level, other_section.type, other_section.level)
end

-- Get the path from root to this section
function Section:get_path()
	if not self._path then
		self._path = {}
		local current = self.parent
		while current do
			table.insert(self._path, 1, current)
			current = current.parent
		end
	end
	return self._path
end

-- Get breadcrumb string
function Section:get_breadcrumb()
	if not self._breadcrumb then
		local parts = {}
		for _, section in ipairs(self:get_path()) do
			table.insert(parts, section.text)
		end
		table.insert(parts, self.text)
		self._breadcrumb = table.concat(parts, " > ")
	end
	return self._breadcrumb
end

-- Check if this section contains a line number
function Section:contains_line(line_num)
	return line_num >= self.start_line and line_num <= self.end_line
end

-- Add a child section
function Section:add_child(child)
	child.parent = self
	table.insert(self.children, child)

	-- Invalidate cached properties
	child._path = nil
	child._id = nil
	child._breadcrumb = nil
end

-- Remove a child section
function Section:remove_child(child)
	for i, c in ipairs(self.children) do
		if c == child then
			table.remove(self.children, i)
			child.parent = nil
			return true
		end
	end
	return false
end

-- Find child section containing line
function Section:find_child_at_line(line_num)
	for _, child in ipairs(self.children) do
		if child:contains_line(line_num) then
			-- Recursively search for deepest match
			local deeper = child:find_child_at_line(line_num)
			return deeper or child
		end
	end
	return nil
end

-- Get all descendant sections (depth-first)
function Section:get_descendants()
	local descendants = {}
	local function collect(section)
		for _, child in ipairs(section.children) do
			table.insert(descendants, child)
			collect(child)
		end
	end
	collect(self)
	return descendants
end

-- Get all tasks in this section (including descendants)
function Section:get_all_tasks()
	local tasks = vim.tbl_extend("force", {}, self.tasks)
	for _, child in ipairs(self.children) do
		vim.list_extend(tasks, child:get_all_tasks())
	end
	return tasks
end

-- Update section bounds (after buffer changes)
function Section:update_bounds(start_line, end_line)
	local line_diff = (end_line - start_line) - (self.end_line - self.start_line)

	self.end_line = end_line

	-- Update all following sections
	local function shift_sections(section, diff)
		section.start_line = section.start_line + diff
		section.end_line = section.end_line + diff
		for _, child in ipairs(section.children) do
			shift_sections(child, diff)
		end
	end

	-- Shift siblings that come after this section
	if self.parent then
		local found_self = false
		for _, sibling in ipairs(self.parent.children) do
			if found_self and sibling ~= self then
				shift_sections(sibling, line_diff)
			elseif sibling == self then
				found_self = true
			end
		end
	end
end

-- Get section statistics
function Section:get_stats()
	local stats = {
		total_tasks = 0,
		completed_tasks = 0,
		total_lines = self.end_line - self.start_line + 1,
		child_count = #self.children,
		depth = #self:get_path(),
	}

	-- Count tasks
	local all_tasks = self:get_all_tasks()
	stats.total_tasks = #all_tasks
	for _, task in ipairs(all_tasks) do
		if task.completed then
			stats.completed_tasks = stats.completed_tasks + 1
		end
	end

	return stats
end

-- Format section for display
function Section:format_display()
	local type_symbols = {
		[constants.SECTION_TYPE.ARTICLE] = "📄",
		[constants.SECTION_TYPE.HEADING] = string.rep("#", self.level or 1),
		[constants.SECTION_TYPE.BOLD_HEADING] = "**",
		[constants.SECTION_TYPE.LABEL] = ":",
		[constants.SECTION_TYPE.TAG] = "@",
	}

	local symbol = type_symbols[self.type] or ""
	return string.format("%s %s", symbol, self.text)
end

-- Section Tree Builder
local SectionTreeBuilder = {}
SectionTreeBuilder.__index = SectionTreeBuilder

function SectionTreeBuilder:new()
	return setmetatable({
		root = Section:new({
			type = constants.SECTION_TYPE.ARTICLE,
			text = "Document Root",
			start_line = 1,
			end_line = 1,
		}),
		stack = {},
		code_tracker = parser.CodeBlockTracker:new(),
	}, self)
end

-- Add a section to the tree
function SectionTreeBuilder:add_section(section)
	-- Find the appropriate parent
	while #self.stack > 0 do
		local potential_parent = self.stack[#self.stack]
		if potential_parent:can_contain(section) and section.start_line <= potential_parent.end_line then
			potential_parent:add_child(section)
			table.insert(self.stack, section)
			return
		else
			-- Pop sections that can't contain this one
			table.remove(self.stack)
		end
	end

	-- If no parent found, add to root
	self.root:add_child(section)
	table.insert(self.stack, section)
end

-- Update the end line of the current section
function SectionTreeBuilder:update_current_end(line_num)
	if #self.stack > 0 then
		self.stack[#self.stack].end_line = line_num
	end
	self.root.end_line = line_num
end

-- Get the built tree
function SectionTreeBuilder:get_tree()
	return self.root
end

-- Module functions
M.Section = Section
M.SectionTreeBuilder = SectionTreeBuilder

-- Create section from parsed line
function M.create_from_line(line, line_num, in_code_block)
	local section_type = parser.detect_section_type(line, in_code_block)

	if section_type == constants.SECTION_TYPE.TEXT or section_type == constants.SECTION_TYPE.TAG then
		return nil -- These don't create sections
	end

	local opts = {
		type = section_type,
		start_line = line_num,
		end_line = line_num,
		raw_text = line,
	}

	-- Parse based on type
	if section_type == constants.SECTION_TYPE.ARTICLE then
		opts.text = parser.extract_article_name(line) or "Article"
	elseif section_type == constants.SECTION_TYPE.HEADING then
		local heading = parser.parse_heading(line)
		if heading then
			opts.text = heading.text
			opts.level = heading.level
		end
	elseif section_type == constants.SECTION_TYPE.BOLD_HEADING then
		local bold = parser.parse_bold_heading(line)
		if bold then
			opts.text = bold.text
		end
	elseif section_type == constants.SECTION_TYPE.LABEL then
		local label = parser.parse_label(line)
		if label then
			opts.text = label.text
		end
	end

	return Section:new(opts)
end

return M
