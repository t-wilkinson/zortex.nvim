-- User interface for Zortex XP system
local M = {}

-- Show XP gain notification
function M.notify_xp_gain(breakdown)
	local msg = string.format("+%d XP", breakdown.total)

	-- Add breakdown details
	local details = {}

	if breakdown.base > 0 then
		table.insert(details, string.format("base: %d", breakdown.base))
	end

	if breakdown.bonuses.total > 0 then
		local bonus_parts = {}
		for name, amount in pairs(breakdown.bonuses) do
			if name ~= "total" and amount > 0 then
				table.insert(bonus_parts, string.format("%s: %d", name, amount))
			end
		end
		if #bonus_parts > 0 then
			table.insert(details, "bonus: " .. table.concat(bonus_parts, ", "))
		end
	end

	if breakdown.penalties.total > 0 then
		table.insert(details, string.format("penalties: -%d", breakdown.penalties.total))
	end

	if #details > 0 then
		msg = msg .. " (" .. table.concat(details, ", ") .. ")"
	end

	-- Add level progress
	local state = require("zortex.xp.state")
	local level_progress = M.get_level_progress()
	msg = msg .. string.format("\nLevel %d (%.1f%% to next)", state.data.level, level_progress)

	-- Add streak info
	if state.data.current_streak > 1 then
		msg = msg .. string.format("\n🔥 %d day streak!", state.data.current_streak)
	end

	vim.notify(msg, "info", { title = "Zortex XP", timeout = 3000 })
end

-- Show main dashboard
function M.show_dashboard()
	local state = require("zortex.xp.state")
	local tracker = require("zortex.xp.tracker")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	local lines = {
		"═══════════════════════════════════════════════════════",
		"                  ZORTEX XP DASHBOARD",
		"═══════════════════════════════════════════════════════",
		"",
		string.format("Level: %d", state.data.level),
		string.format("Total XP: %d", state.data.total_xp),
		string.format("Today's XP: %d", state.data.daily_xp),
		string.format("Current Streak: %d days", state.data.current_streak),
	}

	-- Budget status
	if cfg.budget.enabled then
		table.insert(lines, "")
		table.insert(lines, "Budget:")
		table.insert(lines, string.format("  Spent Today: $%.2f", state.data.budget.spent_today))
		table.insert(lines, string.format("  Total Saved: $%.2f", state.data.budget.saved_total))
	end

	-- Level progress
	table.insert(lines, "")
	table.insert(lines, "Progress to Next Level:")
	local progress_bar = M.create_progress_bar(M.get_level_progress(), 40)
	table.insert(lines, progress_bar)

	-- Skill trees
	if next(state.data.area_xp) then
		table.insert(lines, "")
		table.insert(lines, "Skill Trees:")

		for area, xp in pairs(state.data.area_xp) do
			local skill_info = M.get_skill_info(area, xp)
			table.insert(lines, string.format("  %s: %s", area, skill_info))
		end
	end

	-- Vision quota
	local quota = tracker.get_vision_quota_status()
	if quota then
		table.insert(lines, "")
		table.insert(
			lines,
			string.format("Vision Quota: %d/%d XP %s", quota.current, quota.required, quota.met and "✓" or "✗")
		)
	end

	-- Recent activity
	table.insert(lines, "")
	table.insert(lines, "Recent Activity:")
	M.add_recent_activity(lines)

	-- Badges
	if next(state.data.badges) then
		table.insert(lines, "")
		table.insert(lines, "Badges Earned:")
		for badge, timestamp in pairs(state.data.badges) do
			table.insert(lines, string.format("  🏆 %s - %s", badge, os.date("%Y-%m-%d", timestamp)))
		end
	end

	-- Commands help
	table.insert(lines, "")
	table.insert(lines, "Commands:")
	table.insert(lines, "  :ZortexAnalytics - View detailed analytics")
	table.insert(lines, "  :ZortexHabits    - View habit tracker")
	table.insert(lines, "  :ZortexBudget    - View budget details")
	table.insert(lines, "  :ZortexAudit     - Audit tasks")
	table.insert(lines, "  q                - Close dashboard")

	M.show_buffer(lines, "Zortex XP Dashboard")
end

-- Show analytics
function M.show_analytics()
	local state = require("zortex.xp.state")
	local graph = require("zortex.xp.graph")

	local stats = graph.get_stats()

	local lines = {
		"═══════════════════════════════════════════════════════",
		"             ZORTEX ANALYTICS & DEBUG",
		"═══════════════════════════════════════════════════════",
		"",
		"Graph Statistics:",
		string.format("  Total Nodes: %d", stats.total_nodes),
		string.format("  Vision Nodes: %d", stats.vision_nodes),
		string.format("  Area Nodes: %d", stats.area_nodes),
		string.format("  Orphan Nodes: %d", stats.orphan_nodes),
		"",
		"Node Type Distribution:",
	}

	-- Add type counts
	for node_type, count in pairs(stats.type_counts) do
		table.insert(lines, string.format("  %s: %d", node_type, count))
	end

	-- Distance distribution
	table.insert(lines, "")
	table.insert(lines, "Distance from Vision:")
	for distance = 0, 5 do
		local count = stats.distance_distribution[distance] or 0
		if count > 0 then
			table.insert(lines, string.format("  Distance %d: %d nodes", distance, count))
		end
	end

	-- Daily XP chart
	table.insert(lines, "")
	table.insert(lines, "Daily XP (Last 7 Days):")
	M.add_daily_xp_chart(lines)

	-- Task size distribution
	table.insert(lines, "")
	table.insert(lines, "Task Size Distribution:")
	M.add_size_distribution(lines)

	-- Area activity
	table.insert(lines, "")
	table.insert(lines, "Area Activity (Last 30 Days):")
	M.add_area_activity(lines)

	M.show_buffer(lines, "Zortex Analytics")
