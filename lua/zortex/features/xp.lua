-- features/xp.lua - Experience Points system for Zortex
local M = {}

local config = require("zortex.config")
local parser = require("zortex.core.parser")
local fs = require("zortex.core.filesystem")
local buffer = require("zortex.core.buffer")

-- =============================================================================
-- XP Calculation Helpers
-- =============================================================================

-- Get XP percentage based on completion percentage
local function get_xp_from_curve(completion_pct)
	local curve = config.get("xp.completion_curve")

	-- Find the two points to interpolate between
	local lower_pct, lower_xp = 0, 0
	local upper_pct, upper_xp = 1, 1

	for pct, xp in pairs(curve) do
		if pct <= completion_pct and pct > lower_pct then
			lower_pct = pct
			lower_xp = xp
		end
		if pct >= completion_pct and pct < upper_pct then
			upper_pct = pct
			upper_xp = xp
		end
	end

	-- Linear interpolation
	if upper_pct == lower_pct then
		return lower_xp
	end

	local t = (completion_pct - lower_pct) / (upper_pct - lower_pct)
	return lower_xp + t * (upper_xp - lower_xp)
end

-- Calculate temporal multiplier based on OKR date
local function calculate_temporal_multiplier(okr_info)
	if not okr_info then
		return 0.8
	end

	if okr_info.is_current then
		return 2.0
	end

	-- Calculate age in months
	local current_date = os.date("*t")
	local months_ago = parser.months_between(okr_info, current_date)

	if months_ago <= 3 then
		return 1.5
	elseif months_ago <= 12 then
		return 1.3
	else
		return 1.1
	end
end

-- =============================================================================
-- OKR Connection Detection
-- =============================================================================

-- Find OKR connection for a project
local function find_okr_connection(project_heading)
	local okr_file = fs.get_okr_file()
	if not okr_file or not fs.file_exists(okr_file) then
		return nil
	end

	local lines = fs.read_lines(okr_file)
	if not lines then
		return nil
	end

	local current_objective = nil
	local in_current = false
	local okr_info = nil

	for _, line in ipairs(lines) do
		-- Check if we're in current objectives
		if line:match("^# Current") then
			in_current = true
		elseif line:match("^# Previous") then
			in_current = false
		end

		-- Parse objective line
		local okr_date = parser.parse_okr_date(line)
		if okr_date then
			current_objective = vim.tbl_extend("force", okr_date, {
				is_current = in_current,
			})
		end

		-- Check for key result linking to our project
		if current_objective and line:match("^%s*- KR%-") then
			if parser.is_project_linked(line, project_heading) then
				okr_info = current_objective
				break
			end
		end
	end

	return okr_info
end

-- =============================================================================
-- Task XP Calculation
-- =============================================================================

-- Create task data for XP calculation
function M.create_task_data(line, project_heading, is_project)
	local attrs = is_project and {} or parser.parse_task_attributes(line)
	local okr_connection = project_heading and find_okr_connection(project_heading) or nil

	return vim.tbl_extend("force", attrs, {
		is_project = is_project,
		size = is_project and "xl" or attrs.size,
		okr_connection = okr_connection,
	})
end

-- Main XP calculation function
function M.calculate_xp(task_data)
	-- Skip objectives and key results for base XP
	if task_data.is_objective or task_data.is_key_result then
		return 0
	end

	local cfg = config.get("xp")

	-- Base XP
	local base_xp = task_data.is_project and cfg.base.project or cfg.base.task

	-- OKR connection bonus
	if task_data.okr_connection then
		base_xp = base_xp * cfg.base.okr_connected_bonus
	end

	-- Size multiplier
	local size_mult = task_data.is_project and cfg.project_sizes[task_data.size].multiplier
		or cfg.task_sizes[task_data.size].multiplier

	-- Priority multiplier
	local priority_mult = task_data.priority and cfg.priority_multipliers[task_data.priority]
		or cfg.priority_multipliers.default

	-- Importance multiplier
	local importance_mult = task_data.importance and cfg.importance_multipliers[task_data.importance]
		or cfg.importance_multipliers.default

	-- Temporal multiplier
	local temporal_mult = calculate_temporal_multiplier(task_data.okr_connection)

	-- Calculate total XP
	local total_xp = base_xp * size_mult * priority_mult * importance_mult * temporal_mult

	-- Apply penalties if needed
	if task_data.is_overdue then
		total_xp = total_xp * 0.9
	end

	return math.floor(total_xp + 0.5)
end

-- =============================================================================
-- Project XP Calculation
-- =============================================================================

-- Calculate total project XP based on attributes
function M.calculate_project_total_xp(project_attrs, okr_connection)
	local cfg = config.get("xp")
	local base_xp = cfg.base.project

	-- Size multiplier
	local size_mult = cfg.project_sizes[project_attrs.size].multiplier

	-- Priority multiplier
	local priority_mult = project_attrs.priority and cfg.priority_multipliers[project_attrs.priority]
		or cfg.priority_multipliers.default

	-- Importance multiplier
	local importance_mult = project_attrs.importance and cfg.importance_multipliers[project_attrs.importance]
		or cfg.importance_multipliers.default

	-- OKR bonus
	local okr_mult = 1.0
	if okr_connection then
		okr_mult = cfg.base.okr_connected_bonus
		-- Also apply span multiplier
		if okr_connection.span then
			okr_mult = okr_mult * (cfg.span_multipliers[okr_connection.span] or 1.0)
		end
		-- Apply temporal multiplier
		okr_mult = okr_mult * calculate_temporal_multiplier(okr_connection)
	end

	return math.floor(base_xp * size_mult * priority_mult * importance_mult * okr_mult + 0.5)
