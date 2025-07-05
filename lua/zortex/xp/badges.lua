-- Badge system for Zortex XP
local M = {}

-- Check all badges
function M.check_all()
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	-- XP-based badges
	M.check_xp_badges(cfg.badges)

	-- Streak badges
	M.check_streak_badges()

	-- Area specialist badges
	M.check_area_badges()

	-- Budget badges
	M.check_budget_badges()

	-- Habit badges
	M.check_habit_badges()

	-- Resource badges
	M.check_resource_badges()

	-- Custom badges
	M.check_custom_badges()
end

-- Check XP-based badges
function M.check_xp_badges(badge_config)
	local state = require("zortex.xp.state")

	for badge_name, required_xp in pairs(badge_config or {}) do
		if type(required_xp) == "number" and state.data.total_xp >= required_xp then
			if state.award_badge(badge_name) then
				M.notify_badge(badge_name, "Reached " .. required_xp .. " total XP!")
			end
		end
	end
end

-- Check streak badges
function M.check_streak_badges()
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	local streak_badges = {
		["Week Warrior"] = 7,
		["Fortnight Fighter"] = 14,
		["Monthly Master"] = 30,
		["Quarterly Quest"] = 90,
		["Yearly Yoda"] = 365,
	}

	for badge_name, days in pairs(streak_badges) do
		if state.data.current_streak >= days then
			if state.award_badge(badge_name) then
				M.notify_badge(badge_name, days .. " day streak!")
			end
		end
	end
end

-- Check area specialist badges
function M.check_area_badges()
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	local area_threshold = cfg.badges["Area Specialist"] or 1000

	for area, xp_amount in pairs(state.data.area_xp) do
		if xp_amount >= area_threshold then
			local badge_name = "Area Specialist - " .. area
			if state.award_badge(badge_name) then
				M.notify_badge(badge_name, "Mastered " .. area .. " area!")
			end
		end

		-- Check for max level in area
		local skill_level = M.get_area_skill_level(area, xp_amount)
		if skill_level and skill_level.name == "Master" then
			local master_badge = "Master of " .. area
			if state.award_badge(master_badge) then
				M.notify_badge(master_badge, "Achieved mastery in " .. area .. "!")
			end
		end
	end
end

-- Check budget badges
function M.check_budget_badges()
	local state = require("zortex.xp.state")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	-- Savings badges
	local savings_badges = {
		["Penny Pincher"] = 100,
		["Savings Starter"] = 500,
		["Budget Boss"] = 1000,
		["Financial Freedom"] = 5000,
		["Wealth Warrior"] = 10000,
	}

	for badge_name, amount in pairs(savings_badges) do
		if state.data.budget.saved_total >= amount then
			if state.award_badge(badge_name) then
				M.notify_badge(badge_name, "Saved $" .. amount .. "!")
			end
		end
	end

	-- No-spend streak badges
	if state.data.budget.spent_today == 0 then
		local no_spend_days = M.calculate_no_spend_days()

		local no_spend_badges = {
			["No Spend Day"] = 1,
			["Frugal Week"] = 7,
			["Thrifty Month"] = 30,
		}

		for badge_name, days in pairs(no_spend_badges) do
			if no_spend_days >= days then
				local unique_badge = badge_name .. " - " .. os.date("%Y-%m")
				if state.award_badge(unique_badge) then
					M.notify_badge(badge_name, days .. " days without spending!")
				end
			end
		end
	end
end

-- Check habit badges
function M.check_habit_badges()
	local state = require("zortex.xp.state")

	-- Check each habit type
	for frequency, habits in pairs(state.data.habits) do
		for habit_id, habit_data in pairs(habits) do
			-- Chain badges
			local chain_badges = {
				["Habit Starter"] = 7,
				["Habit Builder"] = 30,
				["Habit Master"] = 100,
			}

			for badge_name, required_chain in pairs(chain_badges) do
				if habit_data.current_chain >= required_chain then
					local unique_badge = badge_name .. " - " .. habit_id
					if state.award_badge(unique_badge) then
						M.notify_badge(badge_name, habit_id .. " chain of " .. required_chain .. "!")
					end
				end
			end

			-- Total completion badges
			local completion_badges = {
				["Consistent"] = 10,
				["Dedicated"] = 50,
				["Unstoppable"] = 100,
			}

			for badge_name, required_completions in pairs(completion_badges) do
				if habit_data.total_completions >= required_completions then
					local unique_badge = badge_name .. " - " .. habit_id
					if state.award_badge(unique_badge) then
						M.notify_badge(badge_name, habit_id .. " completed " .. required_completions .. " times!")
					end
				end
			end
		end
	end
