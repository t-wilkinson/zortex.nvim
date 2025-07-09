-- config.lua - Centralized configuration for Zortex
local M = {}

M.defaults = {
	-- XP System Configuration
	xp = {
		-- Base XP values
		base = {
			task = 10,
			project = 50,
			okr_connected_bonus = 2.0,
			okr_objective = 100,
		},

		-- Task sizes
		task_sizes = {
			xs = { duration = 15, multiplier = 0.5 },
			sm = { duration = 30, multiplier = 0.8 },
			md = { duration = 60, multiplier = 1.0 },
			lg = { duration = 120, multiplier = 1.5 },
			xl = { duration = 240, multiplier = 2.0 },
		},
		default_task_size = "md",

		-- Project sizes
		project_sizes = {
			xs = { multiplier = 0.5 },
			sm = { multiplier = 0.8 },
			md = { multiplier = 1.0 },
			lg = { multiplier = 1.5 },
			xl = { multiplier = 2.0 },
			epic = { multiplier = 3.0 },
			legendary = { multiplier = 5.0 },
			mythic = { multiplier = 8.0 },
			ultimate = { multiplier = 12.0 },
		},
		default_project_size = "md",

		-- Priority/Importance multipliers
		priority_multipliers = {
			p1 = 1.5,
			p2 = 1.2,
			p3 = 1.0,
			default = 0.9,
		},
		importance_multipliers = {
			i1 = 1.5,
			i2 = 1.2,
			i3 = 1.0,
			default = 0.9,
		},

		-- OKR multipliers
		span_multipliers = {
			M = 1.0,
			Q = 1.5,
			Y = 2.0,
			["5Y"] = 3.0,
			["10Y"] = 4.0,
		},

		-- Task completion curve
		completion_curve = {
			[0.1] = 0.05,
			[0.2] = 0.10,
			[0.3] = 0.16,
			[0.4] = 0.23,
			[0.5] = 0.31,
			[0.6] = 0.40,
			[0.7] = 0.50,
			[0.8] = 0.62,
			[0.9] = 0.76,
			[1.0] = 1.00,
		},
	},

	-- Skill Tree Configuration
	skills = {
		distribution_curve = "even", -- "even", "weighted", "primary"
		distribution_weights = {
			primary = 0.7,
			secondary = 0.2,
			tertiary = 0.1,
		},
		bubble_multiplier = 1.2,

		-- Objective XP
		objective_base_xp = {
			M = 100,
			Q = 300,
			Y = 1000,
			["5Y"] = 4000,
			["10Y"] = 12000,
		},

		-- Level thresholds
		level_thresholds = {
			100,
			300,
			600,
			1000,
			1500,
			2200,
			3000,
			4000,
			5200,
			6600,
		},
	},

	-- UI Configuration
	ui = {
		skill_tree = {
			width = 80,
			height = 30,
			border = "rounded",
		},
	},

	-- Archive Configuration
	archive = {
		bubble_xp = true,
	},
}

-- Current configuration
M.config = {}

-- Initialize configuration
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

	-- Validate required settings
	if not vim.g.zortex_notes_dir then
		error("g:zortex_notes_dir must be set")
	end

	return M.config
end

-- Get config value with dot notation
function M.get(path)
	local value = M.config
	for key in path:gmatch("[^%.]+") do
		value = value[key]
		if value == nil then
			return nil
		end
	end
	return value
end

return M
