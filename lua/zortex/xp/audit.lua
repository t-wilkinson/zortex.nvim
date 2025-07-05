-- Task auditing for Zortex XP system
local M = {}

-- Run comprehensive audit
function M.run_audit()
	local graph = require("zortex.xp.graph")
	local state = require("zortex.xp.state")

	-- Ensure graph is built
	graph.ensure_built()

	-- Run all audit checks
	local results = {
		orphans = M.find_orphan_tasks(),
		low_value = M.find_low_value_tasks(),
		missing_metadata = M.find_missing_metadata(),
		neglected_objectives = M.find_neglected_objectives(),
		stale_projects = M.find_stale_projects(),
		budget_opportunities = M.find_budget_opportunities(),
		optimization_suggestions = M.generate_suggestions(),
		stats = M.calculate_audit_stats(),
	}

	-- Display results
	M.show_audit_results(results)

	return results
end

-- Find orphan tasks (not connected to vision)
function M.find_orphan_tasks()
	local graph = require("zortex.xp.graph")
	local orphans = {
		tasks = {},
		projects = {},
		objectives = {},
		total = 0,
	}

	for node_id, node in pairs(graph.data.nodes) do
		local distance = graph.data.distances[node_id]

		if distance >= 999999 then -- Changed from math.huge
			orphans.total = orphans.total + 1

			if node.type == "task" then
				table.insert(orphans.tasks, {
					node = node,
					id = node_id,
					potential_xp_loss = M.calculate_potential_xp_loss(node),
				})
			elseif node.type == "project" then
				table.insert(orphans.projects, node)
			elseif node.type == "objective" then
				table.insert(orphans.objectives, node)
			end
		end
	end

	-- Sort by potential XP loss
	table.sort(orphans.tasks, function(a, b)
		return a.potential_xp_loss > b.potential_xp_loss
	end)

	return orphans
end

-- Find low-value tasks (far from vision)
function M.find_low_value_tasks()
	local graph = require("zortex.xp.graph")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	local low_value = {}
	local distance_threshold = 3

	for node_id, node in pairs(graph.data.nodes) do
		if node.type == "task" and not node.completed then
			local distance = graph.data.distances[node_id]

			if distance and distance > distance_threshold and distance < 999999 then -- Changed from math.huge
				local potential_xp = M.calculate_task_potential_xp(node)

				table.insert(low_value, {
					node = node,
					id = node_id,
					distance = distance,
					potential_xp = potential_xp,
					improvement = M.suggest_improvement(node, distance),
				})
			end
		end
	end

	-- Sort by distance (furthest first)
	table.sort(low_value, function(a, b)
		return a.distance > b.distance
	end)

	return low_value
end

-- Find tasks missing important metadata
function M.find_missing_metadata()
	local graph = require("zortex.xp.graph")
	local missing = {
		size = {},
		priority = {},
		duration = {},
		budget = {},
		links = {},
	}

	for node_id, node in pairs(graph.data.nodes) do
		if node.type == "task" and not node.completed then
			-- Missing size
			if not node.size then
				table.insert(missing.size, node)
			end

			-- Missing priority (for important-looking tasks)
			if not node.priority and M.looks_important(node) then
				table.insert(missing.priority, node)
			end

			-- Missing duration (for time-based tasks)
			if not node.duration and M.looks_time_based(node) then
				table.insert(missing.duration, node)
			end

			-- Missing budget (for financial tasks)
			if not node.budget and M.looks_financial(node) then
				table.insert(missing.budget, node)
			end

			-- Missing links (isolated tasks)
			if not node.links or #node.links == 0 then
				table.insert(missing.links, node)
			end
		end
	end

	return missing
end

-- Find neglected objectives
function M.find_neglected_objectives()
	local graph = require("zortex.xp.graph")
	local state = require("zortex.xp.state")

	local neglected = {}
	local threshold_days = 7
	local threshold_time = os.time() - (threshold_days * 86400)

	-- Track recent activity by objective
	local objective_activity = {}

	for _, entry in ipairs(state.data.xp_log) do
		if entry.timestamp > threshold_time then
			-- Find connected objectives for this task
			local task_node_id = entry.file .. ":" .. entry.task
			local objectives = graph.find_connected_of_type(task_node_id, "objective", 3)

			for _, obj_id in ipairs(objectives) do
				objective_activity[obj_id] = true
			end
		end
	end

	-- Find objectives without recent activity
	for node_id, node in pairs(graph.data.nodes) do
		if node.type == "objective" and not objective_activity[node_id] then
			-- Calculate days since last activity
			local last_activity = M.find_last_activity(node_id)
			local days_inactive = last_activity and math.floor((os.time() - last_activity) / 86400) or nil

			table.insert(neglected, {
				node = node,
				id = node_id,
				days_inactive = days_inactive,
				heat = state.get_objective_heat(node_id),
				child_tasks = M.count_child_tasks(node_id),
			})
		end
	end

	-- Sort by days inactive
	table.sort(neglected, function(a, b)
		return (a.days_inactive or 999) > (b.days_inactive or 999)
	end)

	return neglected
