-- A comprehensive gamification engine for the Zortex note-taking system

local M = {}

-- Dependencies
local Path = require("plenary.path")
local config = require("zortex.config")

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
	area_xp = {}, -- XP per area for skill trees
	spent_budget = 0, -- Total budget spent
	daily_budget_xp_penalty = 0,
	last_line_states = {}, -- Track line states to detect changes
}

-- Get config from the config module
function M.get_config()
	return config.get("xp") or config.defaults.xp
end

-- Graph building and traversal
M.graph = {
	nodes = {},
	edges = {},
	vision_nodes = {},
	distances = {},
	areas = {}, -- Map of areas to their nodes
}

-- Detect file type from filename
function M.detect_file_type(filepath)
	local filename = vim.fn.fnamemodify(filepath, ":t:r")
	if filename:match("visions") then
		return "visions"
	elseif filename:match("objectives") then
		return "objectives"
	elseif filename:match("keyresults") then
		return "keyresults"
	elseif filename:match("projects") then
		return "projects"
	elseif filename:match("areas") then
		return "areas"
	elseif filename:match("resources") then
		return "resources"
	end
	return "unknown"
end

-- Parse zortex file and extract metadata
function M.parse_file(filepath)
	local content = Path:new(filepath):read()
	if not content then
		return nil
	end

	local file_type = M.detect_file_type(filepath)
	local file_data = {
		type = file_type,
		articles = {},
		current_article = nil,
		tasks = {},
		projects = {},
		objectives = {},
		key_results = {},
		visions = {},
		areas = {},
		items = {}, -- Generic items storage
	}

	local current_item = nil
	local item_lines = 0 -- Track lines for size heuristic
	local in_task = false
	local task_metadata = {} -- Store metadata for the next task

	for line in content:gmatch("[^\r\n]+") do
		-- Article names (headers)
		if line:match("^@@") then
			local article_name = line:match("^@@%s*(.+)")
			file_data.current_article = article_name
			table.insert(file_data.articles, article_name)

			-- Create item based on file type
			if file_type == "visions" then
				current_item = {
					type = "vision",
					name = article_name,
					file = filepath,
					links = {},
				}
				table.insert(file_data.visions, current_item)
			elseif file_type == "objectives" then
				current_item = {
					type = "objective",
					name = article_name,
					file = filepath,
					links = {},
				}
				table.insert(file_data.objectives, current_item)
			elseif file_type == "keyresults" then
				current_item = {
					type = "key_result",
					name = article_name,
					file = filepath,
					links = {},
				}
				table.insert(file_data.key_results, current_item)
			elseif file_type == "projects" then
				current_item = {
					type = "project",
					name = article_name,
					file = filepath,
					links = {},
				}
				table.insert(file_data.projects, current_item)
			elseif file_type == "areas" then
				current_item = {
					type = "area",
					name = article_name,
					file = filepath,
					links = {},
				}
				table.insert(file_data.areas, current_item)
			end

			if current_item then
				table.insert(file_data.items, current_item)
			end

		-- Tags and metadata
		elseif line:match("^@") and not line:match("^@@") then
			local tag = line:match("^@(.+)")
			-- Store metadata for next task
			if tag:match("^p[123]") then
				task_metadata.priority = tag
			elseif tag:match("^due%((.+)%)") then
				task_metadata.due = tag:match("^due%((.+)%)")
			elseif tag:match("^(%d+)h") then
				task_metadata.duration = tonumber(tag:match("^(%d+)h"))
			elseif tag:match("^heat%((.+)%)") then
				task_metadata.heat = tonumber(tag:match("^heat%((.+)%)"))
			elseif tag:match("^status%((.+)%)") then
				task_metadata.status = tag:match("^status%((.+)%)")
			elseif tag:match("^repeat%((.+)%)") then
				task_metadata.repeat_type = tag:match("^repeat%((.+)%)")
			elseif tag:match("^(xs|s|m|l|xl)$") then
				task_metadata.size = tag
			elseif tag:match("^budget%((.+)%)") then
				local amount = tag:match("^budget%(%$?([%d%.]+)%)")
				task_metadata.budget = tonumber(amount)
			end

			-- Also apply to current item if it exists
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
				elseif tag:match("^(xs|s|m|l|xl)$") then
					current_item.size = tag
				elseif tag:match("^budget%((.+)%)") then
					local amount = tag:match("^budget%(%$?([%d%.]+)%)")
					current_item.budget = tonumber(amount)
				end
			end

		-- Tasks (checkbox items)
		elseif line:match("^%s*%- %[[ x]%]") then
			local completed = line:match("%[x%]") ~= nil
			local task_text = line:match("%- %[.%]%s*(.+)")

			-- Apply size heuristic if previous task exists and no size set
			if in_task and current_item and not current_item.size then
				local cfg = M.get_config()
				if item_lines >= cfg.size_thresholds.xl then
					current_item.size = "xl"
				elseif item_lines >= cfg.size_thresholds.l then
					current_item.size = "l"
				end
			end

			current_item = {
				type = "task",
				text = task_text,
				completed = completed,
				article = file_data.current_article,
				file = filepath,
				links = {},
			}

			-- Apply any stored metadata
			for k, v in pairs(task_metadata) do
				current_item[k] = v
			end
			task_metadata = {} -- Clear metadata after use

			table.insert(file_data.tasks, current_item)
			table.insert(file_data.items, current_item)
			item_lines = 1
			in_task = true

		-- Links in brackets
		elseif line:match("%[.+%]") then
			local link = line:match("%[(.+)%]")
			if current_item and current_item.links then
				table.insert(current_item.links, link)
			end
			if in_task then
				item_lines = item_lines + 1
			end

		-- Count lines for task size heuristic
		elseif in_task and line:match("^%s+") then
			item_lines = item_lines + 1
		else
			-- Apply size heuristic when task ends
			if in_task and current_item and not current_item.size then
				local cfg = M.get_config()
				if item_lines >= cfg.size_thresholds.xl then
					current_item.size = "xl"
				elseif item_lines >= cfg.size_thresholds.l then
					current_item.size = "l"
				end
			end
			in_task = false
		end
	end

	-- Apply final size heuristic
	if in_task and current_item and not current_item.size then
		local cfg = M.get_config()
		if item_lines >= cfg.size_thresholds.xl then
			current_item.size = "xl"
		elseif item_lines >= cfg.size_thresholds.l then
			current_item.size = "l"
		end
	end

	return file_data
