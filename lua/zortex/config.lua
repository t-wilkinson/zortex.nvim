-- Shared configuration module for Zortex system with XP functionality
-- Handles loading and parsing config.yaml file

local M = {}
local Path = require("plenary.path")

-- YAML parser (simple implementation for our needs)
local function parse_yaml(content)
	local result = {}
	local current_section = nil
	local current_subsection = nil
	local current_subsubsection = nil
	local indent_stack = { 0 }

	for line in content:gmatch("[^\r\n]+") do
		-- Skip comments and empty lines
		if line:match("^%s*#") or line:match("^%s*$") then
			goto continue
		end

		local indent = #(line:match("^(%s*)") or "")
		local trimmed = line:match("^%s*(.-)%s*$")

		-- Handle key-value pairs
		local key, value = trimmed:match("^([%w_]+):%s*(.*)$")
		if key then
			-- Determine nesting level based on indentation
			while #indent_stack > 1 and indent <= indent_stack[#indent_stack] do
				table.remove(indent_stack)
				if current_subsubsection then
					current_subsubsection = nil
				elseif current_subsection then
					current_subsection = nil
				elseif current_section then
					current_section = nil
				end
			end

			if value == "" or not value then
				-- This is a section header
				if indent == 0 then
					current_section = key
					result[key] = result[key] or {}
				elseif current_section and indent > indent_stack[#indent_stack] then
					if not current_subsection then
						current_subsection = key
						result[current_section][key] = result[current_section][key] or {}
					else
						current_subsubsection = key
						result[current_section][current_subsection][key] = result[current_section][current_subsection][key]
							or {}
					end
				end
				table.insert(indent_stack, indent)
			else
				-- Parse the value
				local parsed_value

				-- Remove quotes
				value = value:gsub("^['\"]", ""):gsub("['\"]$", "")

				-- Boolean
				if value == "true" then
					parsed_value = true
				elseif value == "false" then
					parsed_value = false
				-- Number
				elseif value:match("^%-?%d+%.%d+$") or value:match("^%-?%d+$") then
					parsed_value = tonumber(value)
				-- String
				else
					parsed_value = value
				end

				-- Assign value to appropriate level
				if current_subsubsection and current_subsection and current_section then
					result[current_section][current_subsection][current_subsubsection][key] = parsed_value
				elseif current_subsection and current_section then
					result[current_section][current_subsection][key] = parsed_value
				elseif current_section then
					result[current_section][key] = parsed_value
				else
					result[key] = parsed_value
				end
			end
		end

		::continue::
	end

	return result
end

-- Default configuration
M.defaults = {
	-- Calendar settings
	calendar = {
		daily_digest = "09:00",
		enable_daily_digest = true,
	},

	-- XP System Configuration
	xp = {
		-- Base XP values
		base_xp = {
			task = 10, -- Base XP for completing a task
			project = 50, -- Base XP for completing a project
			okr_connected_bonus = 2.0, -- Multiplier for OKR-connected tasks
		},

		-- Task size definitions and their default durations (in minutes)
		task_sizes = {
			xs = { duration = 15, xp_multiplier = 0.5 },
			sm = { duration = 30, xp_multiplier = 0.8 },
			md = { duration = 60, xp_multiplier = 1.0 }, -- Default size
			lg = { duration = 120, xp_multiplier = 1.5 },
			xl = { duration = 240, xp_multiplier = 2.0 },
		},
		default_task_size = "md",

		-- Priority multipliers
		priority_multipliers = {
			p1 = 1.5,
			p2 = 1.2,
			p3 = 1.0,
			default = 0.9,
		},

		-- Importance multipliers
		importance_multipliers = {
			i1 = 1.5,
			i2 = 1.2,
			i3 = 1.0,
			default = 0.9,
		},

		-- OKR span code multipliers (bigger timeframe = bigger multiplier)
		span_multipliers = {
			M = 1.0, -- Monthly
			Q = 1.5, -- Quarterly
			Y = 2.0, -- Yearly
			["5Y"] = 3.0, -- 5 Year
			["10Y"] = 4.0, -- 10 Year
		},

		-- Temporal distance penalty (for non-current OKRs)
		temporal_penalties = {
			current = 1.0,
			recent = 0.8, -- Within last quarter
			past_year = 0.6, -- Within last year
			old = 0.4, -- Older than a year
		},

		-- Skill transfer settings (for projects with multiple areas)
		skill_transfer = {
			primary_area_weight = 0.7, -- Primary area gets 70% of XP
			secondary_area_weight = 0.2, -- Secondary areas share 20%
			tertiary_area_weight = 0.1, -- All other areas share 10%
		},

		-- Completion bonuses
		completion_bonuses = {
			daily_streak = 10, -- Bonus for completing tasks every day
			weekly_goals = 50, -- Bonus for meeting weekly goals
			project_milestone = 100, -- Bonus for project milestones
		},

		-- Penalties
		penalties = {
			overdue_task = 0.9, -- Multiplier for overdue tasks
			abandoned_project = 0.5, -- Multiplier for abandoned projects
		},

		-- Custom XP calculation function (can be overridden in config.zortex)
		-- This allows users to define their own XP calculation logic
		custom_calculation = nil,
	},
}

-- Current configuration (will be populated from file)
M.current = vim.deepcopy(M.defaults)

-- Parse time string (HH:MM or HH:MMam/pm)
local function parse_time_config(time_str)
	if not time_str then
		return nil
	end

	-- Remove any quotes or extra spaces
	time_str = time_str:gsub('"', ""):gsub("'", ""):match("^%s*(.-)%s*$")

	-- Check if it's already in HH:MM format
	if time_str:match("^%d%d?:%d%d$") then
		return time_str
	end

	-- Check for am/pm format
	local hour, min, ampm = time_str:match("^(%d%d?):(%d%d)%s*([ap]m)$")
	if not hour then
		hour, min, ampm = time_str:match("^(%d%d?):(%d%d)([ap]m)$")
	end

	if hour and min and ampm then
		local h = tonumber(hour)
		if ampm == "pm" and h ~= 12 then
			h = h + 12
		elseif ampm == "am" and h == 12 then
			h = 0
		end
		return string.format("%02d:%02d", h, min)
	end

	return time_str
end

-- Parse a value from config
local function parse_value(value)
	-- Remove quotes and trim
	value = value:gsub('"', ""):gsub("'", ""):match("^%s*(.-)%s*$")

	-- Boolean
	if value == "true" then
		return true
	elseif value == "false" then
		return false
	end

	-- Number (integer or float)
	if value:match("^%-?%d+%.%d+$") then
		return tonumber(value)
	elseif value:match("^%-?%d+$") then
		return tonumber(value)
	end

	-- Array (comma-separated)
	if value:match(",") then
		local items = {}
		for item in value:gmatch("([^,]+)") do
			item = item:match("^%s*(.-)%s*$")
			table.insert(items, parse_value(item))
		end
		return items
	end

	-- String
	return value
end

-- Load configuration from config.yaml
function M.load()
	local config_path = Path:new(vim.g.zortex_notes_dir, "config.yaml")
	if not config_path:exists() then
		-- Try config.yml as fallback
		config_path = Path:new(vim.g.zortex_notes_dir, "config.yml")
		if not config_path:exists() then
			return M.current
		end
	end

	local content = config_path:read()
	local parsed = parse_yaml(content)

	-- Merge parsed config with defaults
	M.current = vim.tbl_deep_extend("force", M.current, parsed)

	-- Special handling for time values in calendar section
	if M.current.calendar and M.current.calendar.daily_digest then
		M.current.calendar.daily_digest = parse_time_config(M.current.calendar.daily_digest)
	end

	return M.current
end

-- Get a config value by path (e.g., "xp.task_sizes.md.duration")
function M.get(path)
	local parts = vim.split(path, ".", { plain = true })
	local value = M.current

	for _, part in ipairs(parts) do
		if type(value) == "table" and value[part] ~= nil then
			value = value[part]
		else
			return nil
		end
	end

	return value
end

-- Set a config value by path
function M.set(path, value)
	local parts = vim.split(path, ".", { plain = true })
	local current = M.current

	for i = 1, #parts - 1 do
		if type(current[parts[i]]) ~= "table" then
			current[parts[i]] = {}
		end
		current = current[parts[i]]
	end

	current[parts[#parts]] = value
end

-- Example config.zortex content:
--[[
-- Example config.zortex file for XP system customization

calendar:
  daily_digest: 09:00
  enable_daily_digest: true

xp:
  base_xp:
    task: 15
    project: 75
    okr_connected_bonus: 2.5
  
  task_sizes:
    xs:
      duration: 10
      xp_multiplier: 0.4
    sm:
      duration: 25
      xp_multiplier: 0.7
    md:
      duration: 60
      xp_multiplier: 1.0
    lg:
      duration: 150
      xp_multiplier: 1.8
    xl:
      duration: 300
      xp_multiplier: 2.5
  
  default_task_size: md
  
  priority_multipliers:
    p1: 2.0
    p2: 1.5
    p3: 1.1
    default: 1.0
  
  span_multipliers:
    M: 1.2
    Q: 2.0
    Y: 3.0
    5Y: 5.0
    10Y: 8.0
  
  skill_transfer:
    primary_area_weight: 0.8
    secondary_area_weight: 0.15
    tertiary_area_weight: 0.05
--]]

-- Initialize and load config
M.load()

return M
