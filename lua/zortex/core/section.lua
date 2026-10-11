-- core/section.lua - first-class representation of document structure
--
-- A Section is one node of a document's structural tree (root → article →
-- headings → bold headings → labels). The tree is generic; domain models such
-- as projects or areas are *derived* from it with M.derive (keep the node types
-- you care about, everything else is content of the nearest kept ancestor) and
-- aggregated with Section:fold.
local M = {}

local constants = require("zortex.constants")

-- =============================================================================
-- Section class
-- =============================================================================

local Section = {}
Section.__index = Section

function Section:new(opts)
	local section = setmetatable({}, self)

	section.type = opts.type or constants.SECTION_TYPE.TEXT
	section.text = opts.text or "" -- display text, attributes stripped
	section.start_line = opts.start_line or 1
	section.end_line = opts.end_line or section.start_line
	section.level = opts.level -- structural level (see constants.SECTION_HIERARCHY)
	section.names = opts.names -- article nodes: every @@ alias, primary first

	section.parent = nil
	section.children = {}

	section._path = nil
	section._id = nil

	return section
end

-- -----------------------------------------------------------------------------
-- Identity & paths
-- -----------------------------------------------------------------------------

function Section:is_root()
	return self.type == "root"
end

-- Unique identifier: lowercased "/"-joined path of texts.
function Section:get_id()
	if not self._id then
		self._id = table.concat(self:path_texts(), "/"):gsub("%s+", "_"):lower()
	end
	return self._id
end

-- Ancestors from the root down to (excluding) this section. Cached.
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

