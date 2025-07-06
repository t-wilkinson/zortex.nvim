-- Zortex XP System - Neovim Commands and Integration
-- Add this to your Neovim configuration to enable XP commands

local M = {}
local utils = require("utils")
local config = require("config")

-- Helper function to format XP with commas
local function format_xp(xp)
	local formatted = tostring(math.floor(xp))
	return formatted:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

-- Command to show XP for current line (if it's a task)
function M.show_task_xp()
	local line = vim.api.nvim_get_current_line()
	local parsed = utils.parse_entry(line, os.date("%Y-%m-%d"))

	if parsed.task_status then
		local xp = utils.calculate_task_xp(parsed)
		local status = parsed.task_status.key == "[x]" and "Complete" or "Incomplete"

		local msg = string.format(
			"Task XP: %s (%s) | Size: %s | Priority: %s",
			format_xp(xp),
			status,
			parsed.attributes.size or config.get("xp.default_task_size") or "md",
			parsed.attributes.priority or "none"
		)

		vim.notify(msg, vim.log.levels.INFO)
	else
		vim.notify("Current line is not a task", vim.log.levels.WARN)
	end
end

-- Command to show XP summary for a date
function M.show_daily_xp(date_str)
	date_str = date_str or os.date("%Y-%m-%d")
	local entries = utils.get_entries_for_date(date_str)

	local total_xp = 0
	local completed_tasks = 0
	local pending_tasks = 0

	for _, entry in ipairs(entries) do
		if entry.task_status then
			if entry.task_status.key == "[x]" then
				total_xp = total_xp + utils.calculate_task_xp(entry)
				completed_tasks = completed_tasks + 1
			else
				pending_tasks = pending_tasks + 1
			end
		end
	end

	local msg = string.format(
		"Date: %s\nCompleted: %d tasks\nPending: %d tasks\nTotal XP: %s",
		date_str,
		completed_tasks,
		pending_tasks,
		format_xp(total_xp)
	)

	vim.notify(msg, vim.log.levels.INFO)
end

-- Command to show project XP
function M.show_project_xp(project_name)
	if not project_name or project_name == "" then
		-- Try to extract project name from current buffer
		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		for _, line in ipairs(lines) do
			local heading = line:match("^# (.+)$")
			if heading then
				project_name = heading:gsub("%s*@xp%(%d+%.?%d*%)%s*$", "")
				break
			end
		end
	end

	if not project_name then
		vim.notify("Could not determine project name", vim.log.levels.ERROR)
		return
	end

	-- Load project file to get tasks
	local content = utils.load_file(utils.PROJECTS_FILE)
	if not content then
		vim.notify("Could not load projects file", vim.log.levels.ERROR)
		return
	end

	-- Find and parse project tasks
	local in_project = false
	local project_tasks = {}

	for _, line in ipairs(content) do
		local heading = line:match("^# (.+)$")
		if heading then
			local clean_heading = heading:gsub("%s*@xp%(%d+%.?%d*%)%s*$", "")
			in_project = (clean_heading == project_name)
		elseif in_project then
			local parsed = utils.parse_entry(line, nil)
			if parsed.task_status then
				table.insert(project_tasks, parsed)
			end
		end
	end

	local project_xp = utils.calculate_project_xp(project_name, project_tasks)
	local okr_connections = utils.find_connected_okrs(project_name)

	local msg = string.format(
		"Project: %s\nTotal XP: %s\nTasks: %d\nOKR Connections: %d",
		project_name,
		format_xp(project_xp),
		#project_tasks,
		#okr_connections
	)

	if #okr_connections > 0 then
		msg = msg .. "\n\nConnected OKRs:"
		for _, conn in ipairs(okr_connections) do
			msg = msg
				.. string.format(
					"\n  • %s %s (%s)",
					conn.objective.span,
					conn.objective.title,
					conn.objective.is_current and "Current" or "Past"
				)
		end
	end

	vim.notify(msg, vim.log.levels.INFO)
end

-- Command to archive a project
function M.archive_project_interactive()
	local project_name = vim.fn.input("Project name to archive: ")
	if project_name and project_name ~= "" then
		local success = utils.archive_project(project_name)
		if success then
			-- Reload current buffer if it's the projects file
			local current_file = vim.fn.expand("%:t")
			if current_file == utils.PROJECTS_FILE then
				vim.cmd("edit!")
			end
		end
	end
end

-- Command to show weekly XP summary
function M.show_weekly_xp()
	local total_xp = 0
	local task_count = 0
	local current_date = os.date("*t")

	-- Go back 7 days
	for i = 0, 6 do
		local date = os.time(current_date) - (i * 86400)
		local date_str = os.date("%Y-%m-%d", date)
		local entries = utils.get_entries_for_date(date_str)

		for _, entry in ipairs(entries) do
			if entry.task_status and entry.task_status.key == "[x]" then
				total_xp = total_xp + utils.calculate_task_xp(entry)
				task_count = task_count + 1
			end
		end
	end

	local avg_xp = task_count > 0 and (total_xp / 7) or 0

	local msg = string.format(
		"Weekly Summary (Last 7 days)\nTotal XP: %s\nTasks Completed: %d\nDaily Average: %s XP",
		format_xp(total_xp),
		task_count,
		format_xp(avg_xp)
	)

	vim.notify(msg, vim.log.levels.INFO)
end

-- Command to show OKR graph
function M.show_okr_graph()
	local graph = utils.build_okr_graph()
	if not graph then
		vim.notify("Could not build OKR graph", vim.log.levels.ERROR)
		return
	end

	local lines = {
		"OKR Structure:",
		"",
		"Current Objectives: " .. #graph.current_objectives,
		"Previous Objectives: " .. #graph.previous_objectives,
		"",
	}

	-- Show current objectives
	if #graph.current_objectives > 0 then
		table.insert(lines, "Current:")
		for _, obj in ipairs(graph.current_objectives) do
			table.insert(
				lines,
				string.format(
					"  • %s %s - %s",
					obj.span,
					os.date("%B %Y", os.time({ year = obj.year, month = obj.month, day = 1 })),
					obj.title
				)
			)
			for _, kr in ipairs(obj.key_results) do
				local project_count = #kr.projects
				table.insert(
					lines,
					string.format(
						"    - KR: %s (%d projects)",
						kr.text:sub(1, 50) .. (string.len(kr.text) > 50 and "..." or ""),
						project_count
					)
				)
			end
		end
	end

	-- Create a floating window to display the graph
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	local width = 80
	local height = math.min(#lines + 2, 30)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
		title = " OKR Graph ",
		title_pos = "center",
	})

	-- Close with q or Esc
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { silent = true })
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", { silent = true })
end

