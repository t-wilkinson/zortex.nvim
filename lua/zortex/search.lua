local M = {}

-- Helper function to ensure necessary globals are set
local function check_globals()
	local missing = {}
	if not vim.g.zortex_notes_dir then
		table.insert(missing, "vim.g.zortex_notes_dir")
	end
	if not vim.g.zortex_extension then
		table.insert(missing, "vim.g.zortex_extension")
	end
	if not vim.g.zortex_bin_dir then
		table.insert(missing, "vim.g.zortex_bin_dir (path to source.py/preview.sh)")
	end

	if #missing > 0 then
		vim.notify("Zortex Search: Missing global config: " .. table.concat(missing, ", "), vim.log.levels.ERROR)
		return false
	end
	-- Ensure notes_dir ends with a slash
	if not vim.g.zortex_notes_dir:match("/$") then
		vim.g.zortex_notes_dir = vim.g.zortex_notes_dir .. "/"
	end
	return true
end

-- Function to derive basename from filetime (used by original plugin logic)
local function get_basename_from_filetime(filetime)
	if not filetime or type(filetime) ~= "string" then
		return nil
	end
	return (filetime:gsub("[ :-]", "") .. vim.g.zortex_extension)
end

-- Action: Edit note (handles different open commands)
local function action_edit_note(entry, open_cmd)
	open_cmd = open_cmd or "edit"
	if not entry or not entry.data or not entry.data.filetime then
		vim.notify("Zortex Search: Invalid entry for editing.", vim.log.levels.WARN)
		return
	end
	local basename = get_basename_from_filetime(entry.data.filetime)
	if basename then
		vim.cmd(open_cmd .. " " .. vim.g.zortex_notes_dir .. basename)
	else
		vim.notify(
			"Zortex Search: Could not determine file for entry: " .. (entry.display or "Unknown"),
			vim.log.levels.WARN
		)
	end
end

local function action_create_new_note(prompt_bufnr)
	local telescope_actions = require("telescope.actions")
	telescope_actions.close(prompt_bufnr)

	local new_filename = os.date("%Y%W%u%H%M%S") .. vim.g.zortex_extension -- YYYYWWDHHMMSS.ext
	local f_path = vim.g.zortex_notes_dir .. new_filename

	-- Default command to open new notes, can be configured if needed
	local open_cmd = "edit"

	vim.cmd(open_cmd .. " " .. f_path)

	-- Defer content insertion to ensure file is fully opened and ready
	vim.defer_fn(function()
		vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- Go to line 1, col 0
		vim.api.nvim_put({ "@@" }, "l", true, true) -- Put "@@" on the line, stay in normal mode
		vim.cmd("normal! $") -- Move cursor to end of "@@"
		vim.cmd("startinsert") -- Enter insert mode
	end, 100) -- Small delay
end

-- Action: Delete notes
local function action_delete_notes(selected_entries)
	if not selected_entries or #selected_entries == 0 then
		vim.notify("Zortex Search: No notes selected for deletion.", vim.log.levels.INFO)
		return
	end

	local basenames_to_delete = {}
	for _, entry in ipairs(selected_entries) do
		if entry and entry.data and entry.data.filetime then
			local basename = get_basename_from_filetime(entry.data.filetime)
			if basename then
				table.insert(basenames_to_delete, basename)
			end
		end
	end

	if #basenames_to_delete == 0 then
		vim.notify("Zortex Search: Could not determine files for selected entries.", vim.log.levels.WARN)
		return
	end

	local choice = vim.fn.confirm("Delete " .. table.concat(basenames_to_delete, ", ") .. "?", "&Yes\n&No", 2) -- Default to No
	if choice == 1 then -- Yes
		for _, basename in ipairs(basenames_to_delete) do
			local filepath = vim.g.zortex_notes_dir .. basename

			-- Delete buffer if loaded and unchanged
			local bufnr = vim.fn.bufnr(filepath)
			if bufnr ~= -1 then
				local buf_info_list = vim.fn.getbufinfo(bufnr)
				if #buf_info_list > 0 then
					local buf_info = buf_info_list[1]
					if buf_info.loaded and buf_info.changed == 0 then
						vim.cmd("bdelete! " .. bufnr)
					elseif buf_info.changed == 1 then
						vim.notify(
							"Zortex Search: Buffer for " .. basename .. " has unsaved changes. Not deleting buffer.",
							vim.log.levels.WARN
						)
					end
				end
			end

			-- Delete file
			local ok, err = os.remove(filepath)
			if not ok then
				vim.notify(
					"Zortex Search: Error deleting file " .. filepath .. ": " .. (err or "unknown error"),
					vim.log.levels.ERROR
				)
			else
				vim.notify("Zortex Search: Deleted " .. filepath, vim.log.levels.INFO)
			end
		end
		-- Telescope is already closed. Next search will reflect changes.
	end
end

local function generate_rg_prompt(prompt)
	local placeholder = "_UR_MUM_SUX_XD_"
	-- Treat "\ " as literal space
	-- Otherwise, treat spaces as different patterns to all be matched.
	local clean = prompt:gsub("\\ ", placeholder)
	local words = vim.split(clean, "%s+")

	local args = {}
	for _, word in ipairs(words) do
		if word:find(placeholder, 1, true) then
			word = word:gsub(placeholder, " ")
		end
		table.insert(args, "(?=.*" .. word .. ")")
		-- table.insert(args, "-e")
		-- table.insert(args, word)
	end

	return args
end

