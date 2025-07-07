-- xp.lua - Experience Points system for Zortex
local M = {}

-- Dependencies
local utils = require("zortex.utils")

-- Default configuration
M.defaults = {
	-- Base XP values
	base_xp = {
		task = 10, -- Base XP for completing a task
		project = 50, -- Base XP for completing a project
		okr_connected_bonus = 2.0, -- Multiplier for OKR-connected tasks
		okr_objective = 100, -- Base XP for completing an OKR objective
	},

	-- Task size definitions and their default durations (in minutes)
	task_sizes = {
		xs = { duration = 15, xp_multiplier = 0.5 },
		sm = { duration = 30, xp_multiplier = 0.8 },
		md = { duration = 60, xp_multiplier = 1.0 }, -- Default size
		lg = { duration = 120, xp_multiplier = 1.5 },
		xl = { duration = 240, xp_multiplier = 2.0 },
	},
	default_task_size = "md",

	-- Project size definitions and their XP multipliers
	project_sizes = {
		xs = { xp_multiplier = 0.5 },
		sm = { xp_multiplier = 0.8 },
		md = { xp_multiplier = 1.0 }, -- Default size
		lg = { xp_multiplier = 1.5 },
		xl = { xp_multiplier = 2.0 },
		epic = { xp_multiplier = 3.0 },
		legendary = { xp_multiplier = 5.0 },
		mythic = { xp_multiplier = 8.0 },
		ultimate = { xp_multiplier = 12.0 },
	},
	default_project_size = "md",

	-- Task completion percentage curve
	-- Maps completion percentage to XP percentage awarded
	task_completion_curve = {
		[0.1] = 0.05, -- 10% complete = 5% of project XP
		[0.2] = 0.10, -- 20% complete = 10% of project XP
		[0.3] = 0.16, -- 30% complete = 16% of project XP
		[0.4] = 0.23, -- 40% complete = 23% of project XP
		[0.5] = 0.31, -- 50% complete = 31% of project XP
		[0.6] = 0.40, -- 60% complete = 40% of project XP
		[0.7] = 0.50, -- 70% complete = 50% of project XP
		[0.8] = 0.62, -- 80% complete = 62% of project XP
		[0.9] = 0.76, -- 90% complete = 76% of project XP
		[1.0] = 1.00, -- 100% complete = 100% of project XP
	},

	-- Priority multipliers
	priority_multipliers = {
		p1 = 1.5,
		p2 = 1.2,
		p3 = 1.0,
		default = 0.9,
	},

	-- Importance multipliers
	importance_multipliers = {
		i1 = 1.5,
		i2 = 1.2,
		i3 = 1.0,
		default = 0.9,
	},

	-- OKR span code multipliers (bigger timeframe = bigger multiplier)
	span_multipliers = {
		M = 1.0, -- Monthly
		Q = 1.5, -- Quarterly
		Y = 2.0, -- Yearly
		["5Y"] = 3.0, -- 5 Year
		["10Y"] = 4.0, -- 10 Year
	},

	-- OKR objective completion multipliers (based on span)
	okr_objective_multipliers = {
		M = 1.0, -- Monthly
		Q = 2.0, -- Quarterly
		Y = 4.0, -- Yearly
		["5Y"] = 8.0, -- 5 Year
		["10Y"] = 16.0, -- 10 Year
	},

	-- Temporal multiplier (for non-current OKRs)
	temporal_multipliers = {
		current = 2,
		recent = 1.5, -- Within last quarter
		past_year = 1.3, -- Within last year
		old = 1.1, -- Older than a year
	},

	-- Custom XP calculation function (can be overridden)
	custom_calculation = nil,
}

-- Current configuration
M.config = {}

-- Setup function to initialize the XP system
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

-- =============================================================================
-- Project Attribute Parsing
-- =============================================================================

--- Parse project attributes from a heading line
-- @param line string The project heading line
-- @param config table Configuration with project_sizes and default_project_size
-- @return table Attributes table with size, priority, importance, etc.
function M.parse_project_attributes(line, config)
	config = config or M.config
	local attrs = {
		size = config.default_project_size or "md",
		priority = nil,
		importance = nil,
		duration = nil,
		estimation = nil,
		done_date = nil,
		progress = nil,
	}

	-- Parse size
	for size, _ in pairs(config.project_sizes or {}) do
		if line:match("@" .. size .. "%s") or line:match("@" .. size .. "$") then
			attrs.size = size
			break
		end
	end

	-- Parse priority
	local priority = line:match("@p(%d)")
	if priority then
		attrs.priority = "p" .. priority
	end

	-- Parse importance
	local importance = line:match("@i(%d)")
	if importance then
		attrs.importance = "i" .. importance
	end

	-- Parse duration (e.g., @2h, @30m)
	local duration_match = line:match("@(%d+)([hm])")
	if duration_match then
		local amount, unit = line:match("@(%d+)([hm])")
		attrs.duration = unit == "h" and tonumber(amount) * 60 or tonumber(amount)
	end

	-- Parse estimation (e.g., @est(2h), @est(30m))
	local est_match = line:match("@est%((%d+)([hm])%)")
	if est_match then
		local amount, unit = line:match("@est%((%d+)([hm])%)")
		attrs.estimation = unit == "h" and tonumber(amount) * 60 or tonumber(amount)
	end

	-- Parse done date @done(YYYY-MM-DD)
	local done_date = line:match("@done%((%d%d%d%d%-%d%d%-%d%d)%)")
	if done_date then
		attrs.done_date = done_date
	end

	-- Parse progress @progress(completed/total)
	local completed, total = line:match("@progress%((%d+)/(%d+)%)")
	if completed and total then
		attrs.progress = {
			completed = tonumber(completed),
			total = tonumber(total),
		}
	end

	return attrs