-- Ancestors + self. Returns a fresh list the caller may mutate.
function Section:get_full_path()
	local path = {}
	for _, ancestor in ipairs(self:get_path()) do
		path[#path + 1] = ancestor
	end
	path[#path + 1] = self
	return path
end

-- Texts of the full path, root omitted: { "Projects", "1 Programming", "1.4 - zortex" }
function Section:path_texts()
	local texts = {}
	for _, s in ipairs(self:get_full_path()) do
		if not s:is_root() then
			texts[#texts + 1] = s.text
		end
	end
	return texts
end

-- Breadcrumb string, root omitted; `sep` defaults to " > ".
function Section:get_breadcrumb(sep)
	return table.concat(self:path_texts(), sep or " > ")
end

function Section:depth()
	return #self:get_path()
end

-- -----------------------------------------------------------------------------
-- Lines
-- -----------------------------------------------------------------------------

function Section:get_lines(bufnr)
	return require("zortex.utils.buffer").get_lines(bufnr, self.start_line, self.end_line)
end

-- The line number immediately preceding the first child section
function Section:get_direct_end_line()
	if self.children and #self.children > 0 then
		return self.children[1].start_line - 1
	end
	return self.end_line
end

-- Only the lines belonging directly to this section (excluding sub-sections)
function Section:get_direct_lines(bufnr)
	return require("zortex.utils.buffer").get_lines(bufnr, self.start_line, self:get_direct_end_line())
end

function Section:contains_line(line_num)
	return line_num >= self.start_line and line_num <= self.end_line
end

-- -----------------------------------------------------------------------------
-- Hierarchy
-- -----------------------------------------------------------------------------

function Section:get_priority()
	return self.level or constants.SECTION_HIERARCHY.get_priority(self.type)
end

function Section:can_contain(other_section)
	return self:get_priority() < other_section:get_priority()
end

function Section:add_child(child)
	child.parent = self
	table.insert(self.children, child)
	child._path = nil
	child._id = nil
end

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

-- Deepest descendant containing line (nil if no child contains it)
function Section:find_child_at_line(line_num)
	for _, child in ipairs(self.children) do
		if child:contains_line(line_num) then
			return child:find_child_at_line(line_num) or child
		end
	end
	return nil
end

-- -----------------------------------------------------------------------------
-- Traversal (generic; used by search, projects, areas, ...)
-- -----------------------------------------------------------------------------

-- Pre-order walk. If `fn` returns false the node's children are skipped.
function Section:walk(fn)
	if fn(self) == false then
		return
	end
	for _, child in ipairs(self.children) do
		child:walk(fn)
	end
end

-- All descendants (depth-first, excluding self)
function Section:get_descendants()
	local out = {}
	for _, child in ipairs(self.children) do
		child:walk(function(n)
			out[#out + 1] = n
		end)
	end
	return out
end

-- All nodes in the subtree (excluding a root node) matching `pred`
function Section:filter(pred)
	local out = {}
	self:walk(function(n)
		if not n:is_root() and pred(n) then
			out[#out + 1] = n
		end
	end)
	return out
end

-- First node in the subtree (pre-order, excluding a root node) matching `pred`
function Section:find(pred)
	local found
	self:walk(function(n)
		if found then
			return false
		end
		if not n:is_root() and pred(n) then
			found = n
			return false
		end
	end)
	return found
end

-- Post-order aggregation: fn(node, child_results) -> result
function Section:fold(fn)
	local child_results = {}
	for i, child in ipairs(self.children) do
		child_results[i] = child:fold(fn)
	end
	return fn(self, child_results)
end

-- Ancestors nearest-first, excluding self (and the root)
function Section:ancestors()
	local out = {}
	local current = self.parent
	while current and not current:is_root() do
		out[#out + 1] = current
		current = current.parent
	end
	return out
end

-- -----------------------------------------------------------------------------
-- Editing helpers
-- -----------------------------------------------------------------------------

-- Update section bounds (after buffer changes)
function Section:update_bounds(start_line, end_line)
	local line_diff = (end_line - start_line) - (self.end_line - self.start_line)

	self.end_line = end_line

	local function shift_sections(section, diff)
		section.start_line = section.start_line + diff
		section.end_line = section.end_line + diff
		for _, child in ipairs(section.children) do
			shift_sections(child, diff)
		end
	end

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

function Section:format_display()
	local type_symbols = {
		[constants.SECTION_TYPE.ARTICLE] = "📄",
		[constants.SECTION_TYPE.HEADING] = string.rep("#", self.level or 1),
		[constants.SECTION_TYPE.BOLD_HEADING] = "**",
		[constants.SECTION_TYPE.LABEL] = ":",
		[constants.SECTION_TYPE.TAG] = "@",
	}
	return string.format("%s %s", type_symbols[self.type] or "", self.text)
end

-- =============================================================================
-- Tree construction (single canonical builder)
-- =============================================================================

-- Build a Section tree from section descriptors (core/syntax `ast.sections`).
function M.build_tree_from_sections(sections, line_count)
	local root = Section:new({
		type = "root",
		text = "Root",
		start_line = 1,
		end_line = line_count,
	})
	root.level = -1

	local stack = { root }
	for _, sec in ipairs(sections) do
		local section = Section:new({
			type = sec.type,
			text = sec.text,
			start_line = sec.lnum,
			end_line = sec.lnum,
			level = sec.level,
			names = sec.names,
		})

		-- Close out any open sections at the same or deeper level.
		while #stack > 1 and stack[#stack].level >= sec.level do
			stack[#stack].end_line = sec.lnum - 1
			table.remove(stack)
		end

		stack[#stack]:add_child(section)
		stack[#stack + 1] = section
	end

	for i = 2, #stack do
		stack[i].end_line = line_count
	end

	return root
end

-- Build a full Section tree from buffer lines. All structural decisions come
-- from core/syntax (pass `ast` when the lines were already parsed). The root
-- is a synthetic node of type "root" (level -1).
function M.build_tree(lines, ast)
	if not lines then
		return nil
	end
	ast = ast or require("zortex.core.syntax").parse(lines)
	return M.build_tree_from_sections(ast.sections, #lines)
end

-- Derive a domain tree from a section tree.
--   keep(node)          -> boolean: which sections become domain nodes
--   make(node, parent)  -> domain object with a `children` list
-- Sections that are not kept are skipped; their kept descendants attach to the
-- nearest kept ancestor. Returns the list of top-level domain nodes.
function M.derive(root, keep, make)
	local roots = {}
	local function visit(node, parent)
		local current = parent
		if not node:is_root() and keep(node) then
			current = make(node, parent)
			if parent then
				table.insert(parent.children, current)
			else
				table.insert(roots, current)
			end
		end
		for _, child in ipairs(node.children) do
			visit(child, current)
		end
	end
	visit(root, nil)
	return roots
end

M.Section = Section

return M
