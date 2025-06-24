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

-- Incremental file cache for FZF searching
local file_cache = {}

-- Update the cache by loading new or modified files and dropping removed ones
local function update_file_cache()
        if not check_globals() then
                return
        end

        local dir = vim.g.zortex_notes_dir
        local ext = vim.g.zortex_extension
        local uv = vim.loop
        local handle = uv.fs_scandir(dir)
        if not handle then
                return
        end

        local seen = {}
        while true do
                local name, t = uv.fs_scandir_next(handle)
                if not name then break end
                if t == 'file' and name:sub(-#ext) == ext then
                        local path = dir .. name
                        seen[path] = true
                        local stat = uv.fs_stat(path)
                        local mtime = stat and stat.mtime.sec or 0
                        local cached = file_cache[path]
                        if not cached or cached.mtime ~= mtime then
                                local lines = {}
                                for line in io.lines(path) do
                                        table.insert(lines, line)
                                end
                                file_cache[path] = { mtime = mtime, lines = lines }
                        end
                end
        end

        for path, _ in pairs(file_cache) do
                if not seen[path] then
                        file_cache[path] = nil
                end
        end
end

-- Build the list passed to fzf from the cache
local function build_fzf_source()
        update_file_cache()

        local items = {}
        for path, data in pairs(file_cache) do
                for idx, line in ipairs(data.lines) do
                        table.insert(items, string.format('%s:%d:%s', path, idx, line))
                end
        end
        return items
end

-- Invoke fzf with exact matching over the cached lines
function M.fzf_search()
        if not check_globals() then
                return
        end

        local items = build_fzf_source()

        local spec = {
                source = items,
                options = '--multi --cycle --exact --inline-info',
                ['sink*'] = function(selected)
                        if not selected or vim.tbl_isempty(selected) then
                                return
                        end
                        local first = selected[1]
                        local filepath, lnum = string.match(first, '([^:]+):(%d+):')
                        if filepath and lnum then
                                vim.cmd('edit ' .. filepath)
                                vim.fn.cursor(tonumber(lnum), 1)
                        end
                end,
        }

        vim.fn['fzf#run'](vim.fn['fzf#wrap'](spec, 1))
end

-- Helper to escape string for PCRE2 regex fixed string embedding
local function escape_for_pcre2(s)
	-- Escapes characters that have special meaning in PCRE2 regex.
	return s:gsub("([.\\+*?%[^]%${}()|^#&~-])", "\\%1") -- Added common metacharacters
end

-- Builds the command arguments for Ripgrep
local function build_rg_command_args(prompt_text)
	local rg_args = {
		"rg",
		"--color=never",
		"--no-heading",
		"--with-filename",
		"--line-number",
		"--column",
		"--smart-case",
		"--pcre2",
	}

	local patterns_for_rg = {}
	if prompt_text and #prompt_text > 0 then
		local temp_placeholder = "__ZORTEX_LITERAL_SPACE__"
		local p_text = prompt_text:gsub("\\ ", temp_placeholder) -- Handle escaped spaces
		local terms = vim.split(p_text, "%s+") -- Split by any whitespace

		for _, term in ipairs(terms) do
			local actual_term = term:gsub(temp_placeholder, " "):gsub("^%s*(.-)%s*$", "%1") -- Restore spaces, trim
			if #actual_term > 0 then
				-- Each term is wrapped in (?=.*escaped_term) for PCRE2 AND logic
				table.insert(patterns_for_rg, "(?=.*" .. escape_for_pcre2(actual_term) .. ")")
			end
		end
	end

	if #patterns_for_rg > 0 then
		table.insert(rg_args, "-e")
		table.insert(rg_args, table.concat(patterns_for_rg)) -- All lookaheads form one regex pattern
	else
		-- If prompt is empty, search for default text (e.g., "@@") to provide initial results.
		-- This matches the `default_text` behavior of the picker.
		table.insert(rg_args, "-e")
		table.insert(rg_args, "(?=.*" .. escape_for_pcre2("@@") .. ")")
	end

	table.insert(rg_args, "--")
	table.insert(rg_args, vim.g.zortex_notes_dir)
	-- vim.notify("rg command: " .. table.concat(rg_args, " "), vim.log.levels.DEBUG)
	return rg_args
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

	pickers
		.new(opts, {
			prompt_title = "Zortex Search",
			finder = finders.new_job(build_rg_command_args, entry_maker, nil, vim.g.zortex_notes_dir),
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
