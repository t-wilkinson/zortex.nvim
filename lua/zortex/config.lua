-- Shared configuration module for Zortex system
-- Handles loading and parsing config.zortex file

local M = {}
local Path = require("plenary.path")

-- Default configuration
M.defaults = {
	-- Calendar settings
	calendar = {
		daily_digest = "09:00",
		enable_daily_digest = true,
	},

	-- XP settings (from xp.lua)
	xp = {
		-- Graph weights
		distance_decay = 0.6,
		base_xp = 100,
		multi_parent_bonus = "sum",
		orphan_xp = 1,

		-- Multipliers
		priority = { p1 = 1.5, p2 = 1.2, p3 = 1.0 },
		urgency = { day_factor = 0.2, repeat_daily = 1.1 },
		xp_per_hour = 5,

		-- Size modifiers
		size_multipliers = {
			xs = 0.5,
			s = 0.8,
			m = 1.0,
			l = 1.5,
			xl = 2.0,
		},
		size_thresholds = {
			l = 6,
			xl = 12,
		},

		-- Budget
		budget = {
			enabled = true,
			xp_per_dollar = 1,
			exempt_areas = { "Health", "Education" },
		},

		-- Momentum
		streak = { daily_bonus = 10, cap_pct_of_day = 0.5 },
		combo = { init = 20, step = 10 },

		-- Project fatigue
		fatigue = { after_hours = 4, penalty = 0.5, reset_hours = 12 },

		-- Objective heat
		heat = { default = 1.0, decay_per_week = 0.10 },

		-- Badges
		badges = {
			["Vision Keeper"] = 1000,
			["Deep Work"] = 500,
			["Consistency Master"] = 2000,
			["Multi-Focus"] = 1500,
			["Sprint Champion"] = 3000,
			["Budget Master"] = 5000,
			["Area Specialist"] = 1000,
		},

		-- Vision quota
		vision_quota = { enabled = true, min_xp = 50 },

		-- Skill tree levels
		skill_levels = {
			{ name = "Novice", xp = 0 },
			{ name = "Apprentice", xp = 500 },
			{ name = "Journeyman", xp = 1500 },
			{ name = "Expert", xp = 3000 },
			{ name = "Master", xp = 5000 },
			{ name = "Grandmaster", xp = 10000 },
		},
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

-- Load configuration from config.zortex
function M.load()
	local config_path = Path:new(vim.g.zortex_notes_dir, "config" .. (vim.g.zortex_extension or ".zortex"))
	if not config_path:exists() then
		return M.current
	end

	local content = config_path:read()
	local current_section = nil
	local current_subsection = nil

	for line in content:gmatch("[^\r\n]+") do
		-- Skip comments and empty lines
		if line:match("^%s*%-%-") or line:match("^%s*$") then
			goto continue
		end

		-- Main section headers (e.g., "calendar:", "xp:")
		local section = line:match("^(%w+):$")
		if section then
			current_section = section
			current_subsection = nil
			if not M.current[section] then
				M.current[section] = {}
			end
			goto continue
		end

		-- Subsection headers with indentation (e.g., "  budget:")
		local subsection = line:match("^%s+(%w+):$")
		if subsection and current_section then
			current_subsection = subsection
			if not M.current[current_section][subsection] then
				M.current[current_section][subsection] = {}
			end
			goto continue
		end

		-- Key-value pairs
		local indent, key, value = line:match("^(%s*)([%w_]+):%s*(.+)")
		if key and value then
			value = parse_value(value)

			-- Special handling for time values in calendar section
			if current_section == "calendar" and (key == "daily_digest" or key:match("time")) then
				value = parse_time_config(value)
			end

			-- Determine where to store the value based on indentation
			if current_subsection and #indent > 2 then
				-- This is under a subsection
				M.current[current_section][current_subsection][key] = value
			elseif current_section then
				-- This is directly under a section
				if current_subsection and #indent == 2 then
					M.current[current_section][current_subsection][key] = value
				else
					M.current[current_section][key] = value
				end
			end
		end

		::continue::
	end

	return M.current
end

-- Get a config value by path (e.g., "calendar.daily_digest")
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

-- Initialize and load config
M.load()

return M
