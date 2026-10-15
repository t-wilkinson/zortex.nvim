-- utils/attributes.lua - Simplified attributes module using consolidated parser
local M = {}

local datetime = require("zortex.utils.datetime")

-- =============================================================================
-- Attribute Parsing
-- =============================================================================

local function trim(str)
	return str:match("^%s*(.-)%s*$") or ""
end

-- Type parsers for attributes
local attribute_parsers = {
	string = function(v)
		return trim(v)
	end,
	number = function(v)
		return tonumber(v)
	end,
	boolean = function()
		return true
	end,

	list = function(v)
		local items = {}
		for item in v:gmatch("[^,]+") do
			table.insert(items, trim(item))
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

	area = function(values)
		local links = {}

		-- area links are comma-separated
		for v in values:gmatch("%s*([^,]+)%s*") do
			if not v or v == "" then
				goto continue
			end

			-- Split by "/" to get components
			local components = {}
			for component in v:gmatch("[^/]+") do
				table.insert(components, trim(component))
			end

			-- If more than 2 components, return the raw value without modification
			if #components > 2 then
				local definition = "Areas/" .. v
				table.insert(links, {
					raw = v,
					definition = definition,
					link = "[" .. definition .. "]",
					-- components = components,
				})
			else
				-- Process components to ensure proper prefixes
				local processed = {}

				for i, component in ipairs(components) do
					local processed_component = component

					if i == 1 then
						-- First component should be a heading
						if not component:match("^#") then
							processed_component = "#" .. component
						end
					elseif i == 2 then
						-- Second component should be a label
						if not component:match("^:") then
							processed_component = ":" .. component
						end
					end

					table.insert(processed, processed_component)
				end

				-- Build the link
				local link_path = table.concat(processed, "/")
				local definition = "Areas/" .. link_path
				local link = "[" .. definition .. "]"

				table.insert(links, {
					raw = v, -- Original value
					definition = definition,
					link = link, -- Full link format
					path = link_path,
					-- components = components, -- Original components
					-- processed = processed, -- Processed components with prefixes
					-- heading = processed[1], -- The heading component (with #)
					-- label = processed[2], -- The label component (with :) if exists
				})
			end
			::continue::
		end

		return links
	end,

	notify = function(v)
		v = trim(v)
		if v == "no" then
			return "no"
		end

		local times = {}
		for item in v:gmatch("[^,]+") do
			item = trim(item)
			local duration = datetime.parse_durations(item)
			if duration then
				table.insert(times, duration)
			else
				table.insert(times, item)
			end
		end

		-- The attribute is empty, so we enable the notification time
		if #times == 0 then
			return true
		end

		return times
	end,

	-- ===========================================================================
	-- Datetime
	-- ===========================================================================
	duration = datetime.parse_durations,

	date = datetime.parse_date,

	time = datetime.parse_time,

	datetime = function(v, _, context)
		return datetime.parse_datetime(v, context.default_date_str)
	end,

	range = function(v, _, context)
		-- Parse range specification: "14:00, 16:00" or "14:00, +2h"
		local parts = {}
		for part in v:gmatch("([^,]+)") do
			table.insert(parts, trim(part))
		end

		if #parts ~= 2 then
			return nil
		end

		local start_str = parts[1]
		local end_str = parts[2]

		-- Parse start time/date
		local start_dt = datetime.parse_datetime(start_str, context.default_date_str)
		if not start_dt then
			return nil
		end

		-- Check if end is a duration (+2h format)
		local dur = end_str:match("^%+(%d+%a)")

		if dur then
			dur = datetime.parse_durations(dur)
			if dur then
				return {
					start_dt = start_dt,
					duration = dur,
					type = "duration",
				}
			end
		end

		-- Otherwise parse as datetime
		local end_dt = datetime.parse_datetime(end_str, context.default_date_str)
		if end_dt then
			return {
				start_dt = start_dt,
				["end"] = end_dt,
				type = "explicit",
			}
		end

		return nil
	end,

	after = function(v, _, context)
		return datetime.parse_datetime(v, context.default_date_str)
	end,

	before = function(v, _, context)
		return datetime.parse_datetime(v, context.default_date_str)
	end,

	deadline = function(v, _, context)
		return datetime.parse_datetime(v, context.default_date_str)
	end,

	buffer = function(v)
		return datetime.parse_durations(v)
	end,
}

M.attribute_parsers = attribute_parsers

local size_values = {
	xs = true,
	sm = true,
	md = true,
	lg = true,
	xl = true,
	["2xl"] = true,
	["3xl"] = true,
	["4xl"] = true,
	["5xl"] = true,
	epic = true,
	legendary = true,
	mythic = true,
	ultimate = true,
}

-- Parse @key(value) attributes from text
-- @param parser_context table Context of the text being parsed to optionally pass to functions like parse_datetime() default_date_str.
--  The attribute parsers know how to take the parser_context and pass relevant information to functions as necessary.
function M.parse_attributes(text, schema, parser_context)
	local attrs = {}
	local contexts = {}

	-- Attributes start a word (like syntax.strip_attributes): "[@P/...]" in a
	-- link and "me@example.com" are text, not attributes.
	text = " " .. text

	-- Pattern for @key(value)
	text = text:gsub("(%s)@(%w+)%(([^)]*)%)", function(space, key, value)
		if type(schema[key]) == "string" then
			key = schema[key]
		end

		key = key:lower()

		if schema and schema[key] then
			local parser = attribute_parsers[schema[key].type]

			if parser then
				local parsed = parser(value, schema[key].values, parser_context)
				if parsed ~= nil then
					attrs[key] = parsed
				end
			end
		end
		return space
	end)

	-- Pattern for bare @key
	text = text:gsub("(%s)@(%w+)", function(space, key)
		key = key:lower()

		-- Check duration shortcuts
		local dur_num, dur_unit = key:match("^(%d+%.?%d*)([hdmw])$")
		if dur_num and dur_unit then
			attrs.dur = attribute_parsers.duration(key)
			return space
		end

		-- Check priority shortcuts
		local pri = key:match("^p([123])$")
		if pri then
			attrs.p = pri
			return space
		end

		local imp = key:match("^i([123])$")
		if imp then
			attrs.i = imp
			return space
		end

		-- Check size shortcuts (e.g. @sm, @xl, @ultimate)
		if schema and schema.size and schema.size.values then
			for _, allowed in ipairs(schema.size.values) do
				if key == allowed then
					attrs.size = key
					return space
				end
			end
		elseif not schema and size_values[key] then
			attrs.size = key
			return space
		end

		-- Boolean flags
		if schema and schema[key] and schema[key].type == "boolean" then
			attrs[key] = true
		else
			-- Otherwise it's a context (@home, @work, @phone)
			table.insert(contexts, key)
		end

		return space
	end)

	if #contexts > 0 then
		attrs.context = contexts
	end

	return attrs, trim(text:gsub("%s+", " "))
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
	if type(line) ~= "string" or not key then
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

	-- Remove the attribute and the whitespace before it; leave the rest of the
	-- line (indentation, spacing) untouched.
	local pattern = "@" .. vim.pesc(key) .. "%([^)]*%)"
	line = line:gsub("%s+" .. pattern, "")
	line = line:gsub(pattern, "")
	return line
end

-- Add attribute if not present
function M.add_attribute(line, key, value)
	if M.extract_attribute(line, key) then
		return line -- Already has attribute
	end
	return M.update_attribute(line, key, value)
end

-- =============================================================================
-- Attribute Schemas
-- =============================================================================

M.schemas = {
	-- Task attributes
	task = {
		id = { type = "string" },
		size = { type = "enum", values = { "xs", "sm", "md", "lg", "xl", "2xl", "3xl", "4xl", "5xl" } },
		p = { type = "enum", values = { "1", "2", "3" } },
		i = { type = "enum", values = { "1", "2", "3" } },
		due = { type = "date" },
		at = { type = "string" },
		dur = { type = "duration" },
		est = { type = "duration" },
		spent = { type = "duration" }, -- time tracked on it (the web app's clocks), minutes
		done = { type = "date" },
		progress = { type = "progress" },
		["repeat"] = { type = "string" },
		notify = { type = "notify" },
		n = "notify",
		depends = { type = "string" }, -- Specifies task dependence
		area = { type = "area" }, -- area-link
		a = "area",
	},

	-- Project attributes
	project = {
		p = { type = "enum", values = { "1", "2", "3" } },
		i = { type = "enum", values = { "1", "2", "3" } },
		progress = { type = "progress" },
		due = { type = "date" },
		done = { type = "date" },
		xp = { type = "number" },
		dur = { type = "duration" },
		est = { type = "duration" },
		size = {
			type = "enum",
			values = {
				"xs",
				"sm",
				"md",
				"lg",
				"xl",
				"epic",
				"legendary",
				"mythic",
				"ultimate",
			},
		},
		area = { type = "area" },
		a = "area",
	},

	-- Event attributes
	event = {
		at = { type = "string" },
		from = { type = "datetime" },
		to = { type = "datetime" },
		notify = { type = "notify" },
		n = "notify",
		["repeat"] = { type = "string" },
		area = { type = "area" },
		a = "area",
	},

	-- Calendar entry attributes
	calendar_entry = {
		id = { type = "string" },
		p = { type = "enum", values = { "1", "2", "3" } },
		i = { type = "enum", values = { "1", "2", "3" } },
		due = { type = "datetime" },
		at = { type = "datetime" },
		dur = { type = "duration" },
		est = { type = "duration" },
		spent = { type = "duration" },
		from = { type = "datetime" },
		to = { type = "datetime" },
		["repeat"] = { type = "string" },
		notify = { type = "notify" },
		n = "notify",
		area = { type = "area" },
		a = "area",
	},
}

-- =============================================================================
-- Parse schemas
-- =============================================================================

-- `context` parameter passes additional information for parsing attributes.
-- Currently only used for passing a default date to the 'datetime' attribute

-- Parse project attributes
function M.parse_project_attributes(line, context)
	return M.parse_attributes(line, M.schemas.project, context)
end

-- Parse calendar entry attributes
function M.parse_calendar_attributes(line, context)
	return M.parse_attributes(line, M.schemas.calendar_entry, context)
end

-- =============================================================================
-- Specific Attribute Helpers
-- =============================================================================

-- Progress attribute helpers
function M.update_progress_attribute(line, completed, total)
	if total > 0 then
		return M.update_attribute(line, "progress", string.format("%d/%d", completed, total))
	else
		return M.remove_attribute(line, "progress")
	end
end

-- =============================================================================
-- Duration Helpers
-- =============================================================================

-- Format minutes to duration string
function M.format_duration(minutes)
	if not minutes or minutes <= 0 then
		return nil
	end

	local hours = math.floor(minutes / 60)
	local mins = minutes % 60

	if hours > 0 and mins > 0 then
		return string.format("%dh%dm", hours, mins)
	elseif hours > 0 then
		return string.format("%dh", hours)
	else
		return string.format("%dm", mins)
	end
end

return M