end

-- Build graph from all zortex files
function M.build_graph()
	M.graph = { nodes = {}, edges = {}, vision_nodes = {}, distances = {}, areas = {} }

	local notes_dir = vim.g.zortex_notes_dir
	local extension = vim.g.zortex_extension

	-- Find all zortex files
	local files = vim.fn.globpath(notes_dir, "**/*" .. extension, false, true)

	for _, file in ipairs(files) do
		local data = M.parse_file(file)
		if data then
			-- Add all items to graph
			for _, item in ipairs(data.items) do
				local node_id = item.name or (item.file .. ":" .. (item.text or ""))
				M.graph.nodes[node_id] = item

				-- Create edges from links
				if item.links then
					M.graph.edges[node_id] = {}
					for _, link in ipairs(item.links) do
						table.insert(M.graph.edges[node_id], link)
					end
				end

				-- Track special node types
				if item.type == "vision" then
					table.insert(M.graph.vision_nodes, node_id)
				elseif item.type == "area" then
					M.graph.areas[item.name] = item
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

-- Find areas for a task by following backlinks
function M.find_task_areas(task)
	local areas = {}
	local visited = {}

	local function traverse(node_id, depth)
		if depth > 5 or visited[node_id] then
			return
		end
		visited[node_id] = true

		local node = M.graph.nodes[node_id]
		if node and node.type == "area" then
			areas[node.name] = true
		end

		-- Check who links to this node
		for parent_id, edges in pairs(M.graph.edges) do
			for _, edge in ipairs(edges) do
				if edge == node_id then
					traverse(parent_id, depth + 1)
				end
			end
		end
	end

	local task_id = task.file .. ":" .. task.text
	traverse(task_id, 0)

	-- Also check direct links
	if task.links then
		for _, link in ipairs(task.links) do
			traverse(link, 0)
		end
	end

	local area_list = {}
	for area, _ in pairs(areas) do
		table.insert(area_list, area)
	end
	return area_list
