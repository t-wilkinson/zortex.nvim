-- core/item.lua - The shared item type: one list line with its attributes
--
-- Project tasks, calendar entries and key results are all list items: a
-- marker ("-", "1.", "14:00"), an optional "Key:" prefix, an optional
-- checkbox, text and attributes. core/syntax finds those parts; an Item adds
-- the typed attributes (utils/attributes schemas) and a stable shape every
-- domain module shares:
--
--   lnum, file           where the line is (when known)
--   raw_text             the full line as written
--   indent               leading whitespace width
--   marker, marker_type  "-" | "1." | "14:00" ...; "bullet" | "ordered" | "time"
--   time                 { at } or { from, to } for time-prefixed lines
--   key                  "KR1" in "- KR1: [ ] Ship", "Label" in "- Label: text"
--   mark, mark_col       checkbox character (nil without one) and its column
--   completed            mark is x/X
--   body                 text after marker, key and checkbox (attributes kept)
--   text                 body with attributes removed
--   attributes           typed attributes (schema: task unless given)
--
-- Tasks are items with a checkbox (item:is_task()).
local M = {}

local syntax = require("zortex.core.syntax")

local Item = {}
Item.__index = Item
M.Item = Item

local function attributes()
	return require("zortex.utils.attributes")
end

--- Build an item from a line. `info` is the line's syntax descriptor when the
--- caller already has it (core/document); otherwise the line is classified.
---@param line string
---@param opts { lnum?: integer, file?: string, info?: table, schema?: table|string, context?: table }?
---@return table? Item, or nil when the line is not a list item
function M.from_line(line, opts)
	opts = opts or {}
	local info = opts.info or syntax.classify(line)
	local it = info.item
	if not it then
		return nil
	end
	local body = line:sub(it.content_col + 1)
	local schema = opts.schema or "task"
	if type(schema) == "string" then
		schema = attributes().schemas[schema]
	end
	local attrs, text = attributes().parse_attributes(body, schema, opts.context)
	return setmetatable({
		lnum = opts.lnum,
		file = opts.file,
		raw_text = line,
		indent = info.indent or #line:match("^%s*"),
		marker = it.marker,
		marker_type = it.marker_type,
		time = it.time,
		key = it.key,
		mark = it.mark,
		mark_col = it.mark_col,
		completed = it.mark == "x" or it.mark == "X",
		body = body,
		text = text,
		attributes = attrs,
	}, Item)
end

--- A task item (checkbox) from a line, or nil.
function M.task(line, opts)
	local item = M.from_line(line, opts)
	if item and item.mark then
		return item
	end
	return nil
end

function Item:is_task()
	return self.mark ~= nil
end

--- Links on the line (definitions), in order.
function Item:links()
	local out = {}
	for _, span in ipairs(syntax.links(self.raw_text)) do
		out[#out + 1] = span.definition
	end
	return out
end

--- The line with the checkbox set to `mark` (nothing else changes).
function Item:with_mark(mark)
	if not self.mark_col then
		return self.raw_text
	end
	local i = self.mark_col + 2 -- 1-based position of the mark inside "[ ]"
	return self.raw_text:sub(1, i - 1) .. mark .. self.raw_text:sub(i + 1)
end

return M
