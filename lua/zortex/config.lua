-- config.lua - Centralized configuration for Zortex
local Config = {}
local constants = require("zortex.constants")

local defaults = {
	notes_dir = vim.fn.expand("~/.zortex/"),
	extension = ".zortex",
	special_articles = { "structure" }, -- Changes link opening behavior
	debug = false,
	commands = {
		prefix = "Zortex",
	},
	keymaps = {
		prefix = "<leader>z",
	},

	core = {
		persistence_manager = {
			enabled = true,
			save_interval = 5000, -- 5 seconds
			save_on_exit = true,
			save_on_events = true,
			batch_saves = true,
		},

		logger = {
			enabled = false,
			log_events = false,
			level = 3, -- TRACE, DEBUG, INFO, WARN, ERROR
			max_entries = 1000,
			performance_threshold = 16, -- Log operations taking > 16ms
		},
	},

	notifications = {
		-- Global settings
		enabled = true,
		check_interval_minutes = 5,
		default_advance_minutes = 15,

		-- Channel routing (replaces individual enable flags)
		channels = {
			calendar = { "vim", "system", "ntfy" },
			alarm = { "vim", "system", "ntfy" },
			timer = { "vim", "system" },
			pomodoro = { "vim", "system" },
			digest = { "ses" },
			xp = { "vim" },
			task_due = { "vim", "ntfy", "ses" },
			default = { "vim", "system" },
		},

		-- Provider configuration
		providers = {
			vim = {
				enabled = true,
				timeout = 5000,
				level = vim.log.levels.INFO,
			},
			system = {
				enabled = true,
				commands = {
					macos = "terminal-notifier -title '%s' -message '%s' -sound default",
					linux = "notify-send -u normal -t 10000 '%s' '%s'",
					termux = "termux-notification --title '%s' --content '%s'",
				},
			},
			aws = {
				enabled = false,
				api_endpoint = nil,
				user_id = nil,
			},
			ses = {
				enabled = false,
				region = "us-east-1", -- Your AWS region
				from_email = "noreply@yourdomain.com",
				default_to_email = "your-email@example.com",
				domain = "yourdomain.com",
				use_api = false, -- Use AWS CLI for now
			},
			ntfy = {
				enabled = false,
				server_url = "http://ntfy.sh",
				topic = "zortex-notify",
				priority = "default",
				tags = { "zortex" },
				auth_token = nil,
			},
		},

		types = {
			digest = {
				enabled = true,
				auto_send = true,
				days_ahead = 7,
				send_hour = 7,
				check_interval_minutes = 60,
				digest_email = "your-email@example.com", -- Can be different from default
			},

			pomodoro = {
				work_duration = 25, -- minutes
				short_break = 5, -- minutes
				long_break = 15, -- minutes
				long_break_after = 4, -- number of work sessions
				auto_start_break = true,
				auto_start_work = false,
				sound = "default",
			},

			timers = {
				default_sound = "default",
				allow_multiple = true,
				warnings = { 300, 60 },
			},

			alarm = {
				default_sound = "default",
				default_snooze_duration = 10, -- minutes
				auto_remove_triggered = true,
				presets = {},
			},

			calendar = {
				default_advance_minutes = 0,
				sync_days = 30, -- How many days ahead to scan
			},
		},
	},

	ui = {
		search = {
			default_mode = "section", -- or "article"
			max_results = 500,
			min_score = 0.1,
			access_decay_rate = 0.1, -- per day
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
			token_filters = {
				[1] = {
					constants.SECTION_TYPE.ARTICLE,
					{ constants.SECTION_TYPE.HEADING, max_level = 1 },
				},
				[2] = {
					constants.SECTION_TYPE.ARTICLE,
					{ constants.SECTION_TYPE.HEADING, max_level = 3 },
				},
				[3] = {
					constants.SECTION_TYPE.ARTICLE,
					constants.SECTION_TYPE.HEADING,
					constants.SECTION_TYPE.BOLD_HEADING,
					constants.SECTION_TYPE.LABEL,
				},
				[4] = "all", -- All section types except tags
			},
		},

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
		sources = {
			task = {
				season = 1.0,
				area = 0.1, -- to each linked area
				area_bubble = 0.75,

				base_xp = 10, -- 1 hour, 2 pomodoros
				sizes = {
					-- Think of base xp in terms of minutes/pomodoro cycles that it would take.
					xs = { multiplier = 0.2 }, -- ~0.5 pomodoros, 5-15 minutes
					sm = { multiplier = 0.5 },
					md = { multiplier = 1 }, -- 2 pomodoros, 1 hour
					lg = { multiplier = 1.5 },
					xl = { multiplier = 3 }, -- 6 pomodoros, 3 hours
				},
			},

			project = {
				season = 1.0,
				area = 0.2,
				area_bubble = 0.75,

				base_xp = 70, -- 7 hours, 14 pomodoros
				sizes = {
					xs = { multiplier = 0.5 }, -- a couple hours
					sm = { multiplier = 0.8 }, -- one day
					md = { multiplier = 1.0 }, -- multi-day effort
					lg = { multiplier = 1.5 }, -- half a week
					xl = { multiplier = 2.0 }, -- a solid week of work
					epic = { multiplier = 3.0 }, -- a month
					legendary = { multiplier = 5.0 }, -- a quarter
					mythic = { multiplier = 8.0 }, -- multiple quarters
					ultimate = { multiplier = 12.0 }, -- multiple years
				},
			},

			objective = {
				area = 1.0,
				area_bubble = 0.75,

				base_xp = 20, -- 20 hours, 40 pomodoros
				sizes = {
					M = 0.5,
					Q = 1.5,
					Y = 2.0,
					["5Y"] = 3.0,
					["10Y"] = 4.0,
				},
			},

			daily_review = {
				season = 1.0, -- 100% to season
				bonus_multiplier = 1.5, -- 50% bonus for consistency
			},
		},

		-- Area XP System (Long-term Mastery)
		area = {
			-- XP = base * level^exponent
			level_curve = {
				base = 1000,
				exponent = 2.5,
			},
		},

		-- Season Configuration
		season = {
			-- XP = base * level^exponent
			level_curve = {
				base = 100,
				exponent = 1.2,
			},

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

		modifiers = {
			-- -- Relevance decay (per day)
			-- decay_rate = 0.001, -- 0.1% per day
			-- decay_grace_days = 30, -- No decay for first 30 days

			priority_multipliers = {
				[1] = 1.5,
				[2] = 1.2,
				[3] = 1.0,
				default = 1,
			},
			importance_multipliers = {
				[1] = 1.5,
				[2] = 1.2,
				[3] = 1.0,
				default = 1,
			},
		},
	},
}

-- Helper function to merge tables deeply and in-place.
-- It copies keys from `t2` into `t1`.
local function deep_merge_in_place(t1, t2)
	for k, v in pairs(t2) do
		if type(v) == "table" and type(t1[k]) == "table" then
			deep_merge_in_place(t1[k], v) -- Recurse for nested tables
		else
			t1[k] = v -- Otherwise, set/overwrite the value
		end
	end
end

-- Initialize configuration
function Config.setup(opts)
	-- Merge default and user options in place to avoid cache issues
	deep_merge_in_place(Config, defaults)
	if opts and type(opts) == "table" then
		deep_merge_in_place(Config, opts)
	end

	-- Ensure trailing slash on notes_dir
	if not Config.notes_dir:match("/$") then
		Config.notes_dir = Config.notes_dir .. "/"
	end

	-- Ensure core zortex folders exist
	local fs = require("zortex.utils.filesystem")
	vim.fn.mkdir(fs.joinpath(Config.notes_dir, ".z"), "p") -- Store data
	vim.fn.mkdir(fs.joinpath(Config.notes_dir, "z"), "p") -- User library

	return Config
end

return Config
