-- A comprehensive gamification engine for the Zortex note-taking system

local M = {}

-- Dependencies
local Path = require("plenary.path")
local Job = require("plenary.job")

-- State management
M.state = {
	xp_log = {},
	current_streak = 0,
	last_completion_date = nil,
	daily_xp = 0,
	combo = { project = nil, count = 0, last_time = 0 },
	total_xp = 0,
	level = 1,
	badges = {},
	objective_heat = {},
	project_fatigue = {},
}

-- Default configuration
M.config = {
	-- Graph weights
	distance_decay = 0.6,
	base_xp = 100,
	multi_parent_bonus = "sum",
	orphan_xp = 1,

	-- Multipliers
	priority = { p1 = 1.5, p2 = 1.2, p3 = 1.0 },
	urgency = { day_factor = 0.2, repeat_daily = 1.1 },
	xp_per_hour = 5,

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
	},

	-- Vision quota
	vision_quota = { enabled = true, min_xp = 50 },
}

-- Parse config.zortex file
function M.load_config()
	local config_path = Path:new(vim.g.zortex_notes_dir, "config" .. vim.g.zortex_extension)
	if not config_path:exists() then
		return
	end

	local content = config_path:read()
	local current_section = nil

	for line in content:gmatch("[^\r\n]+") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")

		-- Skip comments and empty lines
		if line:match("^%-%-") or line == "" then
			goto continue
		end

		-- Section headers
		if line:match("^[%w_]+:$") then
			current_section = line:gsub(":$", "")
			if not M.config[current_section] then
				M.config[current_section] = {}
			end
		-- Key-value pairs
		elseif line:match("^%s*[%w_]+:%s*.+") then
			local key, value = line:match("^%s*([%w_]+):%s*(.+)")
			if current_section and M.config[current_section] then
				-- Parse value type
				if value:match("^%d+%.%d+$") then
					value = tonumber(value)
				elseif value:match("^%d+$") then
					value = tonumber(value)
				elseif value == "true" then
					value = true
				elseif value == "false" then
					value = false
				end
				M.config[current_section][key] = value
			end
		end

		::continue::
	end
end

-- Graph building and traversal
M.graph = {
	nodes = {},
	edges = {},
	vision_nodes = {},
	distances = {},
}

-- Parse zortex file and extract metadata
function M.parse_file(filepath)
	local content = Path:new(filepath):read()
	if not content then
		return nil
	end

	local file_data = {
		articles = {},
		current_article = nil,
		tasks = {},
		projects = {},
		objectives = {},
		key_results = {},
		visions = {},
	}

	local current_type = nil
	local current_item = nil

	for line in content:gmatch("[^\r\n]+") do
		-- Article names
		if line:match("^@@") then
			local article_name = line:match("^@@%s*(.+)")
			file_data.current_article = article_name
			table.insert(file_data.articles, article_name)

			-- Detect type from article name
			if article_name:match("Vision") then
				current_type = "vision"
			elseif article_name:match("Objective") then
				current_type = "objective"
			elseif article_name:match("Key Result") or article_name:match("KR") then
				current_type = "key_result"
			elseif article_name:match("Project") then
				current_type = "project"
			end

		-- Tags and metadata
		elseif line:match("^@") and not line:match("^@@") then
			local tag = line:match("^@(.+)")
			if current_item then
				-- Extract metadata
				if tag:match("^p[123]") then
					current_item.priority = tag
				elseif tag:match("^due%((.+)%)") then
					current_item.due = tag:match("^due%((.+)%)")
				elseif tag:match("^(%d+)h") then
					current_item.duration = tonumber(tag:match("^(%d+)h"))
				elseif tag:match("^heat%((.+)%)") then
					current_item.heat = tonumber(tag:match("^heat%((.+)%)"))
				elseif tag:match("^status%((.+)%)") then
					current_item.status = tag:match("^status%((.+)%)")
				elseif tag:match("^repeat%((.+)%)") then
					current_item.repeat_type = tag:match("^repeat%((.+)%)")
				end
			end

		-- Tasks (checkbox items)
		elseif line:match("^%s*%- %[[ x]%]") then
			local completed = line:match("%[x%]") ~= nil
			local task_text = line:match("%- %[.%]%s*(.+)")
			current_item = {
				type = "task",
				text = task_text,
				completed = completed,
				article = file_data.current_article,
				file = filepath,
			}
			table.insert(file_data.tasks, current_item)

		-- Links to parent items
		elseif line:match("%[.+%]") and current_item then
			local link = line:match("%[(.+)%]")
			if not current_item.links then
				current_item.links = {}
			end
			table.insert(current_item.links, link)
		end
	end

	return file_data
end