end

-- =============================================================================
-- Project XP Calculation
-- =============================================================================

--- Get XP percentage based on completion percentage
-- @param completion_pct number Completion percentage (0-1)
-- @return number XP percentage to award
local function get_xp_percentage_from_curve(completion_pct)
	local curve = M.config.task_completion_curve

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

--- Calculate total project XP based on attributes
-- @param project_attrs table Project attributes
-- @param okr_connection table|nil OKR connection info
-- @return number Total project XP value
function M.calculate_project_total_xp(project_attrs, okr_connection)
	local base_xp = M.config.base_xp.project

	-- Size multiplier
	local size_mult = M.config.project_sizes[project_attrs.size].xp_multiplier

	-- Priority multiplier
	local priority_mult = project_attrs.priority and M.config.priority_multipliers[project_attrs.priority]
		or M.config.priority_multipliers.default

	-- Importance multiplier
	local importance_mult = project_attrs.importance and M.config.importance_multipliers[project_attrs.importance]
		or M.config.importance_multipliers.default

	-- OKR bonus
	local okr_mult = 1.0
	if okr_connection then
		okr_mult = M.config.base_xp.okr_connected_bonus
		-- Also apply span multiplier
		if okr_connection.span then
			okr_mult = okr_mult * (M.config.span_multipliers[okr_connection.span] or 1.0)
		end
		-- Apply temporal multiplier
		okr_mult = okr_mult * calculate_temporal_multiplier(okr_connection)
	end

	return math.floor(base_xp * size_mult * priority_mult * importance_mult * okr_mult + 0.5)
end

--- Calculate XP for completing a task within a project
-- @param task_data table Task data
-- @param project_data table Project data including completion info
-- @return number XP value for this task
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
	local before_xp_pct = get_xp_percentage_from_curve(before_pct)
	local after_xp_pct = get_xp_percentage_from_curve(after_pct)

	-- Calculate the project XP portion for this task
	local project_total_xp = M.calculate_project_total_xp(project_data.attrs, project_data.okr_connection)
	local project_xp_portion = project_total_xp * (after_xp_pct - before_xp_pct)

	return math.floor(base_task_xp + project_xp_portion + 0.5)
end

-- =============================================================================
-- OKR Objective XP
-- =============================================================================

--- Calculate XP for completing an OKR objective
-- @param okr_data table OKR data with span, year, month, is_current
-- @return number XP value for completing the objective
function M.calculate_okr_objective_xp(okr_data)
	local base_xp = M.config.base_xp.okr_objective

	-- Span multiplier
	local span_mult = M.config.okr_objective_multipliers[okr_data.span] or 1.0

	-- Temporal multiplier
	local temporal_mult = calculate_temporal_multiplier(okr_data)

	return math.floor(base_xp * span_mult * temporal_mult + 0.5)
end

-- =============================================================================
-- OKR Connection Detection
-- =============================================================================

--- Find OKR connection for a project using the links parser
-- @param project_heading string The project heading to search for
-- @return table|nil OKR info with span, year, month, title, is_current
local function find_okr_connection(project_heading)
	local okr_file = vim.fn.expand(vim.g.zortex_notes_dir .. "/okr.zortex")
	if not vim.fn.filereadable(okr_file) then
		return nil
	end

	local lines = utils.read_file_lines(okr_file)
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
		local okr_date = utils.parse_okr_date(line)
		if okr_date then
			current_objective = vim.tbl_extend("force", okr_date, {
				is_current = in_current,
			})
		end

		-- Check for key result linking to our project
		if current_objective and line:match("^%s*- KR%-") then
			-- Use utils to check if project is linked
			if utils.is_project_linked(line, project_heading) then
				okr_info = current_objective
				break
			end
		end
	end

	return okr_info
end

-- =============================================================================
-- XP Calculation
-- =============================================================================

--- Calculate temporal multiplier based on OKR date
-- @param okr_info table|nil OKR info with year, month, is_current
-- @return number Temporal multiplier
local function calculate_temporal_multiplier(okr_info)
	if not okr_info then
		return M.config.temporal_multipliers.default or 0.8
	end

	if okr_info.is_current then
		return M.config.temporal_multipliers.current
	end

	-- Calculate age in months
	local current_date = os.date("*t")
	local months_ago = utils.months_between(okr_info, current_date)

	if months_ago <= 3 then
		return M.config.temporal_multipliers.recent
	elseif months_ago <= 12 then
		return M.config.temporal_multipliers.past_year
	else
		return M.config.temporal_multipliers.old
	end
