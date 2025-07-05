-- Main entry point for Zortex XP system
local M = {}

-- Load modules
M.state = require("zortex.xp.state")
M.parser = require("zortex.xp.parser")
M.graph = require("zortex.xp.graph")
M.calculator = require("zortex.xp.calculator")
M.tracker = require("zortex.xp.tracker")
M.ui = require("zortex.xp.ui")
M.badges = require("zortex.xp.badges")
M.audit = require("zortex.xp.audit")

-- Cache for file modification times
M._file_cache = {}

-- Get config from main config module
function M.get_config()
	local config = require("zortex.config")
	return config.get("xp") or config.defaults.xp
end

-- Check if graph needs rebuilding
function M.needs_graph_rebuild()
	local notes_dir = vim.g.zortex_notes_dir
	local extension = vim.g.zortex_extension
	local files = vim.fn.globpath(notes_dir, "**/*" .. extension, false, true)

	local needs_rebuild = false

	for _, filepath in ipairs(files) do
		local stat = vim.loop.fs_stat(filepath)
		if stat then
			local cached_mtime = M._file_cache[filepath]
			if not cached_mtime or cached_mtime < stat.mtime.sec then
				needs_rebuild = true
				M._file_cache[filepath] = stat.mtime.sec
			end
		end
	end

	return needs_rebuild
end

-- Check if task was completed
function M.check_task_completion()
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_get_current_line()
	local filepath = vim.fn.expand("%:p")

	-- Create unique key for this line
	local line_key = string.format("%s:%d", filepath, line_num)

	-- Debug: log what we're checking
	if vim.g.zortex_debug then
		vim.notify("Checking line: " .. line, "debug", { title = "Zortex XP Debug" })
	end

	-- First check if this is a checkbox line
	local checkbox_pattern = "^%s*%- %[(.?)%]"
	local checkbox_match = line:match(checkbox_pattern)

	if checkbox_match then
		-- This is a checkbox line
		local is_completed = checkbox_match ~= " " and checkbox_match ~= ""
		local was_completed = M.state.get_line_state(line_key) or false

		if vim.g.zortex_debug then
			vim.notify(
				string.format(
					"Checkbox: '%s', completed: %s, was: %s",
					checkbox_match,
					tostring(is_completed),
					tostring(was_completed)
				),
				"debug",
				{ title = "Zortex XP Debug" }
			)
		end

		-- Check if status changed
		if is_completed and not was_completed then
			-- Task was just completed
			local task_text = line:match("%- %[.?%]%s*(.+)")
			if task_text then
				task_text = task_text:gsub("^%s+", ""):gsub("%s+$", "")

				if vim.g.zortex_debug then
					vim.notify("Task completed: " .. task_text, "info", { title = "Zortex XP Debug" })
				end

				-- Process the completion
				M.process_task_completion(filepath, line, line_num, task_text, true)
			else
				if vim.g.zortex_debug then
					vim.notify("Warning: Could not extract task text from line", "warn", { title = "Zortex XP Debug" })
				end
			end
		elseif not is_completed and was_completed then
			-- Task was unchecked
			if vim.g.zortex_debug then
				vim.notify("Task unchecked", "debug", { title = "Zortex XP Debug" })
			end
		end

		-- Update state
		M.state.set_line_state(line_key, is_completed)
		return
	end

	-- Check other completion patterns
	local patterns = {
		{ pattern = "^%s*%* DONE", extract = "%* DONE%s+(.+)" },
		{ pattern = "^%s*✓", extract = "^%s*✓%s*(.+)" },
		{ pattern = "@done", extract = "(.+)%s*@done" },
		{ pattern = "@completed", extract = "(.+)%s*@completed" },
	}

	for _, p in ipairs(patterns) do
		if line:match(p.pattern) then
			local was_completed = M.state.get_line_state(line_key) or false

			if not was_completed then
				-- Extract task text
				local task_text = line:match(p.extract)
				if task_text then
					task_text = task_text:gsub("^%s+", ""):gsub("%s+$", "")

					if vim.g.zortex_debug then
						vim.notify("Task completed (pattern): " .. task_text, "info", { title = "Zortex XP Debug" })
					end

					-- Process the completion
					M.process_task_completion(filepath, line, line_num, task_text, true)
				end

				-- Mark as completed
				M.state.set_line_state(line_key, true)
			end
			return
		end
	end
