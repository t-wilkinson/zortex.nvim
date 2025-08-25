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

	duration = datetime.parse_durations,

	date = datetime.parse_date,

	time = datetime.parse_time,

	datetime = function(v, _, context)
		return datetime.parse_datetime(v, context.default_date_str)
	end,

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
}

-- Parse @key(value) attributes from text
-- @param parser_context table Context of the text being parsed to optionally pass to functions like parse_datetime() default_date_str.
--  The attribute parsers know how to take the parser_context and pass relevant information to functions as necessary.
function M.parse_attributes(text, schema, parser_context)
	local attrs = {}
	local contexts = {}

	-- Pattern for @key(value)
	text = text:gsub("@(%w+)%(([^)]*)%)", function(key, value)
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
			-- Otherwise it's a context (@home, @work, @phone)
			table.insert(contexts, key)
		end

		return ""
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

function M.update_attributes(line, updates)
	local modified_line = line

	for key, value in pairs(updates) do
		if value == nil then
			-- Remove attribute
			modified_line = M.remove_attribute(modified_line, key)
		else
			-- Update/add attribute
			modified_line = M.update_attribute(modified_line, key, value)
		end
	end

	return modified_line
end

function M.to_line(attributes)
	return M.update_attributes("", attributes)
end

-- Remove attribute
function M.remove_attribute(line, key)
	if not line or not key then
		return line
	end

	return line:gsub("@" .. key .. "%(([^)]+)%)", ""):gsub("%s+", " "):gsub("%s$", "")
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
		size = { type = "enum", values = { "xs", "sm", "md", "lg", "xl" } },
		p = { type = "enum", values = { "1", "2", "3" } },
		i = { type = "enum", values = { "1", "2", "3" } },
		due = { type = "date" },
		at = { type = "string" },
		dur = { type = "duration" },
		est = { type = "duration" },
		done = { type = "date" },
		progress = { type = "progress" },
		["repeat"] = { type = "string" },
		notify = { type = "notify" },
		depends = { types = "string" }, -- Specifies task dependence
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
		from = { type = "datetime" },
		to = { type = "datetime" },
		["repeat"] = { type = "string" },
		notify = { type = "notify" },
		area = { type = "area" },
		a = "area",
	},
}

-- =============================================================================
-- Parse schemas
-- =============================================================================

-- `context` parameter passes additional information for parsing attributes.
-- Currently only used for passing a default date to the 'datetime' attribute

-- Parse task attributes
function M.parse_task_attributes(line, context)
	return M.parse_attributes(line, M.schemas.task, context)
end

-- Parse project attributes
function M.parse_project_attributes(line, context)
	return M.parse_attributes(line, M.schemas.project, context)
end

-- Parse event attributes
function M.parse_event_attributes(line, context)
	return M.parse_attributes(line, M.schemas.event, context)
end

-- Parse calendar entry attributes
function M.parse_calendar_attributes(line, context)
	return M.parse_attributes(line, M.schemas.calendar_entry, context)
end

-- Strip attributes (returns clean text and extracted attributes)
function M.strip_attributes(line, schema)
	return M.parse_attributes(line, schema)
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

function M.extract_progress(line)
	local progress_str = M.extract_attribute(line, "progress")
	if progress_str then
		local completed, total = progress_str:match("(%d+)/(%d+)")
		if completed and total then
			return {
				completed = tonumber(completed),
				total = tonumber(total),
				percentage = tonumber(total) > 0 and (tonumber(completed) / tonumber(total)) or 0,
			}
		end
	end
	return nil
end

-- Done attribute helpers
function M.update_done_attribute(line, done)
	if done then
		return M.update_attribute(line, "done", os.date("%Y-%m-%d"))
	else
		return M.remove_attribute(line, "done")
	end
end

function M.was_done(line)
	return M.extract_attribute(line, "done") ~= nil
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