end

-- Show habit tracker
function M.show_habits()
	local state = require("zortex.xp.state")
	local lines = {
		"═══════════════════════════════════════════════════════",
		"                 HABIT TRACKER",
		"═══════════════════════════════════════════════════════",
		"",
	}

	-- Daily habits
	if next(state.data.habits.daily) then
		table.insert(lines, "Daily Habits:")
		for habit_id, habit in pairs(state.data.habits.daily) do
			local status = habit.completed_today and "✓" or "○"
			local chain = habit.current_chain or 0
			table.insert(
				lines,
				string.format("  %s %s (Chain: %d, Best: %d)", status, habit_id, chain, habit.best_chain or 0)
			)
		end
		table.insert(lines, "")
	end

	-- Weekly habits
	if next(state.data.habits.weekly) then
		table.insert(lines, "Weekly Habits:")
		for habit_id, habit in pairs(state.data.habits.weekly) do
			local status = habit.completed_this_week and "✓" or "○"
			table.insert(lines, string.format("  %s %s (Total: %d)", status, habit_id, habit.total_completions or 0))
		end
		table.insert(lines, "")
	end

	-- Monthly habits
	if next(state.data.habits.monthly) then
		table.insert(lines, "Monthly Habits:")
		for habit_id, habit in pairs(state.data.habits.monthly) do
			local status = habit.completed_this_month and "✓" or "○"
			table.insert(lines, string.format("  %s %s (Total: %d)", status, habit_id, habit.total_completions or 0))
		end
	end

	M.show_buffer(lines, "Habit Tracker")
end

-- Show budget details
function M.show_budget()
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	local lines = {
		"═══════════════════════════════════════════════════════",
		"                 BUDGET TRACKER",
		"═══════════════════════════════════════════════════════",
		"",
		string.format("Today's Spending: $%.2f", state.data.budget.spent_today),
		string.format("Total Spent: $%.2f", state.data.budget.spent_total),
		string.format("Total Saved: $%.2f", state.data.budget.saved_total),
		"",
		"Category Breakdown:",
	}

	-- Category spending
	for category, amount in pairs(state.data.budget.category_spending) do
		table.insert(lines, string.format("  %s: $%.2f", category, amount))
	end

	-- Savings milestones
	if cfg.budget.savings_milestones then
		table.insert(lines, "")
		table.insert(lines, "Savings Milestones:")

		for amount, xp_reward in pairs(cfg.budget.savings_milestones) do
			local achieved = state.data.budget.saved_total >= amount
			local status = achieved and "✓" or "○"
			table.insert(lines, string.format("  %s $%d - %d XP", status, amount, xp_reward))
		end
	end

	M.show_buffer(lines, "Budget Tracker")
end

-- Show resources
function M.show_resources()
	local state = require("zortex.xp.state")
	local lines = {
		"═══════════════════════════════════════════════════════",
		"                RESOURCE TRACKER",
		"═══════════════════════════════════════════════════════",
		"",
	}

	-- Created resources
	if next(state.data.resources.created) then
		table.insert(lines, "Created:")
		for resource, amount in pairs(state.data.resources.created) do
			table.insert(lines, string.format("  %s: %d", resource, amount))
		end
		table.insert(lines, "")
	end

	-- Consumed resources
	if next(state.data.resources.consumed) then
		table.insert(lines, "Consumed:")
		for resource, amount in pairs(state.data.resources.consumed) do
			table.insert(lines, string.format("  %s: %d", resource, amount))
		end
		table.insert(lines, "")
	end

	-- Shared resources
	if next(state.data.resources.shared) then
		table.insert(lines, "Shared:")
		for resource, amount in pairs(state.data.resources.shared) do
			table.insert(lines, string.format("  %s: %d", resource, amount))
		end
	end

	M.show_buffer(lines, "Resource Tracker")
end

-- Helper functions

function M.get_level_progress()
	local state = require("zortex.xp.state")
	local current_level_xp = math.pow(state.data.level - 1, 2) * 100
	local next_level_xp = math.pow(state.data.level, 2) * 100
	return (state.data.total_xp - current_level_xp) / (next_level_xp - current_level_xp) * 100
end