end

-- Process a task completion
function M.process_task_completion(filepath, line, line_num, task_text, completed)
	-- Only rebuild graph if files have changed
	if M.needs_graph_rebuild() then
		M.graph.build()
	else
		M.graph.ensure_built()
	end

	-- Parse current file
	local file_data = M.parser.parse_file(filepath)

	if file_data then
		-- Find matching task or create one
		local task = nil

		-- Look for exact match first
		for _, t in ipairs(file_data.tasks) do
			if t.text and t.text == task_text then
				task = t
				break
			end
		end

		-- If no match in parsed tasks, create task from current context
		if not task then
			-- Get the current article context
			local current_article = nil
			local lines = vim.api.nvim_buf_get_lines(0, 0, line_num, false)

			-- Find the most recent article header
			for i = #lines, 1, -1 do
				if lines[i]:match("^@@") then
					current_article = lines[i]:match("^@@%s*(.+)")
					break
				end
			end

			task = {
				type = "task",
				text = task_text,
				file = filepath,
				line_number = line_num,
				article = current_article,
				completed = completed,
				links = {},
			}

			-- Parse any metadata from the line
			local inline_meta = M.parser.extract_inline_metadata(line)
			for k, v in pairs(inline_meta) do
				task[k] = v
			end

			-- For project files, add some context
			if filepath:match("project") then
				task.in_project = true
				-- Try to find project name from article or filename
				if current_article then
					task.project_name = current_article
				else
					task.project_name = vim.fn.fnamemodify(filepath, ":t:r")
				end
			end
		end

		if task then
			task.completed = completed
			M.complete_task(task)
		else
			vim.notify("Could not create task for: " .. task_text, "warn", { title = "Zortex XP" })
		end
	else
		vim.notify("Could not parse file: " .. filepath, "error", { title = "Zortex XP" })
	end
end

-- Complete a task and award XP
function M.complete_task(task)
	-- Calculate XP
	local xp_breakdown = M.calculator.calculate_total_xp(task)
	local total_xp = xp_breakdown.total

	-- Update state
	M.state.award_xp(total_xp, task, xp_breakdown)

	-- Track task completion for habits/resources
	M.tracker.track_completion(task)

	-- Check for new badges
	M.badges.check_all()

	-- Save state
	M.state.save()

	-- Show notification
	M.ui.notify_xp_gain(xp_breakdown)

	return total_xp
end