end

-- Find stale projects
function M.find_stale_projects()
	local graph = require("zortex.xp.graph")
	local state = require("zortex.xp.state")

	local stale = {}
	local threshold_days = 14
	local threshold_time = os.time() - (threshold_days * 86400)

	for node_id, node in pairs(graph.data.nodes) do
		if node.type == "project" then
			local last_activity = M.find_last_activity(node_id)

			if not last_activity or last_activity < threshold_time then
				local incomplete_tasks = M.count_incomplete_tasks(node_id)
				local days_inactive = last_activity and math.floor((os.time() - last_activity) / 86400) or nil

				if incomplete_tasks > 0 then
					table.insert(stale, {
						node = node,
						id = node_id,
						days_inactive = days_inactive,
						incomplete_tasks = incomplete_tasks,
						fatigue = state.get_project_fatigue(node_id),
					})
				end
			end
		end
	end

	-- Sort by incomplete tasks
	table.sort(stale, function(a, b)
		return a.incomplete_tasks > b.incomplete_tasks
	end)

	return stale
end

-- Find budget optimization opportunities
function M.find_budget_opportunities()
	local state = require("zortex.xp.state")
	local graph = require("zortex.xp.graph")

	local opportunities = {
		uncategorized_spending = {},
		high_penalty_tasks = {},
		savings_opportunities = {},
		category_analysis = {},
	}

	-- Analyze recent spending
	local recent_spending = {}
	local seven_days_ago = os.time() - (7 * 86400)

	for _, entry in ipairs(state.data.xp_log) do
		if
			entry.timestamp > seven_days_ago
			and entry.breakdown
			and entry.breakdown.penalties
			and entry.breakdown.penalties.budget > 0
		then
			-- Find task details
			local task_key = entry.file .. ":" .. entry.task
			local task = graph.get_node(task_key)

			if task then
				-- Check for missing category
				if not task.category then
					table.insert(opportunities.uncategorized_spending, {
						task = task,
						amount = task.budget,
						penalty = entry.breakdown.penalties.budget,
					})
				end

				-- High penalty tasks
				if entry.breakdown.penalties.budget > 50 then
					table.insert(opportunities.high_penalty_tasks, {
						task = task,
						amount = task.budget,
						penalty = entry.breakdown.penalties.budget,
					})
				end
			end
		end
	end

	-- Category spending analysis
	for category, amount in pairs(state.data.budget.category_spending) do
		opportunities.category_analysis[category] = {
			total = amount,
			percentage = (amount / state.data.budget.spent_total) * 100,
		}
	end

	-- Savings opportunities (tasks that could be marked as savings)
	for node_id, node in pairs(graph.data.nodes) do
		if node.type == "task" and not node.completed and M.looks_like_savings(node) then
			table.insert(opportunities.savings_opportunities, node)
		end
	end

	return opportunities
end