function M.create_progress_bar(percentage, width)
	local filled = math.floor(percentage * width / 100)
	local empty = width - filled
	local bar = string.rep("█", filled) .. string.rep("░", empty)
	return string.format("[%s] %.1f%%", bar, percentage)
end

function M.get_skill_info(area, xp)
	local xp_mod = require("zortex.xp")
	local cfg = xp_mod.get_config()

	-- Find current and next skill level
	local current_level = nil
	local next_level = nil

	for i = #cfg.skill_levels, 1, -1 do
		if xp >= cfg.skill_levels[i].xp then
			current_level = cfg.skill_levels[i]
			if i < #cfg.skill_levels then
				next_level = cfg.skill_levels[i + 1]
			end
			break
		end
	end

	if not current_level then
		current_level = cfg.skill_levels[1]
		next_level = cfg.skill_levels[2]
	end

	if next_level then
		local progress = (xp - current_level.xp) / (next_level.xp - current_level.xp) * 100
		return string.format("%s (%.0f%% to %s)", current_level.name, progress, next_level.name)
	else
		return string.format("%s (MAX)", current_level.name)
	end
end

function M.add_recent_activity(lines)
	local state = require("zortex.xp.state")
	local recent_count = math.min(5, #state.data.xp_log)

	for i = #state.data.xp_log, #state.data.xp_log - recent_count + 1, -1 do
		if i > 0 then
			local entry = state.data.xp_log[i]
			local time_str = os.date("%H:%M", entry.timestamp)
			local size_str = entry.size and (" [" .. entry.size .. "]") or ""
			local task_text = entry.task
			if #task_text > 40 then
				task_text = task_text:sub(1, 37) .. "..."
			end
			table.insert(lines, string.format("  %s: +%d XP - %s%s", time_str, entry.xp, task_text, size_str))
		end
	end
end

function M.add_daily_xp_chart(lines)
	local state = require("zortex.xp.state")
	local daily_xp = {}

	-- Aggregate XP by day
	for _, entry in ipairs(state.data.xp_log) do
		local date = os.date("%Y-%m-%d", entry.timestamp)
		daily_xp[date] = (daily_xp[date] or 0) + entry.xp
	end

	-- Show last 7 days
	for i = 6, 0, -1 do
		local date = os.date("%Y-%m-%d", os.time() - i * 86400)
		local xp = daily_xp[date] or 0
		local bar = M.create_mini_bar(xp, 500, 20)
		table.insert(lines, string.format("  %s: %s %d XP", date, bar, xp))
	end
end

function M.create_mini_bar(value, max_value, width)
	local percentage = math.min(100, value / max_value * 100)
	local filled = math.floor(percentage * width / 100)
	return string.rep("▮", filled) .. string.rep("▯", width - filled)
end

function M.add_size_distribution(lines)
	local state = require("zortex.xp.state")
	local size_counts = {}
	local total = 0

	for _, entry in ipairs(state.data.xp_log) do
		local size = entry.size or "m"
		size_counts[size] = (size_counts[size] or 0) + 1
		total = total + 1
	end

	for _, size in ipairs({ "xs", "s", "m", "l", "xl" }) do
		local count = size_counts[size] or 0
		local percentage = total > 0 and (count / total * 100) or 0
		table.insert(lines, string.format("  %s: %d (%.1f%%)", size, count, percentage))
	end
end

function M.add_area_activity(lines)
	local state = require("zortex.xp.state")
	local area_activity = {}
	local thirty_days_ago = os.time() - 30 * 86400

	for _, entry in ipairs(state.data.xp_log) do
		if entry.timestamp > thirty_days_ago and entry.areas then
			for _, area in ipairs(entry.areas) do
				area_activity[area] = (area_activity[area] or 0) + 1
			end
		end
	end

	-- Sort by activity
	local sorted_areas = {}
	for area, count in pairs(area_activity) do
		table.insert(sorted_areas, { area = area, count = count })
	end
	table.sort(sorted_areas, function(a, b)
		return a.count > b.count
	end)

	-- Show top areas
	for i = 1, math.min(5, #sorted_areas) do
		local item = sorted_areas[i]
		table.insert(lines, string.format("  %s: %d tasks", item.area, item.count))
	end
end

function M.show_buffer(lines, title)
	-- Create buffer (check for existing first)
	local buf = nil

	-- Try to find existing buffer with this title
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) then
			local name = vim.api.nvim_buf_get_name(b)
			if name:match(title) then
				-- Reuse existing buffer
				buf = b
				vim.api.nvim_buf_set_option(buf, "modifiable", true)
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
				break
			end
		end
	end

	-- Create new buffer if needed
	if not buf then
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, title)
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")

	-- Calculate window size
	local width = 60
	local height = math.min(#lines, 40)

	-- Create window
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
	})

	-- Keymaps
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { noremap = true, silent = true, desc = "Close window" })
	vim.api.nvim_buf_set_keymap(
		buf,
		"n",
		"<Esc>",
		":close<CR>",
		{ noremap = true, silent = true, desc = "Close window" }
	)
end

return M