end

-- Calculate XP for a task
function M.calculate_task_xp(task)
	local cfg = M.get_config()
	local node_id = task.file .. ":" .. task.text
	local distance = M.graph.distances[node_id] or math.huge

	-- Base XP calculation
	local xp = cfg.base_xp

	if distance == math.huge then
		xp = cfg.orphan_xp
	else
		xp = xp * math.pow(cfg.distance_decay, distance)
	end

	-- Apply multipliers
	local multiplier = 1.0

	-- Priority multiplier
	if task.priority and cfg.priority[task.priority] then
		multiplier = multiplier * cfg.priority[task.priority]
	end

	-- Size multiplier
	local size = task.size or "m"
	if cfg.size_multipliers[size] then
		multiplier = multiplier * cfg.size_multipliers[size]
	end

	-- Urgency multiplier
	if task.due then
		local due_date = M.parse_date(task.due)
		if due_date then
			local days_until = (due_date - os.time()) / 86400
			local urgency = 1 + cfg.urgency.day_factor / (days_until + 1)
			multiplier = multiplier * urgency
		end
	end

	-- Repeat bonus
	if task.repeat_type == "daily" then
		multiplier = multiplier * cfg.urgency.repeat_daily
	end

	-- Apply heat from parent objective
	local heat = M.get_objective_heat(task)
	multiplier = multiplier * heat

	-- Apply project fatigue
	local fatigue = M.get_project_fatigue(task)
	multiplier = multiplier * fatigue

	-- Duration bonus
	if task.duration then
		xp = xp + cfg.xp_per_hour * task.duration
	end

	-- Store distance for vision quota tracking
	task.distance = distance

	return math.floor(xp * multiplier)
end

-- Process budget expenses
function M.process_budget(task)
	local cfg = M.get_config()
	if not task.budget or not cfg.budget.enabled then
		return 0
	end

	-- Check if task is linked to exempt areas
	local task_areas = M.find_task_areas(task)
	for _, area in ipairs(task_areas) do
		for _, exempt in ipairs(cfg.budget.exempt_areas) do
			if area == exempt then
				return 0 -- No penalty for exempt areas
			end
		end
	end

	-- Calculate XP penalty
	local penalty = task.budget * cfg.budget.xp_per_dollar
	M.state.spent_budget = M.state.spent_budget + task.budget
	M.state.daily_budget_xp_penalty = M.state.daily_budget_xp_penalty + penalty

	return -penalty
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
	return M.get_config().heat.default
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
	local cfg = M.get_config()
	if hours_today > cfg.fatigue.after_hours then
		return cfg.fatigue.penalty
	end

	return 1.0
end

-- Find parent project for a task
function M.find_parent_project(task)
	if task.links then
		for _, link in ipairs(task.links) do
			local node = M.graph.nodes[link]
			if node and node.type == "project" then
				return link
			end
		end
	end
	return nil
end

-- Calculate momentum bonuses
function M.calculate_momentum_bonus(task)
	local cfg = M.get_config()
	local bonus = 0
	local now = os.time()
	local today = os.date("%Y-%m-%d")

	-- Streak bonus
	if M.state.last_completion_date == today then
		bonus = bonus + cfg.streak.daily_bonus * M.state.current_streak
	end

	-- Combo bonus
	local project = M.find_parent_project(task)
	if project and M.state.combo.project == project then
		local time_diff = now - M.state.combo.last_time
		if time_diff <= 5400 then -- 90 minutes
			M.state.combo.count = M.state.combo.count + 1
			bonus = bonus + cfg.combo.init + (M.state.combo.count - 1) * cfg.combo.step
		else
			M.state.combo = { project = project, count = 1, last_time = now }
		end
	else
		M.state.combo = { project = project, count = 1, last_time = now }
	end

	-- Cap momentum bonus
	local cap = M.state.daily_xp * cfg.streak.cap_pct_of_day
	return math.min(bonus, cap)