end

-- Check resource badges
function M.check_resource_badges()
	local state = require("zortex.xp.state")

	-- Creator badges
	local total_created = 0
	for _, amount in pairs(state.data.resources.created) do
		total_created = total_created + amount
	end

	local creator_badges = {
		["Resource Creator"] = 10,
		["Prolific Producer"] = 50,
		["Creation Machine"] = 100,
	}

	for badge_name, required in pairs(creator_badges) do
		if total_created >= required then
			if state.award_badge(badge_name) then
				M.notify_badge(badge_name, "Created " .. required .. " resources!")
			end
		end
	end

	-- Sharing badges
	local total_shared = 0
	for _, amount in pairs(state.data.resources.shared) do
		total_shared = total_shared + amount
	end

	local sharing_badges = {
		["Generous"] = 5,
		["Community Builder"] = 25,
		["Sharing Superstar"] = 50,
	}

	for badge_name, required in pairs(sharing_badges) do
		if total_shared >= required then
			if state.award_badge(badge_name) then
				M.notify_badge(badge_name, "Shared " .. required .. " resources!")
			end
		end
	end
end

-- Check custom badges
function M.check_custom_badges()
	local state = require("zortex.xp.state")

	-- Early bird badge (complete task before 7 AM)
	local hour = tonumber(os.date("%H"))
	if hour < 7 and state.data.daily_xp > 0 then
		local badge_name = "Early Bird - " .. os.date("%Y-%m-%d")
		if state.award_badge(badge_name) then
			M.notify_badge("Early Bird", "Completed tasks before 7 AM!")
		end
	end

	-- Night owl badge (complete task after 11 PM)
	if hour >= 23 and state.data.daily_xp > 0 then
		local badge_name = "Night Owl - " .. os.date("%Y-%m-%d")
		if state.award_badge(badge_name) then
			M.notify_badge("Night Owl", "Completed tasks after 11 PM!")
		end
	end

	-- Productive day badges
	local productivity_badges = {
		["Productive Day"] = 100,
		["Super Productive"] = 250,
		["Ultra Productive"] = 500,
		["Legendary Day"] = 1000,
	}

	for badge_name, required_xp in pairs(productivity_badges) do
		if state.data.daily_xp >= required_xp then
			local unique_badge = badge_name .. " - " .. os.date("%Y-%m-%d")
			if state.award_badge(unique_badge) then
				M.notify_badge(badge_name, "Earned " .. required_xp .. " XP today!")
			end
		end
	end

	-- Vision alignment badge
	local tracker = require("zortex.xp.tracker")
	local quota = tracker.get_vision_quota_status()
	if quota and quota.met then
		local badge_name = "Vision Aligned - " .. os.date("%Y-%m-%d")
		if state.award_badge(badge_name) then
			M.notify_badge("Vision Aligned", "Met daily vision quota!")
		end
	end

	-- Zero inbox badge (all tasks completed in a file)
	M.check_zero_inbox_badge()

	-- Comeback badge (return after missing days)
	M.check_comeback_badge()
end

-- Helper functions

function M.notify_badge(badge_name, description)
	local msg = "🏆 Badge Unlocked: " .. badge_name
	if description then
		msg = msg .. "\n" .. description
	end

	vim.notify(msg, "info", {
		title = "Zortex XP",
		timeout = 5000,
		icon = "🏆",
	})

	-- Play sound if available (optional)
	if vim.fn.executable("afplay") == 1 then
		vim.fn.system("afplay /System/Library/Sounds/Glass.aiff &")
	end
end

function M.get_area_skill_level(area, xp)
	local xp_mod = require("zortex.xp")
	local cfg = xp_mod.get_config()

	for i = #cfg.skill_levels, 1, -1 do
		if xp >= cfg.skill_levels[i].xp then
			return cfg.skill_levels[i]
		end
	end

	return cfg.skill_levels[1]
end

