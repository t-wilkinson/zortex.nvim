-- config.lua - Centralized configuration for Zortex
local Config = {}
local constants = require("zortex.constants")

local defaults = {
	notes_dir = vim.fn.expand("~/zortex/"),
	extension = ".zortex",
	-- A new notes folder gets calendar, projects, areas, okr, structure and
	-- inbox notes from short templates (:ZortexInit adds missing ones later)
	init_files = true,
	debug = false,

	-- Commands and keymaps are generated from zortex.actions (:ZortexHelp lists them)
	commands = {
		prefix = "Zortex", -- :ZortexSearch, :ZortexReview, ...
	},
	keymaps = {
		enabled = true,
		prefix = "<leader>z",
		-- Per-action overrides by action id: a key, a list of keys, or false.
		-- e.g. { task_toggle = "t", search_articles = false, review = { "w", "R" } }
		mappings = {},
		-- which-key names for key prefixes (when which-key is installed):
		-- <prefix> is "Zortex", and a prefix like "x" of "xs" is named after
		-- its actions' group ("XP") unless set here. false skips one, or set
		-- groups = false to name none.
		groups = { C = "Calendar" },
	},

	core = {
		logger = {
			enabled = false,
			log_events = false,
			level = 3, -- TRACE, DEBUG, INFO, WARN, ERROR
			max_entries = 1000,
			performance_threshold = 16, -- Log operations taking > 16ms
		},
	},

	-- `zortex serve -data DIR` (app/): keeps the calendar's notifications and
	-- the pomodoro clock, and sends both through ntfy. With a base path the
	-- endpoint includes it, e.g. "https://zortex.home.lab/notes".
	server = {
		enabled = false,
		api_endpoint = "http://127.0.0.1:8090",
		api_key = nil, -- the server's -api-key / ZORTEX_API_KEY, if set
		user_id = "default",
		-- the web app's address for :ZortexPresent and <prefix>gX when it
		-- isn't api_endpoint
		-- (e.g. "https://zortex.home.lab/notes"); nil: api_endpoint
		web_url = nil,
	},

	features = {
		folding = {
			-- Notes open folded below this level: 1 shows the headings of a
			-- note (zo / zR open folds); 99 opens everything
			level = 1,
			include_empty_lines = true,
		},
		-- Links that resolve nowhere (and paths to missing files) as
		-- vim.diagnostic on their notes (]d / [d); severity "ERROR" | "WARN" |
		-- "INFO" | "HINT"
		diagnostics = { enabled = true, severity = "WARN" },
		-- J in a note drops what only starts a line: the joined line's
		-- "#"s, "-" (and "[ ]"), "1." or "> ", and the ":" of a label it is
		-- joined onto. gJ joins as written.
		join = { enabled = true },
		-- <prefix>gX: links in the web app (server.web_url)
		web = {
			-- show them in the tab on this computer you focused last, when
			-- the server is enabled and one is open; false: a new tab
			reuse_tab = true,
		},
	},

	notifications = {
		-- Global settings
		enabled = true,
		check_interval_minutes = 5,
		default_advance_minutes = 15,

		-- Channel routing
		channels = {
			calendar = { "vim", "ntfy" },
			pomodoro = { "vim", "system" }, -- only "ntfy" when ntfy is enabled (types.pomodoro.ntfy_only)
			default = { "vim", "ntfy" },
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
			ntfy = {
				enabled = false,
				server_url = "https://ntfy.sh",
				-- Required: anyone who knows a topic can read it, so pick a
				-- private, hard-to-guess one. Nothing is sent without it.
				topic = nil,
				priority = "default",
				tags = { "zortex" },
				auth_token = nil,
			},
		},

		types = {
			-- With server.enabled the clock runs in the server (shared with its
			-- home page); these settings are pushed to it when they change.
			pomodoro = {
				work_duration = 25, -- minutes
				short_break = 5, -- minutes
				long_break = 15, -- minutes
				long_break_after = 4, -- number of work sessions
				auto_start_break = true,
				auto_start_work = false,
				use_server = true, -- false: always run the clock in Neovim
				ntfy_only = true, -- ntfy enabled: alerts go only through ntfy
				-- Played locally when alerts don't go through ntfy (paths, or false
				-- for silence). Unset: freedesktop sounds (macOS: system sounds)
				-- when present. With ntfy, contrib/ntfy/notify.sh picks the sound
				-- from the message tags.
				sounds = {
					-- work_start = "~/sounds/work.oga",
					-- break_start = "~/sounds/break.oga",
					-- restart = "~/sounds/restart.oga",
					-- work_end = ..., break_end = ...,
				},
				-- The player: a program, a string with arguments ("pw-play --volume
				-- 0.5") or a list ({ "mpv", "--no-video", "%s" }); "%s" is the file,
				-- else it goes last. Default: paplay (afplay on macOS)
				sound_command = nil,
			},

			calendar = {
				default_advance_minutes = 0,
				sync_days = 30, -- How many days ahead to scan
			},
		},
	},

	ui = {
		-- Search, projects, calendar and follow-link pickers: "telescope",
		-- "snacks", "fzf_lua" or "select" (vim.ui.select). "auto": LazyVim's
		-- picker, else a snacks.picker you enabled, telescope, fzf-lua,
		-- snacks.picker, and vim.ui.select when none is installed.
		picker = "auto",

		-- Highlight groups: linked to your colorscheme by default.
		-- preset = "rose-pine" for a Rose Pine Moon palette; groups = { ZortexLink = { fg = "#3e8fb0" } }
		highlights = {
			preset = nil,
			groups = {},
		},

		-- Link preview float (<prefix>K / :ZortexLinkPreview)
		preview = {
			on_hover = false, -- preview the link under the cursor on CursorHold ('updatetime' is the delay)
		},

		-- :ZortexPlan (ui/planner.lua, services/planner.lua)
		planner = {
			todo_link = "P/#TODOs", -- tasks under this project rank higher
			max_tasks = 30,
			project_tasks = 3, -- P puts a project's next this many open tasks on the day (5P: five)
			-- "Coming up": the events of this many days after the day (timed
			-- lines, @event, calendar notes), in the plan and the calendar
			-- view; 0 hides them
			upcoming_days = 7,
			-- The capacity line: open tasks on the day (their @size hours) against
			-- the free time left in `day`, after timed entries that aren't project
			-- work (lectures, appointments; one without an end counts event_minutes)
			capacity = {
				day = { "08:00", "22:00" },
				event_minutes = 30,
			},
			width = 70, -- plan window width
			advance = false, -- after a put, move the calendar cursor to the next line
			-- :ZortexPlan for today copies the open tasks of the days before
			-- (same @id) and marks the old lines [>]; how many days back
			carry_forward = true,
			carry_days = 14,
			-- Lines for a new calendar day. Keys: monday … sunday override
			-- weekday / saturday / sunday. e.g.
			--   weekday = { "07:00 Morning routine [P/#1 Personal/#Habits]", "09:00", "12:00 Lunch", "13:00", "17:00" },
			--   saturday = { "09:00", "14:00" },
			templates = {},
		},

		search = {
			default_mode = "section", -- or "article", "text" (plain text); keys.cycle_mode cycles them
			max_results = 500,
			-- Keys in the search picker (any backend), shown in its title;
			-- false turns one off. <M-t> is taken by some terminals and
			-- multiplexers (zellij): e.g. cycle_mode = "<M-m>". Not <C-t>:
			-- telescope, snacks and fzf-lua open in a tab with it.
			keys = {
				cycle_mode = "<M-t>", -- section / article / text search
				new_note = "<C-o>", -- a new note named after the query
			},
			access_decay_rate = 0.1, -- per day
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
				day_header = "Title",
				notification = "DiagnosticWarn",
				selected = "PmenuSel",
				today_selected = "PmenuSel",
				selected_text = "PmenuSel",
				selected_icon = "PmenuSel",
			},
			pretty_attributes = true, -- Enable/disable pretty display of attributes
			-- Plain Unicode by default; with a Nerd Font, e.g.
			--   event = "󰃰", task = "󰄬", task_done = "󰄱", notification = "󰂞", has_items = "󰸞"
			icons = {
				event = "◆",
				task = "□",
				task_done = "☑",
				notification = "!",
				has_items = "•",
				none = " ",
			},
			keymaps = {
				close = { "q", "<Esc>", "<C-c>" },
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
				search = { "/" },
				refresh = { "r", "R" },
				go_to_file = { "gf" },
				toggle_task = { "x" }, -- 2x ticks the day's task 2
				sync_notifications = { "n" },
				help = { "?" },
			},
		},
	},

	-- Reviews are written in reviews.zortex, one "# 2026-W43" entry per week
	-- with its days ("## 2026-10-21") inside, newest first. :ZortexReview opens
	-- the entry next to the generated findings (services/review, ui/review).
	review = {
		-- a weekly review from this day on plans the next week ("saturday":
		-- Saturday and Sunday reviews pick the coming week's focus)
		next_week_from = "saturday",
		-- a new week's lines; the projects linked under "Focus:" are the week's
		-- focus, ranked first by the planner
		week = { "Focus:", "", "Wins:", "", "Lessons:" },
		-- a new day's lines
		day = { "Done:", "Blocked:", "First thing tomorrow:" },
		width = 80, -- findings window width
		-- where m in the review moves an inbox line without @project(...): a
		-- link like "P/#Areas" (a heading of the projects note for small
		-- tasks that aren't projects); nil asks, with :ZortexMove's search
		inbox_default = nil,
	},

	-- XP is read off the notes (services/xp/ledger): completed tasks with their
	-- @done dates, projects (a pool paid out over their tasks) and objectives
	-- marked @done. Nothing is stored but seasons; see doc/Planning.md.
	xp = {
		stamp_done_on_save = true, -- tasks checked by hand get @done(today) on save
		notify_min = 5, -- announce awards of at least this much XP
		publish = true, -- write .z/xp_summary.json (and POST it to server) for the web app's home page

		-- One unit for everything: XP is estimated work, 10 XP = 1 hour of it.
		-- :ZortexXPGuide shows the whole table with your settings.
		xp_per_hour = 10,

		-- @size -> estimated hours. Tasks without a size count as md. A project
		-- without a size is the sum of its tasks; an objective without one is
		-- the sum of the projects its key results link (else md). These hours
		-- are also the effort points that weigh project and key-result progress.
		sizes = {
			task = {
				xs = 0.25, -- 15 minutes
				sm = 0.5,
				md = 1, -- an hour, 2 pomodoros
				lg = 2,
				xl = 3,
				["2xl"] = 5,
				["3xl"] = 8,
				["4xl"] = 13,
				["5xl"] = 20,
			},
			project = {
				xs = 2, -- a couple of hours
				sm = 6, -- a day
				md = 12, -- a few days
				lg = 20, -- half a week
				xl = 40, -- a solid week
				epic = 160, -- a month
				legendary = 480, -- a quarter
				mythic = 1000, -- several quarters
				ultimate = 2500, -- years
			},
			objective = {
				xs = 5,
				sm = 10,
				md = 30,
				lg = 60,
				xl = 120,
			},
		},

		-- Mastery (area XP) = XP x how the work serves the plan
		alignment = {
			key_result = 1.0, -- a project a key result links (to the objective's areas first)
			project_area = 0.2, -- a project with its own @a(...), no key result
			task_area = 0.1, -- a task outside projects with @a(...)
		},

		-- An award's Mastery share split over its areas, most specific first:
		-- each area gets this ratio of the one before (1: even, 0.5: half,
		-- 0.7: gently decaying)
		area_split = 0.5,

		-- Reaching a key result pays this share of its objective's XP (split
		-- over its key results); completing the objective (@done) pays it again
		completion_bonus = 0.2,

		-- Areas: long-term mastery. Level L at base * L^exponent XP; with 10 XP
		-- an hour, level 10 is about 10,000 hours
		area = {
			level_curve = { base = 316, exponent = 2.5 },
			bubble = 0.75, -- share of a sub-area's XP that also counts for its parent
		},

		-- Seasons: progress on the objectives that fall in the season, weighted
		-- by their XP (size x priority x importance)
		season = {
			default_length = 90, -- days
			-- No season started by hand (or it ended): the calendar quarter is
			-- the season, the same window as 3M-YYYY-Qn objectives
			follow_quarter = true,
			tiers = {
				{ name = "Bronze", at = 0.25 },
				{ name = "Silver", at = 0.50 },
				{ name = "Gold", at = 0.70 },
				{ name = "Platinum", at = 0.85 },
				{ name = "Complete", at = 1.0 },
			},
		},

		modifiers = {
			priority_multipliers = { [1] = 1.5, [2] = 1.2, [3] = 1.0, default = 1 },
			importance_multipliers = { [1] = 1.5, [2] = 1.2, [3] = 1.0, default = 1 },
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

-- Built-in defaults (read-only). Modules overlay their slice of these with the
-- user's options, e.g. services/search.setup(Config.ui.search).
Config.defaults = defaults

-- Initialize configuration
function Config.setup(opts)
	-- Merge default and user options in place to avoid cache issues
	deep_merge_in_place(Config, defaults)
	if opts and type(opts) == "table" then
		deep_merge_in_place(Config, opts)
	end

	-- "~/notes", "$HOME/notes": expand; ensure a trailing slash
	Config.notes_dir = vim.fn.expand(Config.notes_dir)
	if not Config.notes_dir:match("/$") then
		Config.notes_dir = Config.notes_dir .. "/"
	end

	-- Ensure core zortex folders exist
	local fs = require("zortex.utils.filesystem")
	vim.fn.mkdir(fs.joinpath(Config.notes_dir, ".z"), "p") -- Store data
	vim.fn.mkdir(fs.joinpath(Config.notes_dir, "z"), "p") -- Resources and archives

	-- Neovim names a buffer by its resolved path, so resolve notes_dir too:
	-- a notes folder reached through a symlink (or macOS's /var) must give
	-- the same paths as its buffers, or the calendar, the Projects note and
	-- the key notes aren't recognized
	local real = vim.uv.fs_realpath(Config.notes_dir)
	if real then
		Config.notes_dir = real:match("/$") and real or (real .. "/")
	end

	return Config
end

return Config
