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
	-- Add this to your zortex/config.lua defaults
	xp = {
		-- Base XP values
		base_xp = 10,
		orphan_xp = 5, -- Increased from 1 for better orphan task rewards
		xp_per_hour = 20,
		project_orphan_multiplier = 0.7,

		-- Distance-based multipliers (replaces simple decay)
		distance_multipliers = {
			[0] = 2.0, -- Vision-level tasks
			[1] = 1.5, -- Directly linked to vision
			[2] = 1.2, -- One hop from vision
			[3] = 1.0, -- Two hops from vision
			[4] = 0.8, -- Three hops from vision
			default = 0.5, -- Further away
		},
		distance_decay = 0.8, -- Fallback if not using multipliers

		-- Task size multipliers
		size_multipliers = {
			xs = 0.5,
			s = 0.75,
			m = 1.0,
			l = 1.5,
			xl = 2.0,
		},

		-- Size detection thresholds (lines of content)
		size_thresholds = {
			xs = 1,
			s = 3,
			m = 5,
			l = 10,
			xl = 20,
		},

		-- Priority multipliers
		priority = {
			p1 = 1.5,
			p2 = 1.2,
			p3 = 1.0,
		},

		-- Urgency settings
		urgency = {
			overdue = 2.0,
			today = 1.5,
			day_factor = 0.2,
			repeat_daily = 1.2,
		},

		-- Heat system for objectives
		heat = {
			enabled = true,
			default = 1.0,
			min = 0.1,
			max = 2.0,
			decay_per_week = 0.1,
			completion_increase = 0.1,
		},

		-- Project fatigue
		fatigue = {
			enabled = true,
			after_hours = 4,
			penalty = 0.7,
		},

		-- Streak bonuses
		streak = {
			enabled = true,
			daily_bonus = 50,
			cap_pct_of_day = 0.5,
		},

		-- Combo system
		combo = {
			enabled = true,
			window_minutes = 90,
			init = 10,
			step = 5,
			max = 100,
		},

		-- Vision quota
		vision_quota = {
			enabled = true,
			min_xp = 100,
			max_distance = 2,
		},

		-- Habit tracking
		habits = {
			enabled = true,
			daily_bonus = 50,
			weekly_bonus = 200,
			monthly_bonus = 1000,
			chain_multiplier = 1.1, -- 10% bonus per chain day
			completion_multiplier = 1.5, -- Multiplier for habit tasks
			chain_bonus = 5, -- XP per chain day
		},

		-- Resource tracking
		resources = {
			enabled = true,
			creation_bonus = 20,
			creation_multiplier = 1.2,
			consumption_penalty = -5,
			sharing_bonus = 30,
			sharing_multiplier = 1.5,
		},

		-- Budget tracking
		budget = {
			enabled = true,
			xp_per_dollar = 1,
			categories = {
				essential = { multiplier = 0.5 }, -- Less penalty for essentials
				investment = { multiplier = 1.5 }, -- More penalty for investments
				discretionary = { multiplier = 1.0 }, -- Normal penalty
				luxury = { multiplier = 2.0 }, -- High penalty for luxury
			},
			savings_milestones = {
				[100] = 500, -- Save $100, get 500 XP
				[500] = 3000, -- Save $500, get 3000 XP
				[1000] = 7500, -- Save $1000, get 7500 XP
				[5000] = 50000, -- Save $5000, get 50000 XP
			},
			exempt_areas = { "Health", "Education", "Emergency" },
		},

		-- Repeat task settings
		repeat_task = {
			miss_penalty = 50,
			types = { "daily", "weekly", "monthly" },
		},

		-- Badge thresholds
		badges = {
			-- XP-based badges
			["Beginner"] = 100,
			["Novice"] = 500,
			["Apprentice"] = 1000,
			["Journeyman"] = 5000,
			["Expert"] = 10000,
			["Master"] = 25000,
			["Grandmaster"] = 50000,
			["Legend"] = 100000,

			-- Special badges (handled by badge system)
			["Area Specialist"] = 1000, -- Per area
			["Budget Master"] = -1000, -- Saved money
			["Habit Former"] = 30, -- Days of habit
			["Resource Creator"] = 100, -- Resources created
		},

		-- Skill level definitions
		skill_levels = {
			{ name = "Novice", xp = 0 },
			{ name = "Apprentice", xp = 100 },
			{ name = "Journeyman", xp = 500 },
			{ name = "Expert", xp = 1000 },
			{ name = "Master", xp = 5000 },
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
