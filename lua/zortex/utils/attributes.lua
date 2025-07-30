-- utils/attributes.lua - Simplified attributes module using consolidated parser
local M = {}

local parser = require("zortex.utils.parser")

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
		notify = { type = "list" },
		depends = { types = "string" }, -- Specifies task dependence
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
	},

	-- Event attributes
	event = {
		at = { type = "string" },
		from = { type = "datetime" },
		to = { type = "datetime" },
		notify = { type = "duration" },
		["repeat"] = { type = "string" },
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
		notify = { type = "list" },
	},
}

-- =============================================================================
-- Public API - Parsing
-- =============================================================================

-- Parse task attributes
function M.parse_task_attributes(line, context)
	return parser.parse_attributes(line, M.schemas.task, context)
end

-- Parse project attributes
function M.parse_project_attributes(line, context)
	return parser.parse_attributes(line, M.schemas.project, context)
end

-- Parse event attributes
function M.parse_event_attributes(line, context)
	return parser.parse_attributes(line, M.schemas.event, context)
end

-- Parse calendar entry attributes
function M.parse_calendar_attributes(line, context)
	return parser.parse_attributes(line, M.schemas.calendar_entry, context)
end

-- Strip attributes (returns clean text and extracted attributes)
function M.strip_attributes(line, schema)
	return parser.parse_attributes(line, schema)
end

-- =============================================================================
-- Public API - Manipulation
-- =============================================================================

-- Extract specific attribute
function M.extract_attribute(line, key)
	return parser.extract_attribute(line, key)
end

-- Update attribute
function M.update_attribute(line, key, value)
	return parser.update_attribute(line, key, value)
end

-- Remove attribute
function M.remove_attribute(line, key)
	return parser.remove_attribute(line, key)
end

-- Add attribute if not present
function M.add_attribute(line, key, value)
	if parser.extract_attribute(line, key) then
		return line -- Already has attribute
	end
	return parser.update_attribute(line, key, value)
end

-- =============================================================================
-- Specific Attribute Helpers
-- =============================================================================

-- Progress attribute helpers
function M.update_progress_attribute(line, completed, total)
	if total > 0 then
		return parser.update_attribute(line, "progress", string.format("%d/%d", completed, total))
	else
		return parser.remove_attribute(line, "progress")
	end
end

function M.extract_progress(line)
	local progress_str = parser.extract_attribute(line, "progress")
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
		return parser.update_attribute(line, "done", os.date("%Y-%m-%d"))
	else
		return parser.remove_attribute(line, "done")
	end
end

function M.was_done(line)
	return parser.extract_attribute(line, "done") ~= nil
end

function M.extract_task_id(line)
	return parser.extract_attribute(line, "id")
end

-- Task status parsing
function M.parse_task_status(line)
	return parser.parse_task_status(line)
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