-- Setup function
function M.setup()
	-- Initialize modules
	M.state.load()

	-- Build graph in background to avoid blocking
	vim.defer_fn(function()
		M.graph.build()
		vim.notify("Zortex XP system ready!", "info", { title = "Zortex XP" })
	end, 100)

	M.tracker.initialize()

	-- Create commands
	local cmd = vim.api.nvim_create_user_command

	cmd("ZortexXP", function()
		M.graph.ensure_built()
		M.ui.show_dashboard()
	end, { desc = "Show Zortex XP Dashboard" })

	cmd("ZortexAnalytics", function()
		M.graph.ensure_built()
		M.ui.show_analytics()
	end, { desc = "Show Zortex Analytics" })

	cmd("ZortexAudit", function()
		M.graph.ensure_built()
		M.audit.run_audit()
	end, { desc = "Audit tasks for optimization" })

	cmd("ZortexHabits", function()
		M.ui.show_habits()
	end, { desc = "Show habit tracker" })

	cmd("ZortexResources", function()
		M.ui.show_resources()
	end, { desc = "Show resource tracker" })

	cmd("ZortexBudget", function()
		M.ui.show_budget()
	end, { desc = "Show budget tracker" })

	cmd("ZortexRebuild", function()
		-- Clear cache to force rebuild
		M._file_cache = {}
		M.graph.build()
		vim.notify("Graph rebuilt successfully", "info", { title = "Zortex XP" })
	end, { desc = "Rebuild the task graph" })

	-- Debug command
	cmd("ZortexDebug", function()
		local old_debug = vim.g.zortex_debug
		vim.g.zortex_debug = true
		local line = vim.api.nvim_get_current_line()
		local filepath = vim.fn.expand("%:p")
		vim.notify("Current line: " .. line .. "\nFile: " .. filepath, "info", { title = "Zortex Debug" })
		M.check_task_completion()
		vim.g.zortex_debug = old_debug
	end, { desc = "Debug current line" })

	cmd("ZortexTaskInfo", function()
		local line = vim.api.nvim_get_current_line()
		local parser = require("zortex.xp.parser")
		local metadata = parser.extract_inline_metadata(line)

		print("Line: " .. line)
		print("Metadata: " .. vim.inspect(metadata))

		-- Check if it matches task patterns
		local patterns = {
			"^%s*%- %[x%]",
			"^%s*%* DONE",
			"^%s*✓",
			"@done",
			"@completed",
		}

		for _, pattern in ipairs(patterns) do
			if line:match(pattern) then
				print("Matches pattern: " .. pattern)
			end
		end
	end, { desc = "Debug task info for current line" })

	-- cmd("ZortexTestParser", function()
	-- 	local filepath = vim.fn.expand("%:p")
	-- 	local parser = require("zortex.xp.parser")
	-- 	local file_data = parser.parse_file(filepath)
	--
	-- 	if file_data then
	-- 		vim.notify(string.format("Parsed file: %s\nTasks found: %d\nArticles: %d",
	-- 			filepath,
	-- 			#file_data.tasks,
	-- 			#file_data.articles),
	-- 			"info",
	-- 			{ title = "Parser Test" })
	--
	-- 		-- Show first few tasks
	-- 		for i = 1, math.min(3, #file_data.tasks) do
	-- 			local task = file_data.tasks[i]
	-- 			vim.notify(string.format("Task %d: '%s' (completed: %s)",
	-- 				i,
	-- 				task.text or "NO TEXT",
	-- 				tostring(task.completed)),
	-- 				"info")
	-- 		end
	-- 	else
	-- 		vim.notify("Failed to parse file", "error")
	--   end, { title = "Parser Test" })
	cmd("ZortexTestCompletion", function()
		-- Create a test task in current buffer
		local line_num = vim.api.nvim_win_get_cursor(0)[1]
		vim.api.nvim_buf_set_lines(0, line_num - 1, line_num, false, { "- [ ] Test task for XP system" })

		-- Wait a moment
		vim.defer_fn(function()
			-- Complete the task
			vim.api.nvim_buf_set_lines(0, line_num - 1, line_num, false, { "- [x] Test task for XP system" })

			-- Trigger check
			vim.defer_fn(function()
				M.check_task_completion()
			end, 50)
		end, 100)

		vim.notify(
			"Created and completed test task. You should see XP notification...",
			"info",
			{ title = "Zortex Test" }
		)
	end, { desc = "Test task completion" })

	-- Autocmds for task detection
	local augroup = vim.api.nvim_create_augroup("ZortexXP", { clear = true })

	-- Monitor text changes
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		pattern = "*" .. vim.g.zortex_extension,
		callback = function()
			-- Use a shorter delay for better responsiveness
			vim.defer_fn(function()
				M.check_task_completion()
			end, 10)
		end,
	})

	-- Also check on cursor movement (for visual mode changes)
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = augroup,
		pattern = "*" .. vim.g.zortex_extension,
		callback = function()
			-- Only check if the line changed
			local current_line = vim.api.nvim_win_get_cursor(0)[1]
			if not M._last_line or M._last_line ~= current_line then
				M._last_line = current_line
				M.check_task_completion()
			end
		end,
	})

	-- Also check on save (for external edits)
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = "*" .. vim.g.zortex_extension,
		callback = function()
			M.check_task_completion()
		end,
	})

	-- Mark graph as dirty when files change
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = "*" .. vim.g.zortex_extension,
		callback = function()
			M.graph.mark_dirty()
		end,
	})

	-- Periodic updates
	vim.fn.timer_start(300000, function() -- Every 5 minutes
		M.tracker.update_heat()
		M.tracker.check_habits()
		M.state.save()
	end, { ["repeat"] = -1 })

	-- Daily reset
	vim.fn.timer_start(60000, function() -- Check every minute
		M.state.check_daily_reset()
	end, { ["repeat"] = -1 })
end

return M