end

-- Calculate XP for completing a task within a project
function M.calculate_task_xp_in_project(task_data, project_data)
	-- First get base task XP
	local base_task_xp = M.calculate_xp(task_data)

	-- If project doesn't track completion, just return base XP
	if not project_data.total_tasks or project_data.total_tasks == 0 then
		return base_task_xp
	end

	-- Calculate completion percentages before and after this task
	local before_pct = (project_data.completed_tasks - 1) / project_data.total_tasks
	local after_pct = project_data.completed_tasks / project_data.total_tasks

	-- Get XP percentages from curve
	local before_xp_pct = get_xp_from_curve(before_pct)
	local after_xp_pct = get_xp_from_curve(after_pct)

	-- Calculate the project XP portion for this task
	local project_total_xp = M.calculate_project_total_xp(project_data.attrs, project_data.okr_connection)
	local project_xp_portion = project_total_xp * (after_xp_pct - before_xp_pct)

	return math.floor(base_task_xp + project_xp_portion + 0.5)
end

-- =============================================================================
-- OKR Objective XP
-- =============================================================================

-- Calculate XP for completing an OKR objective
function M.calculate_okr_objective_xp(okr_data)
	local cfg = config.get("xp")
	local base_xp = cfg.base.okr_objective

	-- Span multiplier
	local span_mult = cfg.span_multipliers[okr_data.span] or 1.0

	-- Temporal multiplier
	local temporal_mult = calculate_temporal_multiplier(okr_data)

	return math.floor(base_xp * span_mult * temporal_mult + 0.5)
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Get XP for completing a task
function M.get_task_xp(task_line, project_heading)
	local attrs = parser.parse_task_attributes(task_line)
	local okr_connection = project_heading and find_okr_connection(project_heading) or nil

	local task_data = vim.tbl_extend("force", attrs, {
		is_project = false,
		okr_connection = okr_connection,
	})

	return M.calculate_xp(task_data)
end

-- Get XP for completing a project
function M.get_project_xp(project_heading)
	local okr_connection = find_okr_connection(project_heading)

	local project_data = {
		is_project = true,
		size = "xl",
		priority = nil,
		importance = nil,
		okr_connection = okr_connection,
	}

	return M.calculate_xp(project_data)
end

-- Get estimated duration for a task
function M.get_task_duration(task_line)
	local attrs = parser.parse_task_attributes(task_line)
	local cfg = config.get("xp")

	-- Use explicit duration/estimation if available
	if attrs.duration then
		return attrs.duration
	elseif attrs.estimation then
		return attrs.estimation
	else
		-- Use size-based default
		return cfg.task_sizes[attrs.size].duration
	end
end

-- Get XP breakdown for display
function M.get_xp_breakdown(task_data)
	local cfg = config.get("xp")
	local breakdown = {}

	-- Base XP
	local base_xp = task_data.is_project and cfg.base.project or cfg.base.task
	table.insert(breakdown, string.format("Base XP: %d", base_xp))

	-- OKR connection
	if task_data.okr_connection then
		local bonus = cfg.base.okr_connected_bonus
		table.insert(breakdown, string.format("OKR Connected: x%.1f", bonus))
	end

	-- Size
	local size_mult = task_data.is_project and cfg.project_sizes[task_data.size].multiplier
		or cfg.task_sizes[task_data.size].multiplier
	table.insert(breakdown, string.format("Size (%s): x%.1f", task_data.size, size_mult))

	-- Priority
	if task_data.priority then
		local priority_mult = cfg.priority_multipliers[task_data.priority]
		table.insert(breakdown, string.format("Priority (%s): x%.1f", task_data.priority, priority_mult))
	end

	-- Importance
	if task_data.importance then
		local importance_mult = cfg.importance_multipliers[task_data.importance]
		table.insert(breakdown, string.format("Importance (%s): x%.1f", task_data.importance, importance_mult))
	end

	-- OKR span
	if task_data.okr_connection and task_data.okr_connection.span then
		local span_mult = cfg.span_multipliers[task_data.okr_connection.span]
		table.insert(breakdown, string.format("OKR Span (%s): x%.1f", task_data.okr_connection.span, span_mult))
	end

	-- Temporal
	if task_data.okr_connection then
		local temporal_mult = calculate_temporal_multiplier(task_data.okr_connection)
		local status = task_data.okr_connection.is_current and "Current" or "Past"
		table.insert(breakdown, string.format("Temporal (%s): x%.1f", status, temporal_mult))
	end

	-- Total
	local total_xp = M.calculate_xp(task_data)
	table.insert(breakdown, string.format("Total XP: %d", total_xp))

	return breakdown
end

return M