-- Build graph from all zortex files
function M.build_graph()
	M.graph = { nodes = {}, edges = {}, vision_nodes = {}, distances = {} }

	local notes_dir = vim.g.zortex_notes_dir
	local extension = vim.g.zortex_extension

	-- Find all zortex files
	local files = vim.fn.globpath(notes_dir, "**/*" .. extension, false, true)

	for _, file in ipairs(files) do
		local data = M.parse_file(file)
		if data then
			-- Add nodes to graph
			for _, task in ipairs(data.tasks) do
				local node_id = file .. ":" .. task.text
				M.graph.nodes[node_id] = task

				-- Parse links to find parents
				if task.links then
					for _, link in ipairs(task.links) do
						if not M.graph.edges[node_id] then
							M.graph.edges[node_id] = {}
						end
						table.insert(M.graph.edges[node_id], link)
					end
				end
			end

			-- Track vision nodes
			for _, article in ipairs(data.articles) do
				if article:match("Vision") then
					table.insert(M.graph.vision_nodes, article)
				end
			end
		end
	end

	-- Calculate distances from visions
	M.calculate_distances()
end

-- BFS to calculate minimum distance to any vision
function M.calculate_distances()
	local queue = {}
	local visited = {}

	-- Start from vision nodes with distance 0
	for _, vision in ipairs(M.graph.vision_nodes) do
		table.insert(queue, { node = vision, distance = 0 })
		M.graph.distances[vision] = 0
		visited[vision] = true
	end

	-- BFS traversal
	while #queue > 0 do
		local current = table.remove(queue, 1)

		-- Find all nodes that link to current node
		for node_id, edges in pairs(M.graph.edges) do
			for _, edge in ipairs(edges) do
				if edge == current.node and not visited[node_id] then
					visited[node_id] = true
					M.graph.distances[node_id] = current.distance + 1
					table.insert(queue, { node = node_id, distance = current.distance + 1 })
				end
			end
		end
	end
end

-- Calculate XP for a task
function M.calculate_task_xp(task)
	local node_id = task.file .. ":" .. task.text
	local distance = M.graph.distances[node_id] or math.huge

	-- Base XP calculation
	local xp = M.config.base_xp

	if distance == math.huge then
		xp = M.config.orphan_xp
	else
		xp = xp * math.pow(M.config.distance_decay, distance)
	end

	-- Apply multipliers
	local multiplier = 1.0

	-- Priority multiplier
	if task.priority and M.config.priority[task.priority] then
		multiplier = multiplier * M.config.priority[task.priority]
	end

	-- Urgency multiplier
	if task.due then
		local due_date = M.parse_date(task.due)
		if due_date then
			local days_until = (due_date - os.time()) / 86400
			local urgency = 1 + M.config.urgency.day_factor / (days_until + 1)
			multiplier = multiplier * urgency
		end
	end

	-- Repeat bonus
	if task.repeat_type == "daily" then
		multiplier = multiplier * M.config.urgency.repeat_daily
	end

	-- Apply heat from parent objective
	local heat = M.get_objective_heat(task)
	multiplier = multiplier * heat

	-- Apply project fatigue
	local fatigue = M.get_project_fatigue(task)
	multiplier = multiplier * fatigue

	-- Duration bonus
	if task.duration then
		xp = xp + M.config.xp_per_hour * task.duration
	end

	return math.floor(xp * multiplier)
end

-- Get objective heat for a task
function M.get_objective_heat(task)
	-- Find parent objective through links
	if task.links then
		for _, link in ipairs(task.links) do
			if M.state.objective_heat[link] then
				return M.state.objective_heat[link]
			end
		end
	end
	return M.config.heat.default
end

-- Get project fatigue multiplier
function M.get_project_fatigue(task)
	local project = M.find_parent_project(task)
	if not project then
		return 1.0
	end

	local fatigue_data = M.state.project_fatigue[project]
	if not fatigue_data then
		return 1.0
	end

	local hours_today = fatigue_data.hours_today or 0
	if hours_today > M.config.fatigue.after_hours then
		return M.config.fatigue.penalty
	end

	return 1.0
end

-- Find parent project for a task
function M.find_parent_project(task)
	if task.links then
		for _, link in ipairs(task.links) do
			if link:match("Project") then
				return link
			end
		end
	end
	return nil
end

-- Calculate momentum bonuses
function M.calculate_momentum_bonus(task)
	local bonus = 0
	local now = os.time()
	local today = os.date("%Y-%m-%d")

	-- Streak bonus
	if M.state.last_completion_date == today then
		bonus = bonus + M.config.streak.daily_bonus * M.state.current_streak
	end

	-- Combo bonus
	local project = M.find_parent_project(task)
	if project and M.state.combo.project == project then
		local time_diff = now - M.state.combo.last_time
		if time_diff <= 5400 then -- 90 minutes
			M.state.combo.count = M.state.combo.count + 1
			bonus = bonus + M.config.combo.init + (M.state.combo.count - 1) * M.config.combo.step
		else
			M.state.combo = { project = project, count = 1, last_time = now }
		end
	else
		M.state.combo = { project = project, count = 1, last_time = now }
	end

	-- Cap momentum bonus
	local cap = M.state.daily_xp * M.config.streak.cap_pct_of_day
	return math.min(bonus, cap)