function M.search(opts)
	opts = opts or {}

	if not check_globals() then
		return
	end

	local telescope = require("telescope")
	local telescope_actions = require("telescope.actions")
	local finders = require("telescope.finders")
	local pickers = require("telescope.pickers")
	-- local layout_strategies = require("telescope.pickers.layout_strategies")
	-- local previewers = require("telescope.previewers")
	local conf = require("telescope.config").values
	local utils = require("telescope.utils")
	local flatten = utils.flatten

	-- Command to get the list of items from your source.py script
	local source_command_parts = {
		vim.g.zortex_bin_dir .. "source.py",
		vim.g.zortex_notes_dir,
		vim.g.zortex_extension,
	}

	-- Path to your preview.sh script
	local preview_script_path = vim.g.zortex_bin_dir .. "preview.sh"
	local vimgrep_arguments =
		{ "rg", "--color=never", "--no-heading", "--with-filename", "--line-number", "--column", "--smart-case" }

	local entry_maker = function(line)
		-- Expected rg output: filename:lineno:colno:text
		local parts = vim.split(line, ":", { plain = true, max = 4 })
		if #parts < 4 then
			vim.notify("Zortex Search (rg): Could not parse line: " .. line, vim.log.levels.DEBUG)
			return nil
		end

		local path = parts[1]
		local lnum = tonumber(parts[2])
		local col = tonumber(parts[3])
		local matched_text = parts[4]

		if not lnum or not col then
			return nil
		end

		local display_filename = vim.fn.fnamemodify(path, ":t")
		return {
			filename = path,
			lnum = lnum,
			col = col,
			text = matched_text,

			value = line,
			-- display = string.format("%s:%d:%d | %s", display_filename, lnum, col, matched_text),
			display = display_filename .. " | " .. matched_text,
			ordinal = line,

			-- data = {} -- Add custom data here if needed by specific actions not covered by standard fields
		}
	end

	local zortex_searcher = finders.new_job(function(prompt)
		if not prompt then
			prompt = ""
		end

		vim.notify("Initial prompt received: " .. vim.inspect(prompt), vim.log.levels.DEBUG)
		prompt = generate_rg_prompt(prompt)
		vim.notify(table.concat(prompt, ","), vim.log.levels.DEBUG)
		return flatten({ vimgrep_arguments, "--pcre2", "-e", table.concat(prompt), "--", vim.g.zortex_notes_dir })
	end, entry_maker, nil, vim.g.zortex_notes_dir)

	pickers
		.new(opts, {
			prompt_title = "Zortex Search",
			finder = zortex_searcher,
			sorter = conf.generic_sorter({}),
			previewer = conf.grep_previewer(opts),
			-- previewer = previewers.new_buffer_previewer({
			-- 	get_command = function(entry, _)
			-- 		-- preview.sh expects: <script> <extension> <selected_line_value>
			-- 		return { preview_script_path, vim.g.zortex_extension, entry.value }
			-- 	end,
			-- }),
			attach_mappings = function(prompt_bufnr, map)
				telescope_actions.select_default:replace(function()
					local selection = telescope_actions.get_selected_entry()
					telescope_actions.close(prompt_bufnr)
					action_edit_note(selection, "edit")
				end)
				map("n", "<CR>", telescope_actions.select_default)
				map("n", "q", function()
					telescope_actions.close(prompt_bufnr)
				end)

				-- -- Open in split, vsplit, tab
				-- map("n", "<C-s>", function()
				-- 	local selection = telescope_actions.get_selected_entry()
				-- 	telescope_actions.close(prompt_bufnr)
				-- 	action_edit_note(selection, "split")
				-- end)
				-- map("n", "<C-v>", function()
				-- 	local selection = telescope_actions.get_selected_entry()
				-- 	telescope_actions.close(prompt_bufnr)
				-- 	action_edit_note(selection, "vsplit")
				-- end)
				-- map("n", "<C-t>", function()
				-- 	local selection = telescope_actions.get_selected_entry()
				-- 	telescope_actions.close(prompt_bufnr)
				-- 	action_edit_note(selection, "tabedit")
				-- end)

				-- -- Multi-selection delete action
				-- map("n", "<C-d>", function()
				-- 	local selections = telescope_actions.get_multiple_selection(prompt_bufnr)
				-- 	telescope_actions.close(prompt_bufnr)
				-- 	-- Defer confirm dialog until Telescope UI is fully closed
				-- 	vim.defer_fn(function()
				-- 		action_delete_notes(selections)
				-- 	end, 50)
				-- end)

				map("n", "<C-o>", function()
					action_create_new_note(prompt_bufnr) -- This function handles closing Telescope
				end)

				-- -- Standard Telescope multi-selection mappings (Tab/Shift-Tab in Normal and Insert modes)
				-- map("n", "<Tab>", telescope_actions.toggle_selection + telescope_actions.move_selection_next)
				-- map("n", "<S-Tab>", telescope_actions.toggle_selection + telescope_actions.move_selection_previous)
				-- map("i", "<Tab>", telescope_actions.toggle_selection + telescope_actions.move_selection_next)
				-- map("i", "<S-Tab>", telescope_actions.toggle_selection + telescope_actions.move_selection_previous)

				-- -- Toggle all selections (similar to fzf's alt-a) and clear selections
				-- map("n", "<C-a>", telescope_actions.select_all)
				-- map("n", "<C-c>", telescope_actions.drop_all_selection) -- Or clear_all_selection

				return true -- Mark mappings as handled
			end,
			layout_strategy = "cursor",
			layout_config = {
				width = 0.9,
				height = 0.8,
				preview_width = 0.55,
			},
			default_text = "@@",
			multi = true,
			cycle = true,
			exact = true,
			-- inline_info = true,
			-- +s, (sort by score) is Telescope's default behavior.
		})
		:find()
end

M.search()
return M