function M.calculate_no_spend_days()
	local state = require("zortex.xp.state")
	local days = 0
	local today = os.date("%Y-%m-%d")

	-- Look through recent XP log for spending
	for i = #state.data.xp_log, 1, -1 do
		local entry = state.data.xp_log[i]
		local entry_date = os.date("%Y-%m-%d", entry.timestamp)

		if entry_date ~= today then
			-- Different day, check if had spending
			local had_spending = false

			-- Check all entries for that day
			for j = i, 1, -1 do
				local check_entry = state.data.xp_log[j]
				local check_date = os.date("%Y-%m-%d", check_entry.timestamp)

				if check_date ~= entry_date then
					break
				end

				if
					check_entry.breakdown
					and check_entry.breakdown.penalties
					and check_entry.breakdown.penalties.budget > 0
				then
					had_spending = true
					break
				end
			end

			if had_spending then
				break
			else
				days = days + 1
			end
		end
	end

	-- Add today if no spending
	if state.data.budget.spent_today == 0 then
		days = days + 1
	end

	return days
end

function M.check_zero_inbox_badge()
	-- This would require parsing current file
	-- Implementation depends on how you want to detect "all tasks completed"
	-- For now, this is a placeholder
end

function M.check_comeback_badge()
	local state = require("zortex.xp.state")

	-- Check if returned after missing days
	if state.data.current_streak == 1 and state.data.last_completion_date then
		-- Calculate days missed
		local last_date = state.data.last_completion_date
		local today = os.date("%Y-%m-%d")

		-- Simple date difference (this is approximate)
		-- You might want a more robust date calculation
		if last_date ~= today and last_date ~= os.date("%Y-%m-%d", os.time() - 86400) then
			local badge_name = "Comeback - " .. today
			if state.award_badge(badge_name) then
				M.notify_badge("Comeback Kid", "Returned after a break!")
			end
		end
	end
end

-- Badge categories for display
function M.get_badge_categories()
	local state = require("zortex.xp.state")
	local categories = {
		["XP Achievements"] = {},
		["Streaks"] = {},
		["Area Mastery"] = {},
		["Financial"] = {},
		["Habits"] = {},
		["Resources"] = {},
		["Daily"] = {},
		["Special"] = {},
	}

	-- Categorize existing badges
	for badge_name, timestamp in pairs(state.data.badges) do
		local added = false

		-- Pattern matching for categories
		if badge_name:match("Area Specialist") or badge_name:match("Master of") then
			table.insert(categories["Area Mastery"], { name = badge_name, time = timestamp })
			added = true
		elseif
			badge_name:match("Streak")
			or badge_name:match("Warrior")
			or badge_name:match("Fighter")
			or badge_name:match("Master")
			or badge_name:match("Quest")
			or badge_name:match("Yoda")
		then
			table.insert(categories["Streaks"], { name = badge_name, time = timestamp })
			added = true
		elseif
			badge_name:match("Penny")
			or badge_name:match("Savings")
			or badge_name:match("Budget")
			or badge_name:match("Financial")
			or badge_name:match("Wealth")
			or badge_name:match("Frugal")
			or badge_name:match("Thrifty")
			or badge_name:match("No Spend")
		then
			table.insert(categories["Financial"], { name = badge_name, time = timestamp })
			added = true
		elseif
			badge_name:match("Habit")
			or badge_name:match("Consistent")
			or badge_name:match("Dedicated")
			or badge_name:match("Unstoppable")
		then
			table.insert(categories["Habits"], { name = badge_name, time = timestamp })
			added = true
		elseif
			badge_name:match("Resource")
			or badge_name:match("Creator")
			or badge_name:match("Producer")
			or badge_name:match("Generous")
			or badge_name:match("Community")
			or badge_name:match("Sharing")
		then
			table.insert(categories["Resources"], { name = badge_name, time = timestamp })
			added = true
		elseif
			badge_name:match("Early Bird")
			or badge_name:match("Night Owl")
			or badge_name:match("Productive Day")
			or badge_name:match("Vision Aligned")
		then
			table.insert(categories["Daily"], { name = badge_name, time = timestamp })
			added = true
		end

		-- Default to XP or Special
		if not added then
			if badge_name:match("%d+ XP") or badge_name:match("Level") then
				table.insert(categories["XP Achievements"], { name = badge_name, time = timestamp })
			else
				table.insert(categories["Special"], { name = badge_name, time = timestamp })
			end
		end
	end

	-- Sort badges in each category by timestamp
	for _, badges in pairs(categories) do
		table.sort(badges, function(a, b)
			return a.time < b.time
		end)
	end

	return categories
end

return M
