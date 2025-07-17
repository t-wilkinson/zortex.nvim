-- modules/progress.lua - Main progress tracking coordinator
local M = {}

local fs = require("zortex.core.filesystem")
local projects = require("zortex.modules.projects")
local objectives = require("zortex.modules.objectives")
local tasks = require("zortex.modules.tasks")
local xp_core = require("zortex.xp.core")

-- =============================================================================
-- Project Progress
-- =============================================================================

-- Update progress for all projects
function M.update_all_projects()
	local projects_file = fs.get_projects_file()
	if projects_file and fs.file_exists(projects_file) then
		local bufnr = vim.fn.bufadd(projects_file)
		vim.fn.bufload(bufnr)
		return projects.update_progress(bufnr)
	end
	return false
end

-- =============================================================================
-- Combined Updates
-- =============================================================================

-- Update all progress (projects + OKRs)
function M.update_all_progress()
	local project_updated = M.update_all_projects()
	local okr_updated = M.update_okr_progress()

	if project_updated or okr_updated then
		vim.notify("Updated all progress tracking", vim.log.levels.INFO)
	else
		vim.notify("No progress updates needed", vim.log.levels.INFO)
	end

	return project_updated or okr_updated
end

-- =============================================================================
-- Statistics & Display
-- =============================================================================

-- Show combined statistics
function M.show_stats()
	local lines = {}

	-- Header
	table.insert(lines, "📊 Zortex Progress Statistics")
	table.insert(lines, string.rep("═", 50))
	table.insert(lines, "")

	-- Task stats
	local task_stats = tasks.get_stats()
	table.insert(lines, "📋 Tasks:")
	table.insert(lines, string.format("   Total: %d", task_stats.total_tasks))
	table.insert(
		lines,
		string.format(
			"   Completed: %d (%.0f%%)",
			task_stats.completed_tasks,
			task_stats.total_tasks > 0 and (task_stats.completed_tasks / task_stats.total_tasks * 100) or 0
		)
	)
	table.insert(lines, string.format("   XP Earned: %s", xp_core.format_xp(task_stats.total_xp_awarded)))
	table.insert(lines, "")

	-- Project stats
	projects.load()
	local project_stats = projects.get_all_stats()
	table.insert(lines, "📁 Projects:")
	table.insert(lines, string.format("   Total: %d", project_stats.project_count))

	if next(project_stats.projects_by_level) then
		table.insert(lines, "   By Level:")
		for level = 1, 6 do
			local count = project_stats.projects_by_level[level] or 0
			if count > 0 then
				table.insert(lines, string.format("     Level %d: %d", level, count))
			end
		end
	end
	table.insert(lines, "")

	-- Objective stats
	local obj_stats = objectives.get_objective_stats()
	if obj_stats then
		table.insert(lines, "🎯 Objectives:")
		table.insert(lines, string.format("   Total: %d", obj_stats.total))
		table.insert(
			lines,
			string.format("   Completed: %d (%.0f%%)", obj_stats.completed, obj_stats.completion_rate * 100)
		)

		if next(obj_stats.by_span) then
			table.insert(lines, "   By Time Span:")
			local spans = { "daily", "weekly", "monthly", "quarterly", "yearly" }
			for _, span in ipairs(spans) do
				local data = obj_stats.by_span[span]
				if data and data.total > 0 then
					table.insert(
						lines,
						string.format(
							"     %s: %d/%d",
							span:sub(1, 1):upper() .. span:sub(2),
							data.completed,
							data.total
						)
					)
				end
			end
		end
		table.insert(lines, "")
	end

	-- Season status
	local season_status = require("zortex.xp.projects").get_season_status()
	if season_status then
		table.insert(lines, "🏆 Current Season:")
		table.insert(lines, string.format("   Name: %s", season_status.season.name))
		table.insert(lines, string.format("   Level: %d", season_status.level))
		if season_status.current_tier then
			table.insert(lines, string.format("   Tier: %s", season_status.current_tier.name))
		end
		table.insert(lines, string.format("   Progress: %.0f%% to next level", season_status.progress_to_next * 100))
		table.insert(lines, "")
	end

	-- Top areas
	local top_areas = require("zortex.modules.areas").get_top_areas(5)
	if #top_areas > 0 then
		table.insert(lines, "🏔️  Top Areas:")
		for i, area in ipairs(top_areas) do
			table.insert(
				lines,
				string.format("   %d. %s - Level %d (%s XP)", i, area.path, area.level, xp_core.format_xp(area.xp))
			)
		end
	end

	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- =============================================================================
-- Maintenance
-- =============================================================================

-- Force reload all data
function M.reload_all()
	-- Reload stores
	require("zortex.stores.xp").reload()
	require("zortex.stores.tasks").reload()

	-- Reload file data
	projects.load()

	vim.notify("Reloaded all progress data", vim.log.levels.INFO)
end

-- =============================================================================
-- Autocommands Setup
-- =============================================================================

function M.setup_autocommands()
	local group = vim.api.nvim_create_augroup("ZortexProgress", { clear = true })

	-- Auto-update progress on save
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*/projects.zortex",
		callback = function(ev)
			projects.update_progress(ev.buf)
		end,
		desc = "Update project progress on save",
	})

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*/okr.zortex",
		callback = function()
			M.update_okr_progress()
		end,
		desc = "Update OKR progress on save",
	})
end

return M