-- Generate optimization suggestions
function M.generate_suggestions()
	local graph = require("zortex.xp.graph")
	local state = require("zortex.xp.state")
	local suggestions = {}

	-- Vision alignment suggestion
	local orphan_count = 0
	for _, distance in pairs(graph.data.distances) do
		if distance == math.huge then
			orphan_count = orphan_count + 1
		end
	end

	if orphan_count > 10 then
		table.insert(suggestions, {
			type = "vision_alignment",
			priority = "high",
			message = string.format(
				"%d orphan items found. Link them to objectives/visions for better XP.",
				orphan_count
			),
			potential_xp_gain = orphan_count * 5, -- Rough estimate
		})
	end

	-- Streak suggestion
	if state.data.current_streak < 7 then
		table.insert(suggestions, {
			type = "streak_building",
			priority = "medium",
			message = "Build a 7+ day streak for significant XP bonuses.",
			potential_xp_gain = 350, -- 50 * 7
		})
	end

	-- Heat optimization
	local low_heat_objectives = 0
	for obj_id, heat_data in pairs(state.data.objective_heat) do
		if type(heat_data) == "table" and heat_data.value < 0.5 then
			low_heat_objectives = low_heat_objectives + 1
		end
	end

	if low_heat_objectives > 0 then
		table.insert(suggestions, {
			type = "heat_optimization",
			priority = "medium",
			message = string.format(
				"%d objectives have low heat. Focus on them for multiplier bonuses.",
				low_heat_objectives
			),
			potential_xp_gain = low_heat_objectives * 100,
		})
	end

	-- Size optimization
	local missing_sizes = M.count_missing_sizes()
	if missing_sizes > 5 then
		table.insert(suggestions, {
			type = "size_tagging",
			priority = "low",
			message = string.format("%d tasks missing size tags. Add them for accurate XP calculation.", missing_sizes),
			potential_xp_gain = missing_sizes * 10,
		})
	end

	-- Habit creation
	if vim.tbl_count(state.data.habits.daily) < 3 then
		table.insert(suggestions, {
			type = "habit_creation",
			priority = "high",
			message = "Create daily habits for consistent XP gains.",
			potential_xp_gain = 150, -- 50 * 3
		})
	end

	-- Sort by priority and potential gain
	table.sort(suggestions, function(a, b)
		local priority_order = { high = 3, medium = 2, low = 1 }
		if priority_order[a.priority] ~= priority_order[b.priority] then
			return priority_order[a.priority] > priority_order[b.priority]
		end
		return a.potential_xp_gain > b.potential_xp_gain
	end)

	return suggestions
end

-- Calculate audit statistics
function M.calculate_audit_stats()
	local graph = require("zortex.xp.graph")
	local state = require("zortex.xp.state")

	local stats = {
		total_nodes = vim.tbl_count(graph.data.nodes),
		completion_rate = 0,
		avg_task_xp = 0,
		orphan_percentage = 0,
		vision_alignment_score = 0,
		metadata_completeness = 0,
	}

	-- Calculate completion rate
	local total_tasks = 0
	local completed_tasks = 0
	local total_xp_earned = 0
	local tasks_with_metadata = 0
	local orphans = 0
	local vision_aligned = 0

	for node_id, node in pairs(graph.data.nodes) do
		if node.type == "task" then
			total_tasks = total_tasks + 1

			if node.completed then
				completed_tasks = completed_tasks + 1
			end

			-- Check metadata completeness
			if node.size and (node.priority or not M.looks_important(node)) then
				tasks_with_metadata = tasks_with_metadata + 1
			end

			-- Check orphan status
			local distance = graph.data.distances[node_id]
			if distance >= 999999 then -- Changed from math.huge
				orphans = orphans + 1
			elseif distance <= 2 then
				vision_aligned = vision_aligned + 1
			end
		end
	end

	-- Calculate total XP from log
	for _, entry in ipairs(state.data.xp_log) do
		total_xp_earned = total_xp_earned + entry.xp
	end

	-- Calculate stats
	if total_tasks > 0 then
		stats.completion_rate = (completed_tasks / total_tasks) * 100
		stats.metadata_completeness = (tasks_with_metadata / total_tasks) * 100
		stats.orphan_percentage = (orphans / total_tasks) * 100
		stats.vision_alignment_score = (vision_aligned / total_tasks) * 100
	end

	if #state.data.xp_log > 0 then
		stats.avg_task_xp = total_xp_earned / #state.data.xp_log
	end

	return stats
end