end

--- Main XP calculation function
-- @param task_data table Task data with attributes and metadata
-- @return number Calculated XP value
function M.calculate_xp(task_data)
	-- Allow custom calculation if provided
	if M.config.custom_calculation then
		return M.config.custom_calculation(task_data, M.config)
	end

	-- Base XP
	local base_xp = task_data.is_project and M.config.base_xp.project or M.config.base_xp.task

	-- OKR connection bonus
	if task_data.okr_connection then
		base_xp = base_xp * M.config.base_xp.okr_connected_bonus
	end

	-- Size multiplier
	local size_mult = M.config.task_sizes[task_data.size].xp_multiplier

	-- Priority multiplier
	local priority_mult = task_data.priority and M.config.priority_multipliers[task_data.priority]
		or M.config.priority_multipliers.default

	-- Importance multiplier
	local importance_mult = task_data.importance and M.config.importance_multipliers[task_data.importance]
		or M.config.importance_multipliers.default

	-- Temporal multiplier
	local temporal_mult = calculate_temporal_multiplier(task_data.okr_connection)

	-- Calculate total XP
	local total_xp = base_xp * size_mult * priority_mult * importance_mult * temporal_mult

	-- Apply penalties if needed
	if task_data.is_overdue then
		total_xp = total_xp * (M.config.penalties and M.config.penalties.overdue_task or 0.9)
	end

	return math.floor(total_xp + 0.5) -- Round to nearest integer
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Get XP for completing a task
-- @param task_line string The task line to calculate XP for
-- @param project_heading string|nil The project this task belongs to
-- @return number XP value
function M.get_task_xp(task_line, project_heading)
	local attrs = utils.parse_task_attributes(task_line, M.config)
	local okr_connection = project_heading and find_okr_connection(project_heading) or nil

	local task_data = vim.tbl_extend("force", attrs, {
		is_project = false,
		okr_connection = okr_connection,
	})

	return M.calculate_xp(task_data)
end

--- Get XP for completing a project
-- @param project_heading string The project heading
-- @return number XP value
function M.get_project_xp(project_heading)
	local okr_connection = find_okr_connection(project_heading)

	local project_data = {
		is_project = true,
		size = "xl", -- Projects are always XL
		priority = nil,
		importance = nil,
		okr_connection = okr_connection,
	}

	return M.calculate_xp(project_data)
end

--- Get XP breakdown for display
-- @param task_data table Task data to break down
-- @return table Array of breakdown strings
function M.get_xp_breakdown(task_data)
	local breakdown = {}

	-- Base XP
	local base_xp = task_data.is_project and M.config.base_xp.project or M.config.base_xp.task
	table.insert(breakdown, string.format("Base XP: %d", base_xp))

	-- OKR connection
	if task_data.okr_connection then
		local bonus = M.config.base_xp.okr_connected_bonus
		table.insert(breakdown, string.format("OKR Connected: x%.1f", bonus))
	end

	-- Size
	local size_mult = M.config.task_sizes[task_data.size].xp_multiplier
	table.insert(breakdown, string.format("Size (%s): x%.1f", task_data.size, size_mult))

	-- Priority
	if task_data.priority then
		local priority_mult = M.config.priority_multipliers[task_data.priority]
		table.insert(breakdown, string.format("Priority (%s): x%.1f", task_data.priority, priority_mult))
	end

	-- Importance
	if task_data.importance then
		local importance_mult = M.config.importance_multipliers[task_data.importance]
		table.insert(breakdown, string.format("Importance (%s): x%.1f", task_data.importance, importance_mult))
	end

	-- OKR span
	if task_data.okr_connection and task_data.okr_connection.span then
		local span_mult = M.config.span_multipliers[task_data.okr_connection.span]
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

--- Get estimated duration for a task
-- @param task_line string The task line
-- @return number Duration in minutes
function M.get_task_duration(task_line)
	local attrs = utils.parse_task_attributes(task_line, M.config)

	-- Use explicit duration/estimation if available
	if attrs.duration then
		return attrs.duration
	elseif attrs.estimation then
		return attrs.estimation
	else
		-- Use size-based default
		return M.config.task_sizes[attrs.size].duration
	end
end

--- Create task data for XP calculation
-- @param line string Task or project line
-- @param project_heading string|nil Current project heading
-- @param is_project boolean Whether this is a project
-- @return table Task data for XP calculation
function M.create_task_data(line, project_heading, is_project)
	local attrs = is_project and {} or utils.parse_task_attributes(line, M.config)
	local okr_connection = project_heading and find_okr_connection(project_heading) or nil

	return vim.tbl_extend("force", attrs, {
		is_project = is_project,
		size = is_project and "xl" or attrs.size,
		okr_connection = okr_connection,
	})
end

-- Initialize with defaults
M.config = M.defaults

return M