-- Command to recalculate XP in archive
function M.recalculate_project_xp()
	utils.recalculate_xp(false)
end

-- Command to recalculate all XP in archive
function M.recalculate_all_xp()
	utils.recalculate_xp(true)
end

-- Command to finalize project XP (never recalculate)
function M.finalize_project_xp()
	local filename = vim.fn.expand("%:t")
	if filename ~= utils.ARCHIVE_PROJECTS_FILE then
		vim.notify("This command only works in archive.projects.zortex", vim.log.levels.ERROR)
		return
	end

	local cursor_line = vim.fn.line(".")
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

	-- Find current project heading
	local project_line = nil
	for i = cursor_line, 1, -1 do
		local level, heading = lines[i]:match("^(#+)%s+(.+)$")
		if level then
			project_line = i

			-- Check if already finalized
			if heading:match("@xp:final%(") then
				vim.notify("Project XP is already finalized", vim.log.levels.WARN)
				return
			end

			-- Convert @xp() to @xp:final()
			local xp = heading:match("@xp%((%d+%.?%d*)%)")
			if xp then
				local new_heading = heading:gsub("@xp%(%d+%.?%d*%)", "@xp:final(" .. xp .. ")")
				lines[i] = level .. " " .. new_heading
				vim.api.nvim_buf_set_lines(0, project_line - 1, project_line, false, { lines[i] })
				vim.notify(string.format("Finalized project XP: %s", xp), vim.log.levels.INFO)
			else
				vim.notify("No XP found to finalize", vim.log.levels.ERROR)
			end
			return
		end
	end
end

-- Command to reload configuration
function M.reload_config()
	config.load()
	utils.clear_file_cache()
	vim.notify("Zortex configuration reloaded", vim.log.levels.INFO)
end

-- Set up commands
function M.setup()
	-- Load data on startup
	utils.load()

	-- Task XP commands
	vim.api.nvim_create_user_command("ZortexTaskXP", M.show_task_xp, {})
	vim.api.nvim_create_user_command("ZortexDailyXP", function(opts)
		M.show_daily_xp(opts.args ~= "" and opts.args or nil)
	end, { nargs = "?" })

	-- Project commands
	vim.api.nvim_create_user_command("ZortexProjectXP", function(opts)
		M.show_project_xp(opts.args ~= "" and opts.args or nil)
	end, { nargs = "?" })
	vim.api.nvim_create_user_command("ZortexArchive", M.archive_project_interactive, {})

	-- Summary commands
	vim.api.nvim_create_user_command("ZortexWeeklyXP", M.show_weekly_xp, {})
	vim.api.nvim_create_user_command("ZortexOKRGraph", M.show_okr_graph, {})

	-- XP recalculation commands
	vim.api.nvim_create_user_command("ZortexRecalcXP", M.recalculate_project_xp, {})
	vim.api.nvim_create_user_command("ZortexRecalcAllXP", M.recalculate_all_xp, {})
	vim.api.nvim_create_user_command("ZortexFinalizeXP", M.finalize_project_xp, {})

	-- Config commands
	vim.api.nvim_create_user_command("ZortexReload", M.reload_config, {})

	-- Keybindings (optional - customize as needed)
	vim.api.nvim_set_keymap("n", "<leader>zx", ":ZortexTaskXP<CR>", { silent = true, desc = "Show task XP" })
	vim.api.nvim_set_keymap("n", "<leader>zd", ":ZortexDailyXP<CR>", { silent = true, desc = "Show daily XP" })
	vim.api.nvim_set_keymap("n", "<leader>zp", ":ZortexProjectXP<CR>", { silent = true, desc = "Show project XP" })
	vim.api.nvim_set_keymap("n", "<leader>za", ":ZortexArchive<CR>", { silent = true, desc = "Archive project" })
	vim.api.nvim_set_keymap("n", "<leader>zw", ":ZortexWeeklyXP<CR>", { silent = true, desc = "Show weekly XP" })
	vim.api.nvim_set_keymap("n", "<leader>zo", ":ZortexOKRGraph<CR>", { silent = true, desc = "Show OKR graph" })
	vim.api.nvim_set_keymap(
		"n",
		"<leader>zr",
		":ZortexRecalcXP<CR>",
		{ silent = true, desc = "Recalculate current project XP" }
	)
	vim.api.nvim_set_keymap("n", "<leader>zR", ":ZortexRecalcAllXP<CR>", { silent = true, desc = "Recalculate all XP" })
	vim.api.nvim_set_keymap("n", "<leader>zf", ":ZortexFinalizeXP<CR>", { silent = true, desc = "Finalize project XP" })
end

return M