end

-- Complete a task and award XP
function M.complete_task(task)
	-- Calculate XP
	local base_xp = M.calculate_task_xp(task)
	local momentum_bonus = M.calculate_momentum_bonus(task)
	local budget_penalty = M.process_budget(task)
	local total_xp = base_xp + momentum_bonus + budget_penalty

	-- Update state
	local today = os.date("%Y-%m-%d")
	if M.state.last_completion_date ~= today then
		M.state.daily_xp = 0
		M.state.daily_budget_xp_penalty = 0
		if M.state.last_completion_date == os.date("%Y-%m-%d", os.time() - 86400) then
			M.state.current_streak = M.state.current_streak + 1
		else
			M.state.current_streak = 1
		end
		M.state.last_completion_date = today
	end

	M.state.daily_xp = M.state.daily_xp + total_xp
	M.state.total_xp = M.state.total_xp + total_xp

	-- Update area XP
	local task_areas = M.find_task_areas(task)
	for _, area in ipairs(task_areas) do
		M.state.area_xp[area] = (M.state.area_xp[area] or 0) + total_xp
	end

	-- Update level (fix the progress calculation)
	M.state.level = math.floor(math.sqrt(M.state.total_xp / 100)) + 1

	-- Check for new badges
	M.check_badges()

	-- Log XP gain
	table.insert(M.state.xp_log, {
		timestamp = os.time(),
		task = task.text,
		xp = total_xp,
		base_xp = base_xp,
		bonus_xp = momentum_bonus,
		budget_penalty = budget_penalty,
		level = M.state.level,
		distance = task.distance,
		areas = task_areas,
		size = task.size,
	})

	-- Save state
	M.save_state()

	-- Show notification
	M.notify_xp_gain(total_xp, base_xp, momentum_bonus, budget_penalty)

	return total_xp
end

-- Check and award badges
function M.check_badges()
	local cfg = M.get_config()
	for badge_name, required_xp in pairs(cfg.badges) do
		if badge_name == "Budget Master" then
			-- Special badge for saving money (negative spending)
			if M.state.spent_budget < -required_xp and not M.state.badges[badge_name] then
				M.state.badges[badge_name] = os.time()
				vim.notify("🏆 Badge Unlocked: " .. badge_name .. "!", "info", { title = "Zortex XP" })
			end
		elseif badge_name == "Area Specialist" then
			-- Award for each area that reaches the threshold
			for area, xp in pairs(M.state.area_xp) do
				local area_badge = badge_name .. " - " .. area
				if xp >= required_xp and not M.state.badges[area_badge] then
					M.state.badges[area_badge] = os.time()
					vim.notify("🏆 Badge Unlocked: " .. area_badge .. "!", "info", { title = "Zortex XP" })
				end
			end
		else
			-- Regular badges
			if M.state.total_xp >= required_xp and not M.state.badges[badge_name] then
				M.state.badges[badge_name] = os.time()
				vim.notify("🏆 Badge Unlocked: " .. badge_name .. "!", "info", { title = "Zortex XP" })
			end
		end
	end
end

-- Notification helper
function M.notify_xp_gain(total, base, bonus, penalty)
	local msg = string.format("+%d XP", total)

	local details = {}
	if base > 0 then
		table.insert(details, string.format("base: %d", base))
	end
	if bonus > 0 then
		table.insert(details, string.format("bonus: %d", bonus))
	end
	if penalty < 0 then
		table.insert(details, string.format("budget: %d", penalty))
	end

	if #details > 0 then
		msg = msg .. " (" .. table.concat(details, ", ") .. ")"
	end

	-- Add level progress (fixed calculation)
	local current_level_xp = math.pow(M.state.level - 1, 2) * 100
	local next_level_xp = math.pow(M.state.level, 2) * 100
	local progress = (M.state.total_xp - current_level_xp) / (next_level_xp - current_level_xp) * 100
	msg = msg .. string.format("\nLevel %d (%.1f%% to next)", M.state.level, progress)

	-- Add streak info
	if M.state.current_streak > 1 then
		msg = msg .. string.format("\n🔥 %d day streak!", M.state.current_streak)
	end

	vim.notify(msg, "info", { title = "Zortex XP", timeout = 3000 })
