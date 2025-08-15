-- commands/xp.lua - XP system commands
local M = {}

local xp_service = require("zortex.services.xp")
local xp_store = require("zortex.stores.xp")
local projects_service = require("zortex.services.projects")
local workspace = require("zortex.core.workspace")
local Logger = require("zortex.core.logger")

-- =============================================================================
-- XP Status Commands
-- =============================================================================

-- Show XP overview
function M.show_xp_overview()
	local stats = xp_service.get_stats()
	local lines = {}

	table.insert(lines, "🎮 Zortex XP System (Project-Centric)")
	table.insert(lines, string.rep("─", 50))
	table.insert(lines, "")

	-- Season status
	if stats.season then
		table.insert(lines, "🏆 Current Season: " .. stats.season.season.name)
		table.insert(
			lines,
			string.format(
				"   Level %d (%s)",
				stats.season.level,
				stats.season.current_tier and stats.season.current_tier.name or "None"
			)
		)
		table.insert(lines, string.format("   Progress: %.1f%% to next level", stats.season.progress.progress * 100))
		table.insert(lines, string.format("   Total XP: %d", stats.season.xp))
		table.insert(lines, "")
	end

	-- XP sources breakdown
	table.insert(lines, "📊 XP Sources:")
	for source, percentage in pairs(stats.source_percentages) do
		local amount = stats.sources[source]
		table.insert(
			lines,
			string.format("   %s: %d XP (%.1f%%)", source:gsub("_", " "):gsub("^%l", string.upper), amount, percentage)
		)
	end
	table.insert(lines, "")

	-- Project statistics
	table.insert(lines, "📁 Projects:")
	table.insert(lines, string.format("   Active: %d", stats.totals.active_projects))
	table.insert(lines, string.format("   Completed: %d", stats.totals.completed_projects))
	table.insert(lines, "")

	-- Area statistics
	table.insert(lines, "🗺️ Areas:")
	table.insert(lines, string.format("   Total: %d", stats.totals.total_areas))
	table.insert(lines, string.format("   Average Level: %.1f", stats.totals.avg_area_level))

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, {
		title = "XP Overview",
		timeout = 10000,
	})
end

-- Show project XP details
function M.show_project_xp()
	local context = workspace.get_context()
	if not context then
		vim.notify("No workspace context", vim.log.levels.ERROR)
		return
	end

	-- Find current project
	local project_section = projects_service.find_project(context.section)
	if not project_section then
		vim.notify("Not in a project", vim.log.levels.WARN)
		return
	end

	local project = projects_service.get_project(project_section, context.doc)
	if not project then
		vim.notify("Could not get project data", vim.log.levels.ERROR)
		return
	end

	-- Get XP details
	local details = xp_store.get_project_details(project.name)
	local lines = {}

	table.insert(lines, string.format("📁 Project: %s", project.name))
	table.insert(lines, string.rep("─", 40))

	if details then
		table.insert(lines, string.format("Total XP: %d", details.total_xp))
		table.insert(lines, string.format("Earned XP: %d", details.earned_xp))
		table.insert(lines, string.format("Progress: %.1f%%", details.completion_percentage * 100))
		table.insert(lines, string.format("Tasks: %d", details.task_count))
		table.insert(lines, "")

		-- Task breakdown
		table.insert(lines, "Task Sizes:")
		local size_counts = {}
		local parser = require("zortex.utils.parser")
		local lines_in_project = project.section:get_lines(context.doc.bufnr)

		for _, line in ipairs(lines_in_project) do
			local task = parser.parse_task(line)
			if task then
				local size = task.attributes and task.attributes.size or "md"
				size_counts[size] = (size_counts[size] or 0) + 1
			end
		end

		for size, count in pairs(size_counts) do
			table.insert(lines, string.format("  %s: %d tasks", size:upper(), count))
		end
	else
		table.insert(lines, "No XP data yet - complete some tasks!")
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, {
		title = "Project XP",
		timeout = 5000,
	})
end

-- =============================================================================
-- Project Management Commands
-- =============================================================================

-- Recalculate current project XP
function M.recalculate_project_xp()
	local context = workspace.get_context()
	if not context then
		vim.notify("No workspace context", vim.log.levels.ERROR)
		return
	end

	-- Find current project
	local project_section = projects_service.find_project(context.section)
	if not project_section then
		vim.notify("Not in a project", vim.log.levels.WARN)
		return
	end

	local project = projects_service.get_project(project_section, context.doc)
	if not project then
		vim.notify("Could not get project data", vim.log.levels.ERROR)
		return
	end

	-- Recalculate
	local result = xp_service.recalculate_project_xp(project)

	if result then
		vim.notify(
			string.format(
				"Project XP recalculated:\n%s\nEarned: %d/%d XP (%.1f%%)",
				project.name,
				result.earned_xp,
				result.total_xp,
				result.completion_percentage * 100
			),
			vim.log.levels.INFO
		)
	else
		vim.notify("Failed to recalculate project XP", vim.log.levels.ERROR)
	end
end

-- Recalculate all projects
function M.recalculate_all_projects()
	local doc = workspace.projects()
	if not doc then
		vim.notify("Could not access projects document", vim.log.levels.ERROR)
		return
	end

	local projects = projects_service.get_all_projects()
	local count = 0
	local total_xp = 0

	for _, project in pairs(projects) do
		local result = xp_service.recalculate_project_xp(project)
		if result then
			count = count + 1
			total_xp = total_xp + result.earned_xp
		end
	end

	vim.notify(string.format("Recalculated %d projects\nTotal XP: %d", count, total_xp), vim.log.levels.INFO)