-- Display audit results
function M.show_audit_results(results)
	local ui = require("zortex.xp.ui")
	local lines = {
		"═══════════════════════════════════════════════════════",
		"                  TASK AUDIT REPORT",
		"═══════════════════════════════════════════════════════",
		"",
		"Summary Statistics:",
		string.format("  Total Nodes: %d", results.stats.total_nodes),
		string.format("  Completion Rate: %.1f%%", results.stats.completion_rate),
		string.format("  Average Task XP: %.1f", results.stats.avg_task_xp),
		string.format("  Orphan Rate: %.1f%%", results.stats.orphan_percentage),
		string.format("  Vision Alignment: %.1f%%", results.stats.vision_alignment_score),
		string.format("  Metadata Completeness: %.1f%%", results.stats.metadata_completeness),
		"",
	}

	-- Optimization suggestions
	if #results.optimization_suggestions > 0 then
		table.insert(lines, "🎯 Top Optimization Opportunities:")
		for i, suggestion in ipairs(results.optimization_suggestions) do
			if i > 5 then
				break
			end
			table.insert(lines, string.format("  %d. %s", i, suggestion.message))
			table.insert(lines, string.format("     Potential gain: +%d XP", suggestion.potential_xp_gain))
		end
		table.insert(lines, "")
	end

	-- Orphan tasks
	if results.orphans.total > 0 then
		table.insert(lines, string.format("⚠️  Orphan Items: %d total", results.orphans.total))
		if #results.orphans.tasks > 0 then
			table.insert(lines, "  Top orphan tasks (by potential XP loss):")
			for i = 1, math.min(5, #results.orphans.tasks) do
				local item = results.orphans.tasks[i]
				local text = item.node.text or item.node.name or "Unknown"
				if #text > 40 then
					text = text:sub(1, 37) .. "..."
				end
				table.insert(lines, string.format("    - %s (-%d XP)", text, item.potential_xp_loss))
			end
		end
		table.insert(lines, "")
	end

	-- Low value tasks
	if #results.low_value > 0 then
		table.insert(lines, string.format("📉 Low Value Tasks: %d", #results.low_value))
		for i = 1, math.min(3, #results.low_value) do
			local item = results.low_value[i]
			local text = item.node.text or "Unknown"
			if #text > 40 then
				text = text:sub(1, 37) .. "..."
			end
			local distance_display = item.distance >= 999999 and "∞" or tostring(item.distance)
			table.insert(lines, string.format("    - %s (distance: %s)", text, distance_display))
			if item.improvement then
				table.insert(lines, string.format("      → %s", item.improvement))
			end
		end
		table.insert(lines, "")
	end

	-- Missing metadata
	local total_missing = #results.missing_metadata.size
		+ #results.missing_metadata.priority
		+ #results.missing_metadata.duration
		+ #results.missing_metadata.budget
	if total_missing > 0 then
		table.insert(lines, "📋 Missing Metadata:")
		table.insert(lines, string.format("  - Size tags: %d tasks", #results.missing_metadata.size))
		table.insert(lines, string.format("  - Priority: %d tasks", #results.missing_metadata.priority))
		table.insert(lines, string.format("  - Duration: %d tasks", #results.missing_metadata.duration))
		table.insert(lines, string.format("  - Budget: %d tasks", #results.missing_metadata.budget))
		table.insert(lines, string.format("  - Links: %d tasks", #results.missing_metadata.links))
		table.insert(lines, "")
	end

	-- Neglected objectives
	if #results.neglected_objectives > 0 then
		table.insert(lines, "🎯 Neglected Objectives:")
		for i = 1, math.min(3, #results.neglected_objectives) do
			local obj = results.neglected_objectives[i]
			local days = obj.days_inactive or "Unknown"
			table.insert(lines, string.format("  - %s (%s days inactive, heat: %.1f)", obj.node.name, days, obj.heat))
		end
		table.insert(lines, "")
	end

	-- Stale projects
	if #results.stale_projects > 0 then
		table.insert(lines, "💤 Stale Projects:")
		for i = 1, math.min(3, #results.stale_projects) do
			local proj = results.stale_projects[i]
			table.insert(lines, string.format("  - %s (%d incomplete tasks)", proj.node.name, proj.incomplete_tasks))
		end
		table.insert(lines, "")
	end

	-- Budget insights
	if results.budget_opportunities then
		local budget = results.budget_opportunities
		if #budget.uncategorized_spending > 0 then
			table.insert(
				lines,
				string.format("💰 Uncategorized Spending: %d transactions", #budget.uncategorized_spending)
			)
		end
		if #budget.high_penalty_tasks > 0 then
			table.insert(
				lines,
				string.format("💸 High Penalty Tasks: %d (consider exemptions)", #budget.high_penalty_tasks)
			)
		end
		table.insert(lines, "")
	end

	-- Actions
	table.insert(lines, "Recommended Actions:")
	table.insert(lines, "  1. Link orphan tasks to objectives/projects")
	table.insert(lines, "  2. Add size tags to estimate effort accurately")
	table.insert(lines, "  3. Review and archive stale projects")
	table.insert(lines, "  4. Set priorities for important tasks")
	table.insert(lines, "  5. Focus on neglected objectives to balance progress")

	ui.show_buffer(lines, "Task Audit Report")
end

-- Helper functions

function M.calculate_potential_xp_loss(node)
	local calculator = require("zortex.xp.calculator")
	local xp = require("zortex.xp")
	local cfg = xp.get_config()

	-- Estimate XP if it were connected vs orphan
	local connected_xp = cfg.base_xp * cfg.distance_multipliers[2] -- Assume distance 2
	local orphan_xp = cfg.orphan_xp

	return math.floor(connected_xp - orphan_xp)
end

function M.calculate_task_potential_xp(task)
	local calculator = require("zortex.xp.calculator")
	return calculator.calculate_total_xp(task).total
end

function M.suggest_improvement(node, distance)
	if distance > 4 then
		return "Link to a project or objective for better XP"
	elseif distance > 2 then
		return "Consider linking closer to vision"
	elseif not node.size then
		return "Add size tag for accurate XP"
	elseif not node.priority and M.looks_important(node) then
		return "Add priority for multiplier bonus"
	else
		return nil
	end
end

function M.looks_important(node)
	if not node.text then
		return false
	end

	local important_keywords = {
		"important",
		"urgent",
		"critical",
		"asap",
		"priority",
		"deadline",
		"must",
		"need",
		"require",
		"essential",
	}

	local text_lower = node.text:lower()
	for _, keyword in ipairs(important_keywords) do
		if text_lower:match(keyword) then
			return true
		end
	end

	return false
end

function M.looks_time_based(node)
	if not node.text then
		return false
	end

	local time_keywords = {
		"hour",
		"hours",
		"minute",
		"minutes",
		"time",
		"duration",
		"estimate",
		"meeting",
		"call",
		"session",
	}

	local text_lower = node.text:lower()
	for _, keyword in ipairs(time_keywords) do
		if text_lower:match(keyword) then
			return true
		end
	end

	return false
end

function M.looks_financial(node)
	if not node.text then
		return false
	end

	local financial_keywords = {
		"buy",
		"purchase",
		"pay",
		"cost",
		"price",
		"budget",
		"spend",
		"expense",
		"bill",
		"invoice",
		"subscription",
		"$",
		"dollar",
		"money",
	}

	local text_lower = node.text:lower()
	for _, keyword in ipairs(financial_keywords) do
		if text_lower:match(keyword) then
			return true
		end
	end

	return false
end

function M.looks_like_savings(node)
	if not node.text then
		return false
	end

	local savings_keywords = {
		"save",
		"saving",
		"saved",
		"discount",
		"coupon",
		"deal",
		"sale",
		"refund",
		"cashback",
		"reward",
	}

	local text_lower = node.text:lower()
	for _, keyword in ipairs(savings_keywords) do
		if text_lower:match(keyword) then
			return true
		end
	end

	return false
end

function M.find_last_activity(node_id)
	local state = require("zortex.xp.state")
	local graph = require("zortex.xp.graph")

	-- Check direct task completions
	for i = #state.data.xp_log, 1, -1 do
		local entry = state.data.xp_log[i]
		local task_id = entry.file .. ":" .. entry.task

		-- Check if task is connected to this node
		local connected = graph.find_connected_of_type(task_id, graph.data.nodes[node_id].type, 3)

		for _, connected_id in ipairs(connected) do
			if connected_id == node_id then
				return entry.timestamp
			end
		end
	end

	return nil
end

function M.count_child_tasks(node_id)
	local graph = require("zortex.xp.graph")
	local count = 0

	-- Count tasks that link to this node
	for task_id, task in pairs(graph.data.nodes) do
		if task.type == "task" and task.links then
			for _, link in ipairs(task.links) do
				if link == node_id then
					count = count + 1
					break
				end
			end
		end
	end

	return count
end

function M.count_incomplete_tasks(project_id)
	local graph = require("zortex.xp.graph")
	local count = 0

	for task_id, task in pairs(graph.data.nodes) do
		if task.type == "task" and not task.completed and task.links then
			for _, link in ipairs(task.links) do
				if link == project_id then
					count = count + 1
					break
				end
			end
		end
	end

	return count
end

function M.count_missing_sizes()
	local graph = require("zortex.xp.graph")
	local count = 0

	for _, node in pairs(graph.data.nodes) do
		if node.type == "task" and not node.completed and not node.size then
			count = count + 1
		end
	end

	return count
end

return M
