-- config.lua - Centralized configuration for Zortex
local M = {}

-- Using M.defaults and M.config helps with type checking
M.defaults = {
	notes_dir = vim.fn.expand("$HOME/.zortex") .. "/",
	extension = ".zortex",
	special_articles = { "structure" },

	commands = {
		prefix = "Zortex",
	},
	keymaps = {
		prefix = "<leader>z",
	},

	search = {
		default_mode = "section", -- or "article"
		breadcrumb_display = {
			one_token = { "article" },
			two_tokens = { "article", "heading_1_2" },
			three_plus_tokens = { "article", "heading", "bold_heading", "label" },
		},
		history = {
			enabled = true,
			max_entries = 50,
			score_decay = 0.1, -- per day
			propagation_decay = 0.7,
		},
	},

	notifications = {
		-- Global settings
		enabled = true,
		check_interval_minutes = 5,
		default_advance_minutes = 15,

		-- Provider configuration
		providers = {
			system = {
				enabled = true,
				commands = {
					macos = "terminal-notifier -title '%s' -message '%s' -sound default",
					linux = "notify-send -u normal -t 10000 '%s' '%s'",
					termux = "termux-notification --title '%s' --content '%s'",
				},
			},
			ntfy = {
				enabled = true,
				server_url = "http://ntfy.sh",
				topic = "zortex-notify",
				priority = "default",
				tags = { "zortex" },
				auth_token = nil,
			},
			aws = {
				enabled = false,
				api_endpoint = nil,
				user_id = nil,
			},
			vim = {
				enabled = true,
				timeout = 5000,
				level = vim.log.levels.INFO,
			},
			ses = {
				enabled = true,
				region = "us-east-1", -- Your AWS region
				from_email = "noreply@yourdomain.com",
				default_to_email = "your-email@example.com",
				domain = "yourdomain.com",
				use_api = false, -- Use AWS CLI for now
			},
		},

		-- Default providers for different notification types
		default_providers = { "vim", "system" },
		calendar_providers = { "vim", "system", "ntfy" },
		timer_providers = { "vim", "system" },
		pomodoro_providers = { "vim", "system" },
		digest_providers = { "ses" },

		-- Daily digest settings
		digest = {
			enabled = true,
			auto_send = true,
			days_ahead = 7,
			send_hour = 7, -- 7 AM
			check_interval_minutes = 60,
			digest_email = "your-email@example.com", -- Can be different from default
		},

		-- Pomodoro settings
		pomodoro = {
			work_duration = 25, -- minutes
			short_break = 5, -- minutes
			long_break = 15, -- minutes
			long_break_after = 4, -- number of work sessions
			auto_start_break = true,
			auto_start_work = false,
			sound = "default",
		},

		-- Timer settings
		timers = {
			default_sound = "default",
			allow_multiple = true,
		},
	},

	ui = {
		calendar = {
			window = {
				relative = "editor",
				width = 82,
				height = 0.85,
				border = "rounded",
				title = " 📅 Zortex Calendar ",
				title_pos = "center",
			},
			colors = {
				today = "DiagnosticOk",
				weekend = "Comment",
				has_entry = "DiagnosticInfo",
				header = "Title",
				border = "FloatBorder",
				footer = "Comment",
				key_hint = "NonText",
				digest_header = "Title",
				notification = "DiagnosticWarn",
				-- "IncSearch" "CursorLine" "CursorLineNr"
				selected = "MiniHipatternsTodo",
				today_selected = "MiniHipatternsTodo",
				selected_text = "MiniHipatternsTodo",
				-- selected_icon = "@variable.builtin",
				selected_icon = "MiniHipatternsTodo",
			},
			-- icons = {
			-- 	event = "🎉",
			-- 	task = "📝",
			-- 	task_done = "✔",
			-- 	notification = "🔔",
			-- 	has_items = "•", -- Default dot for days with any entry
			-- },
			-- icons = {
			-- 	event = "◆",
			-- 	task = "□",
			-- 	task_done = "☑",
			-- 	notification = "◉",
			-- 	has_items = "•",
			-- 	none = " ",
			-- },
			pretty_attributes = true, -- Enable/disable pretty display of attributes
			icon_width = 3, -- Unfortunately necessary atm for calculating how much an icon will shift text in the terminal (fn.strwidth doesn't calculate it correctly).
			icons = {
				event = "󰃰", -- nf-md-calendar_star
				task = "󰄬", -- nf-md-checkbox_blank_circle_outline
				task_done = "󰄱", -- nf-md-check_circle
				notification = "󰍛", -- nf-md-bell_ring
				has_items = "󰸞", -- nf-md-dots_circle
				none = " ",
			},
			digest = {
				show_upcoming_days = 7, -- Show events for next 7 days
				show_high_priority = true, -- Show high priority/importance projects
				position = "right", -- right, bottom, or floating
			},
			keymaps = {
				close = { "q", "<Esc>" },
				next_day = { "l", "<Right>" },
				prev_day = { "h", "<Left>" },
				next_week = { "j", "<Down>" },
				prev_week = { "k", "<Up>" },
				next_month = { "J" },
				prev_month = { "K" },
				next_year = { "L" },
				prev_year = { "H" },
				today = { "t", "T" },
				add_entry = { "a", "i" },
				view_entries = { "<CR>", "o" },
				edit_entry = { "e" },
				delete_entry = { "x" },
				telescope_search = { "/" },
				toggle_view = { "v" },
				digest = { "d", "D" },
				refresh = { "r", "R" },
				go_to_file = { "gf" },
				sync_notifications = { "n" },
				help = { "?" },
			},
		},
		telescope = {
			-- Optional telescope-specific config
		},
	},

	xp = {
		-- Area XP System (Long-term Mastery)
		area = {
			-- Exponential curve: XP = base * level^exponent
			level_curve = {
				base = 1000,
				exponent = 2.5,
			},

			-- XP bubbling to parent areas
			bubble_percentage = 0.75, -- 75% of XP bubbles up

			-- Time horizon multipliers for objectives
			time_multipliers = {
				daily = 0.1, -- Very short term
				weekly = 0.25,
				monthly = 0.5,
				quarterly = 1.0,
				yearly = 3.0, -- Long-term goals worth more
				["5year"] = 10.0,
			},

			-- Relevance decay (per day)
			decay_rate = 0.001, -- 0.1% per day
			decay_grace_days = 30, -- No decay for first 30 days
		},

		-- Project XP System (Seasonal Momentum)
		project = {
			-- Polynomial curve for seasonal levels: XP = base * level^exponent
			season_curve = {
				base = 100,
				exponent = 1.2,
			},

			-- 3-stage task reward structure
			task_rewards = {
				-- Initiation stage (first N tasks)
				initiation = {
					task_count = 3,
					base_xp = 50,
					curve = "logarithmic", -- Front-loaded rewards
					multiplier = 2.0,
				},

				-- Execution stage (main body)
				execution = {
					base_xp = 20,
					curve = "linear",
				},

				-- Completion bonus (final task)
				completion = {
					multiplier = 5.0, -- 5x the execution XP
					bonus_xp = 200, -- Plus flat bonus
				},
			},

			-- Integration with Area system
			area_transfer_rate = 0.10, -- 10% of project XP goes to area
		},

		-- Season Configuration
		seasons = {
			-- Default season length (days)
			default_length = 90, -- Quarterly

			-- Battle pass tiers
			tiers = {
				{ name = "Bronze", required_level = 1 },
				{ name = "Silver", required_level = 5 },
				{ name = "Gold", required_level = 10 },
				{ name = "Platinum", required_level = 15 },
				{ name = "Diamond", required_level = 20 },
				{ name = "Master", required_level = 30 },
			},
		},

		-- Old system to migrate back in
		--[[
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

  -- Skills configuration
  skills = {
    categories = {
      technical = { color = "#61afef", icon = "💻" },
      creative = { color = "#c678dd", icon = "🎨" },
      business = { color = "#98c379", icon = "💼" },
      personal = { color = "#e06c75", icon = "🌟" },
    },
  },

--]]
	},
}

M.config = {}

M.cmd = function(name, command, opts)
	vim.api.nvim_create_user_command(M.config.commands.prefix .. name, command, opts or {})
end

M.map = function(mode, lhs, rhs, opts)
	vim.keymap.set(mode, M.config.keymaps.prefix .. lhs, rhs, opts or {})
end

-- Initialize configuration
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

	-- Set globals for backward compatibility
	vim.g.zortex_notes_dir = M.config.notes_dir
	vim.g.zortex_extension = M.config.extension
	vim.g.zortex_special_articles = M.config.special_articles

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