end

-- Get skill level for an area
function M.get_skill_level(area_xp)
	local cfg = M.get_config()
	for i = #cfg.skill_levels, 1, -1 do
		if area_xp >= cfg.skill_levels[i].xp then
			return cfg.skill_levels[i]
		end
	end
	return cfg.skill_levels[1]
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
			-- Initialize new fields if missing
			M.state.area_xp = M.state.area_xp or {}
			M.state.spent_budget = M.state.spent_budget or 0
			M.state.daily_budget_xp_penalty = M.state.daily_budget_xp_penalty or 0
			M.state.last_line_states = M.state.last_line_states or {}
		end
	end
end

-- Update objective heat (decay over time)
function M.update_objective_heat()
	local cfg = M.get_config()
	local current_time = os.time()
	local week_seconds = 7 * 24 * 60 * 60

	for objective, heat_data in pairs(M.state.objective_heat) do
		if type(heat_data) == "table" then
			local weeks_elapsed = (current_time - heat_data.last_update) / week_seconds
			local decay = cfg.heat.decay_per_week * weeks_elapsed
			heat_data.value = math.max(0.1, heat_data.value - decay)
			heat_data.last_update = current_time
		end
	end
end

-- Dashboard command
function M.show_dashboard()
	local cfg = M.get_config()
	local lines = {
		"═══════════════════════════════════════════════════════",
		"              ZORTEX XP DASHBOARD",
		"═══════════════════════════════════════════════════════",
		"",
		string.format("Level: %d", M.state.level),
		string.format("Total XP: %d", M.state.total_xp),
		string.format("Today's XP: %d", M.state.daily_xp),
		string.format("Current Streak: %d days", M.state.current_streak),
	}

	-- Budget status
	if cfg.budget.enabled then
		table.insert(lines, string.format("Daily Budget Impact: %d XP", -M.state.daily_budget_xp_penalty))
		table.insert(lines, string.format("Total Spent: $%.2f", M.state.spent_budget))
	end

	table.insert(lines, "")
	table.insert(lines, "Progress to Next Level:")

	-- Level progress bar (fixed calculation)
	local current_level_xp = math.pow(M.state.level - 1, 2) * 100
	local next_level_xp = math.pow(M.state.level, 2) * 100
	local progress = (M.state.total_xp - current_level_xp) / (next_level_xp - current_level_xp)
	local bar_width = 40
	local filled = math.floor(progress * bar_width)
	local bar = string.rep("█", filled) .. string.rep("░", bar_width - filled)
	table.insert(lines, string.format("[%s] %.1f%%", bar, progress * 100))
	table.insert(lines, string.format("%d XP to level %d", next_level_xp - M.state.total_xp, M.state.level + 1))

	-- Skill Trees
	if next(M.state.area_xp) then
		table.insert(lines, "")
		table.insert(lines, "Skill Trees:")
		for area, xp in pairs(M.state.area_xp) do
			local level = M.get_skill_level(xp)
			local next_level = nil
			for i, l in ipairs(cfg.skill_levels) do
				if l.name == level.name and i < #cfg.skill_levels then
					next_level = cfg.skill_levels[i + 1]
					break
				end
			end

			if next_level then
				local progress = (xp - level.xp) / (next_level.xp - level.xp) * 100
				table.insert(
					lines,
					string.format("  %s: %s (%.0f%% to %s)", area, level.name, progress, next_level.name)
				)
			else
				table.insert(lines, string.format("  %s: %s (MAX)", area, level.name))
			end
		end
	end

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
			local size_str = entry.size and (" [" .. entry.size .. "]") or ""
			table.insert(lines, string.format("  %s: +%d XP - %s%s", time_str, entry.xp, entry.task, size_str))
		end
	end

	-- Vision quota status
	if cfg.vision_quota.enabled then
		local vision_xp_today = M.calculate_vision_xp_today()
		table.insert(lines, "")
		table.insert(lines, string.format("Vision Quota: %d/%d XP", vision_xp_today, cfg.vision_quota.min_xp))
	end

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")

	-- Create window
	local width = 60
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