end

-- =============================================================================
-- Task Size Commands
-- =============================================================================

-- Set project size
function M.set_project_size(size)
	local context = workspace.get_context()
	if not context then
		vim.notify("No workspace context", vim.log.levels.ERROR)
		return
	end

	-- Find current project
	local project_section = projects_service.find_project(context.section)
	if not project_section then
		vim.notify("Not in a project", vim.log.levels.WARN)
		return
	end

	-- Validate size
	local valid_sizes = { "xs", "sm", "md", "lg", "xl", "epic", "legendary", "mythic", "ultimate" }
	local size_valid = false
	for _, s in ipairs(valid_sizes) do
		if s == size then
			size_valid = true
			break
		end
	end

	if not size_valid then
		vim.notify("Invalid size. Use: xs, sm, md, lg, xl, epic, legendary, mythic, ultimate", vim.log.levels.ERROR)
		return
	end

	-- Update project heading line with size attribute
	local attributes = require("zortex.utils.attributes")
	local new_line = attributes.update_attribute(project_section.raw_text, "size", size)
	context.doc:change_line(project_section.start_line, new_line)

	-- Recalculate XP
	local project = projects_service.get_project(project_section, context.doc)
	if project then
		xp_service.recalculate_project_xp(project)
		vim.notify(string.format("Project size set to: %s", size:upper()), vim.log.levels.INFO)
	end
end

-- =============================================================================
-- Area Commands
-- =============================================================================

-- Show area XP
function M.show_area_xp()
	local area_service = require("zortex.services.areas")
	local top_areas = area_service.get_top_areas(10)

	local lines = {}
	table.insert(lines, "🗺️ Top Areas by XP")
	table.insert(lines, string.rep("─", 40))

	for i, area in ipairs(top_areas) do
		table.insert(lines, string.format("%d. %s - Level %d (%d XP)", i, area.path, area.level, area.xp))
	end

	if #top_areas == 0 then
		table.insert(lines, "No areas with XP yet")
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, {
		title = "Area XP Rankings",
		timeout = 5000,
	})
end

-- =============================================================================
-- Season Commands
-- =============================================================================

-- Start a new season
function M.start_season()
	vim.ui.input({
		prompt = "Season name: ",
		default = "Q" .. os.date("%q") .. " " .. os.date("%Y"),
	}, function(name)
		if not name or name == "" then
			return
		end

		vim.ui.input({
			prompt = "Season duration (days): ",
			default = "90",
		}, function(days)
			days = tonumber(days) or 90
			local end_date = os.date("%Y-%m-%d", os.time() + (days * 86400))

			xp_service.start_season(name, end_date)
			vim.notify(string.format("Season '%s' started!\nEnds: %s", name, end_date), vim.log.levels.INFO)
		end)
	end)
end

-- End current season
function M.end_season()
	local season_record = xp_service.end_season()

	if season_record then
		local lines = {}
		table.insert(lines, string.format("Season '%s' completed!", season_record.name))
		table.insert(lines, string.rep("─", 40))
		table.insert(lines, string.format("Final Level: %d", season_record.final_level))
		table.insert(lines, string.format("Total XP: %d", season_record.final_xp))
		table.insert(lines, "")
		table.insert(lines, "XP Sources:")
		for source, amount in pairs(season_record.xp_sources) do
			table.insert(lines, string.format("  %s: %d", source:gsub("_", " "), amount))
		end

		vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, {
			title = "Season Complete!",
			timeout = 10000,
		})
	else
		vim.notify("No active season to end", vim.log.levels.WARN)
	end
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup()
	-- Register commands
	vim.api.nvim_create_user_command("ZortexXP", function(opts)
		local subcmd = opts.args

		if subcmd == "overview" or subcmd == "" then
			M.show_xp_overview()
		elseif subcmd == "project" then
			M.show_project_xp()
		elseif subcmd == "recalc" then
			M.recalculate_project_xp()
		elseif subcmd == "recalcall" then
			M.recalculate_all_projects()
		elseif subcmd == "areas" then
			M.show_area_xp()
		elseif subcmd == "season start" then
			M.start_season()
		elseif subcmd == "season end" then
			M.end_season()
		else
			vim.notify("Unknown subcommand: " .. subcmd, vim.log.levels.ERROR)
		end
	end, {
		nargs = "*",
		complete = function(_, cmdline, _)
			local parts = vim.split(cmdline, "%s+")
			if #parts == 2 then
				return { "overview", "project", "recalc", "recalcall", "areas", "season" }
			elseif #parts == 3 and parts[2] == "season" then
				return { "start", "end" }
			end
			return {}
		end,
		desc = "XP system commands",
	})

	-- Task size commands
	vim.api.nvim_create_user_command("ZortexTaskSize", function(opts)
		local tasks = require("zortex.services.tasks")
		tasks.set_current_task_size(opts.args)
	end, {
		nargs = 1,
		complete = function()
			return { "xs", "sm", "md", "lg", "xl" }
		end,
		desc = "Set task size",
	})

	-- Project size commands
	vim.api.nvim_create_user_command("ZortexProjectSize", function(opts)
		M.set_project_size(opts.args)
	end, {
		nargs = 1,
		complete = function()
			return { "xs", "sm", "md", "lg", "xl", "epic", "legendary", "mythic", "ultimate" }
		end,
		desc = "Set project size",
	})
end

return M
