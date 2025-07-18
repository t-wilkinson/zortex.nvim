-- core/attributes.lua
local M = {}

local clone = require("zortex.core.utils").clone
local datetime = require("zortex.core.datetime")
local parser = require("zortex.core.parser")
local constants = require("zortex.constants")

-- =============================================================================
-- Type Parsers
-- =============================================================================

local type_parsers = {
	-- String: just trim
	string = function(v)
		return parser.trim(v)
	end,

	-- Number: convert to number
	number = function(v)
		return tonumber(v)
	end,

	-- Date: use datetime module
	date = function(v)
		return datetime.parse_date(v)
	end,

	datetime = function(v)
		return datetime.parse_datetime(v)
	end,

	-- Duration: flexible format (2h, 30m, 1d, 1h30m, etc.) to base minutes
	duration = function(v)
		local total = 0
		-- Match patterns like "2h", "30m", "1d", "1w"
		for num, unit in v:gmatch("(%d+%.?%d*)%s*([hdmw])") do
			num = tonumber(num)
			local multipliers = {
				m = 1, -- minutes
				h = 60, -- hours to minutes
				d = 60 * 24, -- days to minutes
				w = 60 * 24 * 7, -- weeks to minutes
			}
			total = total + (num * (multipliers[unit] or 0))
		end
		return total > 0 and total or nil
	end,

	-- Boolean: presence indicates true
	boolean = function(_)
		return true
	end,

	-- List: comma-separated values
	list = function(v)
		local items = {}
		for item in v:gmatch("[^,]+") do
			table.insert(items, parser.trim(item))
		end
		return items
	end,

	-- Enum: validate against allowed values
	enum = function(v, schema)
		if schema.values then
			for _, allowed in ipairs(schema.values) do
				if v == allowed then
					return v
				end
			end
		end
		return nil
	end,
}

-- =============================================================================
-- Attribute Schemas
-- =============================================================================

local base_schema = {
	-- Core attributes
	id = { type = "string" },

	-- Priority/importance as enums
	p = { type = "enum", values = { "1", "2", "3" } },
	i = { type = "enum", values = { "1", "2", "3" } },

	-- Time attributes
	due = { type = "datetime" },
	at = { type = "string" }, -- Time like "14:30"
	dur = { type = "duration" },
	est = { type = "duration" },

	from = { type = "datetime" },
	to = { type = "datetime" },
	notify = {
		type = "custom",
		-- Process list of (2h, 1h30m, 1d, 12)
		parse = function(v)
			local durations = {}
			for duration in v:gmatch("([^,]+)") do
				table.insert(durations, type_parsers.duration(duration))
			end
			return durations
		end,
	},

	-- Status attributes
	done = { type = "date" },
	progress = {
		type = "custom",
		parse = function(v)
			local completed, total = v:match("(%d+)/(%d+)")
			if completed and total then
				return { completed = tonumber(completed), total = tonumber(total) }
			end
			return nil
		end,
	},

	-- Other
	size = { type = "enum", values = { "xs", "sm", "md", "lg", "xl" } },
	xp = { type = "number" },
	["repeat"] = { type = "string" },
}

local function build_schema(keys, overrides)
	if type(keys) == "string" then
		keys = vim.split(keys, ",", { trimempty = true })
	end

	local result = {}
	for _, k in ipairs(keys) do
		assert(base_schema[k], string.format("Unknown attribute '%s'", k))
		result[k] = clone(base_schema[k])
	end

	if overrides then
		for k, v in pairs(overrides) do
			result[k] = v
		end
	end

	return result
end

local habit_schema = build_schema("repeat,at")
local calendar_entry_schema = build_schema("id,p,i,due,at,dur,est,from,to,repeat,notify")
local task_schema = build_schema("size,id,p,i,due,at,dur,est,done,progress,repeat,notify")
local project_schema = build_schema("p,i,progress,due,done,xp,dur,est", {
	size = { type = "enum", values = { "xs", "sm", "md", "lg", "xl", "epic", "legendary", "mythic", "ultimate" } },
})
local event_schema = build_schema("at,from,to,notify,repeat")