-- Enhanced analytics dashboard
function M.show_analytics()
	local lines = {
		"═══════════════════════════════════════════════════════",
		"          ZORTEX ANALYTICS & DEBUG",
		"═══════════════════════════════════════════════════════",
		"",
		"Graph Statistics:",
		string.format("  Total Nodes: %d", vim.tbl_count(M.graph.nodes)),
		string.format("  Vision Nodes: %d", #M.graph.vision_nodes),
		string.format("  Area Nodes: %d", vim.tbl_count(M.graph.areas)),
		"",
		"Node Type Distribution:",
	}

	-- Count node types
	local type_counts = {}
	for _, node in pairs(M.graph.nodes) do
		local node_type = node.type or "unknown"
		type_counts[node_type] = (type_counts[node_type] or 0) + 1
	end

	for node_type, count in pairs(type_counts) do
		table.insert(lines, string.format("  %s: %d", node_type, count))
	end

	-- Distance distribution
	table.insert(lines, "")
	table.insert(lines, "Distance from Vision Distribution:")
	local distance_counts = {}
	local orphan_count = 0
	for _, distance in pairs(M.graph.distances) do
		if distance == math.huge then
			orphan_count = orphan_count + 1
		else
			distance_counts[distance] = (distance_counts[distance] or 0) + 1
		end
	end

	for i = 0, 5 do
		if distance_counts[i] then
			table.insert(lines, string.format("  Distance %d: %d nodes", i, distance_counts[i]))
		end
	end
	table.insert(lines, string.format("  Orphans: %d nodes", orphan_count))

	-- XP by day
	table.insert(lines, "")
	table.insert(lines, "Daily XP (Last 7 Days):")
	local daily_xp = {}
	for _, entry in ipairs(M.state.xp_log) do
		local date = os.date("%Y-%m-%d", entry.timestamp)
		daily_xp[date] = (daily_xp[date] or 0) + entry.xp
	end

	for i = 6, 0, -1 do
		local date = os.date("%Y-%m-%d", os.time() - i * 86400)
		local xp = daily_xp[date] or 0
		table.insert(lines, string.format("  %s: %d XP", date, xp))
	end

	-- Size distribution
	table.insert(lines, "")
	table.insert(lines, "Task Size Distribution:")
	local size_counts = {}
	for _, entry in ipairs(M.state.xp_log) do
		local size = entry.size or "m"
		size_counts[size] = (size_counts[size] or 0) + 1
	end

	for _, size in ipairs({ "xs", "s", "m", "l", "xl" }) do
		local count = size_counts[size] or 0
		table.insert(lines, string.format("  %s: %d tasks", size, count))
	end

	-- Area activity
	table.insert(lines, "")
	table.insert(lines, "Area Activity (Last 30 Days):")
	local area_recent = {}
	local thirty_days_ago = os.time() - 30 * 86400
	for _, entry in ipairs(M.state.xp_log) do
		if entry.timestamp > thirty_days_ago and entry.areas then
			for _, area in ipairs(entry.areas) do
				area_recent[area] = (area_recent[area] or 0) + 1
			end
		end
	end

	for area, count in pairs(area_recent) do
		table.insert(lines, string.format("  %s: %d tasks", area, count))
	end

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")

	-- Create window
	local width = 60
	local height = math.min(#lines, 40)
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
	local cfg = M.get_config()
	local vision_xp = 0
	local today = os.date("%Y-%m-%d")

	for i = #M.state.xp_log, 1, -1 do
		local entry = M.state.xp_log[i]
		if os.date("%Y-%m-%d", entry.timestamp) ~= today then
			break
		end

		-- Check if task is close to vision (distance <= 1)
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
		missing_sizes = {},
		missing_budgets = {},
	}

	-- Audit all nodes
	for node_id, node in pairs(M.graph.nodes) do
		local distance = M.graph.distances[node_id]

		-- Find orphans
		if distance == math.huge then
			table.insert(audit_results.orphans, node)
		elseif distance > 3 then
			table.insert(audit_results.low_value, node)
		end

		-- Check for missing metadata
		if node.type == "task" then
			if not node.size then
				table.insert(audit_results.missing_sizes, node)
			end
			-- Tasks with certain keywords should have budgets
			if
				node.text
				and (node.text:match("buy") or node.text:match("purchase") or node.text:match("pay"))
				and not node.budget
			then
				table.insert(audit_results.missing_budgets, node)
			end
		end
	end

	-- Find neglected objectives (no recent activity)
	local objective_activity = {}
	local seven_days_ago = os.time() - 7 * 86400

	for _, entry in ipairs(M.state.xp_log) do
		if entry.timestamp > seven_days_ago then
			-- Track activity through links
			local task = M.graph.nodes[entry.task]
			if task and task.links then
				for _, link in ipairs(task.links) do
					objective_activity[link] = true
				end
			end
		end
	end

	for node_id, node in pairs(M.graph.nodes) do
		if node.type == "objective" and not objective_activity[node_id] then
			table.insert(audit_results.neglected_objectives, node)
		end
	end

	return audit_results
end

-- Check if task was completed in the current buffer
function M.check_task_completion()
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_get_current_line()
	local buf = vim.api.nvim_get_current_buf()
	local filepath = vim.fn.expand("%:p")

	-- Create unique key for this line
	local line_key = string.format("%s:%d", filepath, line_num)

	-- Check if this is a task line
	if line:match("^%s*%- %[[ x]%]") then
		local is_completed = line:match("%[x%]") ~= nil
		local was_completed = M.state.last_line_states[line_key] or false

		-- Task was just completed (changed from [ ] to [x])
		if is_completed and not was_completed then
			-- Rebuild graph to ensure we have latest data
			M.build_graph()

			-- Parse the current file to get full task context
			local file_data = M.parse_file(filepath)

			if file_data then
				-- Find the matching task
				local task_text = line:match("%- %[x%]%s*(.+)")
				for _, task in ipairs(file_data.tasks) do
					if task.text == task_text and task.completed then
						-- Award XP
						M.complete_task(task)
						break
					end
				end
			end
		end

		-- Update state
		M.state.last_line_states[line_key] = is_completed
	end
end

-- Setup function
function M.setup()
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

	vim.api.nvim_create_user_command("ZortexAnalytics", function()
		M.show_analytics()
	end, { desc = "Show Zortex Analytics & Debug" })

	vim.api.nvim_create_user_command("ZortexAudit", function()
		local results = M.audit_tasks()
		local msg = string.format(
			"Audit Results:\nOrphans: %d\nLow Value: %d\nNeglected Objectives: %d\nMissing Sizes: %d\nMissing Budgets: %d",
			#results.orphans,
			#results.low_value,
			#results.neglected_objectives,
			#results.missing_sizes,
			#results.missing_budgets
		)
		vim.notify(msg, "info", { title = "Zortex Audit" })
	end, { desc = "Audit tasks for optimization" })

	vim.api.nvim_create_user_command("ZortexRebuildGraph", function()
		M.build_graph()
		vim.notify("Graph rebuilt successfully", "info", { title = "Zortex" })
	end, { desc = "Rebuild the task graph" })

	-- More robust autocmd for task completion
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
		pattern = "*" .. vim.g.zortex_extension,
		callback = function()
			-- Defer the check slightly to ensure the buffer is updated
			vim.defer_fn(function()
				M.check_task_completion()
			end, 50)
		end,
	})

	-- Also check on cursor movement (in case user uses visual mode to change)
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		pattern = "*" .. vim.g.zortex_extension,
		callback = function()
			M.check_task_completion()
		end,
	})

	-- Periodic heat decay
	vim.fn.timer_start(3600000, function() -- Every hour
		M.update_objective_heat()
		M.save_state()
	end, { ["repeat"] = -1 })
end

return M