end

-- Complete a task and award XP
function M.complete_task(task)
	-- Calculate XP
	local base_xp = M.calculate_task_xp(task)
	local momentum_bonus = M.calculate_momentum_bonus(task)
	local total_xp = base_xp + momentum_bonus

	-- Update state
	local today = os.date("%Y-%m-%d")
	if M.state.last_completion_date ~= today then
		M.state.daily_xp = 0
		if M.state.last_completion_date == os.date("%Y-%m-%d", os.time() - 86400) then
			M.state.current_streak = M.state.current_streak + 1
		else
			M.state.current_streak = 1
		end
		M.state.last_completion_date = today
	end

	M.state.daily_xp = M.state.daily_xp + total_xp
	M.state.total_xp = M.state.total_xp + total_xp

	-- Update level
	M.state.level = math.floor(math.sqrt(M.state.total_xp / 100))

	-- Check for new badges
	M.check_badges()

	-- Log XP gain
	table.insert(M.state.xp_log, {
		timestamp = os.time(),
		task = task.text,
		xp = total_xp,
		base_xp = base_xp,
		bonus_xp = momentum_bonus,
		level = M.state.level,
	})

	-- Save state
	M.save_state()

	-- Show notification
	M.notify_xp_gain(total_xp, base_xp, momentum_bonus)

	return total_xp
end

-- Check and award badges
function M.check_badges()
	for badge_name, required_xp in pairs(M.config.badges) do
		if M.state.total_xp >= required_xp and not M.state.badges[badge_name] then
			M.state.badges[badge_name] = os.time()
			vim.notify("🏆 Badge Unlocked: " .. badge_name .. "!", "info", { title = "Zortex XP" })
		end
	end
end

-- Notification helper
function M.notify_xp_gain(total, base, bonus)
	local msg = string.format("+%d XP", total)
	if bonus > 0 then
		msg = msg .. string.format(" (base: %d, bonus: %d)", base, bonus)
	end

	-- Add level progress
	local next_level_xp = math.pow(M.state.level + 1, 2) * 100
	local progress = M.state.total_xp / next_level_xp * 100
	msg = msg .. string.format("\nLevel %d (%.1f%% to next)", M.state.level, progress)

	-- Add streak info
	if M.state.current_streak > 1 then
		msg = msg .. string.format("\n🔥 %d day streak!", M.state.current_streak)
	end

	vim.notify(msg, "info", { title = "Zortex XP", timeout = 3000 })
end

-- Save state to disk
function M.save_state()
	local state_path = Path:new(vim.fn.stdpath("data"), "zortex", "xp_state.json")
	state_path:parent():mkdir({ parents = true })
	state_path:write(vim.fn.json_encode(M.state), "w")
end

-- Load state from disk
function M.load_state()
	local state_path = Path:new(vim.fn.stdpath("data"), "zortex", "xp_state.json")
	if state_path:exists() then
		local content = state_path:read()
		if content then
			M.state = vim.fn.json_decode(content)
		end
	end
end

-- Update objective heat (decay over time)
function M.update_objective_heat()
	local current_time = os.time()
	local week_seconds = 7 * 24 * 60 * 60

	for objective, heat_data in pairs(M.state.objective_heat) do
		if type(heat_data) == "table" then
			local weeks_elapsed = (current_time - heat_data.last_update) / week_seconds
			local decay = M.config.heat.decay_per_week * weeks_elapsed
			heat_data.value = math.max(0.1, heat_data.value - decay)
			heat_data.last_update = current_time
		end
	end
end