-- =============================================================================
-- Core Parsing Logic
-- =============================================================================

-- Pattern to match @key(value) or @key
local ATTR_PATTERN = "@(%w+)%s*%(([^)]*)%)" -- @key(value)
local BARE_PATTERN = "@(%w+)" -- @key

--- Parse a single attribute value using schema
local function parse_value(value, attr_schema)
	if not attr_schema then
		return nil
	end

	local parser_type = attr_schema.type

	-- Custom parser takes precedence
	if attr_schema.parse then
		return attr_schema.parse(value)
	end

	-- Use type parser
	local parser_fn = type_parsers[parser_type]
	if parser_fn then
		return parser_fn(value, attr_schema)
	end

	-- Default to string
	return value
end

--- Parse bare attributes (e.g., @p1, @i3, @2h, @home)
local function parse_bare_attribute(key, schema)
	-- Check if it matches a duration pattern (e.g., @2h, @30m)
	local dur_num, dur_unit = key:match("^(%d+%.?%d*)([hdmw])$")
	if dur_num and dur_unit then
		return "dur", type_parsers.duration(key)
	end

	-- Check for priority/importance shortcuts (e.g., @p1, @i3)
	local pri_match = key:match("^p([123])$")
	if pri_match then
		return "p", pri_match
	end

	local imp_match = key:match("^i([123])$")
	if imp_match then
		return "i", imp_match
	end

	-- Check for size shortcuts
	if schema.size then
		for _, size in ipairs(schema.size) do
			if key == size then
				return "size", size
			end
		end
	end

	-- Check if key is in schema as a boolean flag
	if schema[key] and schema[key].type == "boolean" then
		return key, true
	end

	-- Otherwise treat as a context/tag
	return "context", key
end

--- Main attribute parser
function M.parse_attributes(text, schema)
	schema = schema or {}
	local attrs = {}
	local contexts = {} -- Collect contexts separately

	-- First pass: @key(value) attributes
	text = text:gsub(ATTR_PATTERN, function(key, value)
		key = key:lower()
		if schema[key] then
			local parsed = parse_value(value, schema[key])
			if parsed ~= nil then
				attrs[key] = parsed
			end
		end
		return "" -- Remove from text
	end)

	-- Second pass: bare @key attributes
	text = text:gsub(BARE_PATTERN, function(key)
		key = key:lower()

		-- Try to interpret the bare attribute
		local attr_name, attr_value = parse_bare_attribute(key, schema)

		if attr_name == "context" then
			table.insert(contexts, attr_value)
		elseif attr_name then
			attrs[attr_name] = attr_value
		end

		return "" -- Remove from text
	end)

	-- Add contexts if any
	if #contexts > 0 then
		attrs.context = contexts
	end

	-- Clean up text
	text = parser.trim(text:gsub("%s+", " "))

	return attrs, text
end

-- =============================================================================
-- @flag patterns
-- =============================================================================
local Flag = {}
M.Flag = Flag

function Flag.pattern_for(key)
	return "@" .. key .. "%s"
end

-- =============================================================================
-- @key(parameter) patterns
-- =============================================================================
local Param = {}
M.Param = Param

-- Build a Lua pattern that matches an @key(value) attribute *and* captures the
-- value without the surrounding parentheses.
function Param.pattern_for(key)
	return "@" .. key .. "%(([^)]+)%)" -- capture everything *inside* the parens
end

-- Return a space separator (" ") **only** when the given line does not already
-- end with whitespace.
function Param.ensure_space(line)
	return line:match("%s$") and "" or " "
end

-- Append an attribute if the key is not already present.
function Param.add_attribute(line, key, value)
	if not line or not key or not value then
		return line
	end
	if line:match(Param.pattern_for(key)) then
		return line -- already present, leave untouched
	end
	return line .. Param.ensure_space(line) .. "@" .. key .. "(" .. value .. ")"
end

-- Extract the *first* occurrence of an attribute's value.
function Param.extract_attribute(line, key)
	if not line or not key then
		return nil
	end
	return line:match(Param.pattern_for(key))
end

-- Update (or insert) an attribute so that the key always ends up with the given value.
function Param.update_attribute(line, key, new_value)
	if not line or not key or not new_value then
		return line
	end
	local attr_pat = Param.pattern_for(key)
	local replacement = "@" .. key .. "(" .. new_value .. ")"
	if line:match(attr_pat) then
		-- key present → replace *first* occurrence only
		return line:gsub(attr_pat, replacement, 1)
	else
		-- key missing → append
		return line .. Param.ensure_space(line) .. replacement
	end
end

-- Remove an attribute entirely if present.
function Param.remove_attribute(line, key)
	if not line or not key then
		return line
	end
	return line:gsub(Param.pattern_for(key), ""):gsub("%s%s+", " "):gsub("%s$", "")
end

-- =============================================================================
-- Specific patterns
-- =============================================================================

-- @progress(completed/total) attribute
function M.update_progress_attribute(line, completed, total)
	if total > 0 then
		return Param.update_attribute(line, "progress", completed .. "/" .. total)
	else
		return Param.remove_attribute(line, "progress")
	end
end

-- @done(YYYY-MM-DD) attribute
function M.update_done_attribute(line, done)
	if done then
		local date = os.date("%Y-%m-%d")
		return Param.update_attribute(line, "done", date)
	else
		return Param.remove_attribute(line, "done")
	end
end
function M.was_done(line)
	return Param.extract_attribute(line, "done") ~= nil
end

-- @id(<id>) attribute
function M.add_task_id(line, id)
	return Param.add_attribute(line, "id", id)
end
function M.extract_task_id(line)
	return Param.extract_attribute(line, "id")
end
function M.update_task_id(line, new_id)
	return Param.update_attribute(line, "id", new_id)
end

-- @xp(<xp>) attribute
function M.update_xp_attribute(line, xp)
	return Param.update_attribute(line, "xp", xp)
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Export schemas for external use
M.schemas = {
	base = base_schema,
	task = task_schema,
	project = project_schema,
	event = event_schema,
	habit = habit_schema,
	calendar_entry = calendar_entry_schema,
}

-- Parse task attributes
function M.parse_task_attributes(line)
	return M.parse_attributes(line, task_schema)
end

-- Parse project attributes
function M.parse_project_attributes(line)
	return M.parse_attributes(line, project_schema)
end

-- Parse event attributes
function M.parse_event_attributes(line)
	return M.parse_attributes(line, event_schema)
end

-- Remove all attributes
function M.strip_project_attributes(line)
	local _, text = M.parse_attributes(line, project_schema)
	return text
end
function M.strip_task_attributes(line)
	local _, text = M.parse_attributes(line, task_schema)
	return text
end
function M.strip_attributes(line)
	local attrs, text = M.parse_attributes(line, base_schema)
	return text, attrs
end

-- Parse task status (checkbox state)
function M.parse_task_status(line)
	local status_key = line:match(constants.PATTERNS.TASK_CHECKBOX)
	if status_key then
		local status_map = {
			[" "] = { symbol = "☐", name = "Incomplete", hl = "Comment" },
			["x"] = { symbol = "☑", name = "Complete", hl = "String" },
			["X"] = { symbol = "☑", name = "Complete", hl = "String" },
			["~"] = { symbol = "◐", name = "In Progress", hl = "WarningMsg" },
			["@"] = { symbol = "⏸", name = "Paused", hl = "Comment" },
		}
		local status = status_map[status_key]
		if status then
			return vim.tbl_extend("force", status, { key = status_key })
		end
	end
	return nil
end

-- Legacy compatibility: parse duration string into minutes
function M.parse_duration(dur_str)
	if not dur_str then
		return nil
	end
	local minutes = type_parsers.duration(dur_str)
	return minutes
end

return M