-- Dashboard command
function M.show_dashboard()
	local lines = {
		"═══════════════════════════════════════",
		"         ZORTEX XP DASHBOARD",
		"═══════════════════════════════════════",
		"",
		string.format("Level: %d", M.state.level),
		string.format("Total XP: %d", M.state.total_xp),
		string.format("Today's XP: %d", M.state.daily_xp),
		string.format("Current Streak: %d days", M.state.current_streak),
		"",
		"Progress to Next Level:",
	}

	-- Level progress bar
	local next_level_xp = math.pow(M.state.level + 1, 2) * 100
	local current_level_xp = math.pow(M.state.level, 2) * 100
	local progress = (M.state.total_xp - current_level_xp) / (next_level_xp - current_level_xp)
	local bar_width = 30
	local filled = math.floor(progress * bar_width)
	local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)
	table.insert(lines, string.format("[%s] %.1f%%", bar, progress * 100))
	table.insert(lines, string.format("%d XP to level %d", next_level_xp - M.state.total_xp, M.state.level + 1))

	-- Badges
	if next(M.state.badges) then
		table.insert(lines, "")
		table.insert(lines, "Badges Earned:")
		for badge, timestamp in pairs(M.state.badges) do
			table.insert(lines, string.format("  🏆 %s - %s", badge, os.date("%Y-%m-%d", timestamp)))
		end
	end

	-- Recent XP gains
	table.insert(lines, "")
	table.insert(lines, "Recent Activity:")
	local recent_count = math.min(5, #M.state.xp_log)
	for i = #M.state.xp_log, #M.state.xp_log - recent_count + 1, -1 do
		if i > 0 then
			local entry = M.state.xp_log[i]
			local time_str = os.date("%H:%M", entry.timestamp)
			table.insert(lines, string.format("  %s: +%d XP - %s", time_str, entry.xp, entry.task))
		end
	end

	-- Vision quota status
	if M.config.vision_quota.enabled then
		local vision_xp_today = M.calculate_vision_xp_today()
		table.insert(lines, "")
		table.insert(lines, string.format("Vision Quota: %d/%d XP", vision_xp_today, M.config.vision_quota.min_xp))
	end

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")

	-- Create window
	local width = 50
	local height = #lines
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
	})

	-- Close on q
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { noremap = true, silent = true })
end

-- Calculate today's XP from vision-aligned tasks
function M.calculate_vision_xp_today()
	local vision_xp = 0
	local today = os.date("%Y-%m-%d")

	for i = #M.state.xp_log, 1, -1 do
		local entry = M.state.xp_log[i]
		if os.date("%Y-%m-%d", entry.timestamp) ~= today then
			break
		end

		-- Check if task is close to vision (distance <= 1)
		-- This would need to be stored in the log entry
		if entry.distance and entry.distance <= 1 then
			vision_xp = vision_xp + entry.xp
		end
	end

	return vision_xp
end

-- Parse date string
function M.parse_date(date_str)
	-- Simple date parser for common formats
	local year, month, day = date_str:match("(%d+)-(%d+)-(%d+)")
	if year then
		return os.time({ year = year, month = month, day = day })
	end
	return nil
end

-- Weekly audit function
function M.audit_tasks()
	local audit_results = {
		orphans = {},
		low_value = {},
		neglected_objectives = {},
	}

	-- Find orphan tasks
	for node_id, node in pairs(M.graph.nodes) do
		local distance = M.graph.distances[node_id]
		if distance == math.huge then
			table.insert(audit_results.orphans, node)
		elseif distance > 3 then
			table.insert(audit_results.low_value, node)
		end
	end

	-- Find neglected objectives
	-- (This would need more sophisticated tracking of objective activity)

	return audit_results
end

-- Setup function
function M.setup(opts)
	opts = opts or {}

	-- Merge user config
	M.config = vim.tbl_deep_extend("force", M.config, opts)

	-- Load config from file
	M.load_config()

	-- Load saved state
	M.load_state()

	-- Build initial graph
	M.build_graph()

	-- Update heat values
	M.update_objective_heat()

	-- Create commands
	vim.api.nvim_create_user_command("ZortexXP", function()
		M.show_dashboard()
	end, { desc = "Show Zortex XP Dashboard" })

	vim.api.nvim_create_user_command("ZortexAudit", function()
		local results = M.audit_tasks()
		vim.notify(
			string.format("Audit Results:\nOrphans: %d\nLow Value: %d", #results.orphans, #results.low_value),
			"info",
			{ title = "Zortex Audit" }
		)
	end, { desc = "Audit tasks for optimization" })

	vim.api.nvim_create_user_command("ZortexRebuildGraph", function()
		M.build_graph()
		vim.notify("Graph rebuilt successfully", "info", { title = "Zortex" })
	end, { desc = "Rebuild the task graph" })

	-- Set up autocmd for task completion
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		pattern = "*" .. vim.g.zortex_extension,
		callback = function()
			-- Check if a task was just completed
			local line = vim.api.nvim_get_current_line()
			if line:match("^%s*%- %[x%]") then
				-- Parse the task
				local task = {
					text = line:match("%- %[x%]%s*(.+)"),
					file = vim.fn.expand("%:p"),
					completed = true,
				}

				-- Award XP
				M.complete_task(task)
			end
		end,
	})

	-- Periodic heat decay
	vim.fn.timer_start(3600000, function() -- Every hour
		M.update_objective_heat()
		M.save_state()
	end, { ["repeat"] = -1 })
end

return M
