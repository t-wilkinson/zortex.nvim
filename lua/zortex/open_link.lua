local extract_link = require("zortex.extract_link")

local M = {}

-- For Neovim 0.7+ path joining, otherwise use manual concatenation.
local joinpath = vim.fs and vim.fs.joinpath
	or function(...)
		local parts = { ... }
		local path = table.remove(parts, 1)
		for _, part in ipairs(parts) do
			if path == "" or part == "" then -- Handle empty parts
				path = path .. part
			elseif path:sub(-1) ~= "/" and part:sub(1, 1) ~= "/" then
				path = path .. "/" .. part
			elseif path:sub(-1) == "/" and part:sub(1, 1) == "/" then
				path = path .. part:sub(2)
			else
				path = path .. part
			end
		end
		return path:gsub("//+", "/") -- Normalize multiple slashes
	end

--- Finds an article file based on its @@ArticleName title.
function M.find_article_file_path(article_name_query)
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir or notes_dir == "" then
		vim.notify("g:zortex_notes_dir is not set.", vim.log.levels.ERROR)
		return nil
	end

	local lower_case_query = article_name_query:lower()

	local scandir_handle = vim.loop.fs_scandir(notes_dir)
	if not scandir_handle then
		vim.notify("Could not scan directory: " .. notes_dir, vim.log.levels.WARN)
		return nil
	end

	while true do
		local name, file_type = vim.loop.fs_scandir_next(scandir_handle)
		if not name then
			break
		end

		if file_type == "file" and (name:match("%.md$") or name:match("%.zortex$") or name:match("%.txt$")) then
			local full_path = joinpath(notes_dir, name)
			local file = io.open(full_path, "r")
			if file then
				local line_num = 0
				for file_line in file:lines() do
					line_num = line_num + 1
					if line_num > 20 then
						break
					end
					if file_line:sub(1, 2) == "@@" then
						local article_title_in_file = file_line:sub(3):gsub("^%s*(.-)%s*$", "%1")
						if article_title_in_file:lower() == lower_case_query then
							file:close()
							return full_path
						end
						break
					end
				end
				file:close()
			end
		end
	end
	vim.notify("Article file not found for: " .. article_name_query, vim.log.levels.INFO)
	return nil
end

local function create_vim_search_pattern_for_target(target_type, target_text, for_global_search)
	local search_pattern
	local base_text = vim.fn.escape(target_text, "\\")

	if target_type == "heading" then
		search_pattern = "\\c^#\\+\\s*" .. base_text
	elseif target_type == "label" then
		search_pattern = "\\c^" .. base_text .. ".*:" -- Note: design doc implies LabelName is matched, not LabelName.*
		-- For `^LabelName.*:`, the `.*` is part of the line but not the ID.
		-- If `target_text` is just `LabelName`, then `^\\^` .. base_text .. ".*:" is correct.
	elseif target_type == "query" then
		if target_text:match("[A-Z]") then
			search_pattern = "\\C" .. base_text
		else
			search_pattern = "\\c" .. base_text
		end
	else -- generic
		search_pattern = "\\c" .. base_text
	end
	return search_pattern
end

local function lua_pattern_escape(text)
	if text == nil then
		return ""
	end
	return text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

function M.search_in_current_buffer(targets_to_find, current_file_path_for_msg)
	if not targets_to_find or #targets_to_find == 0 then
		vim.notify("No targets specified for search in current buffer.", vim.log.levels.INFO)
		return true
	end

	local original_cursor = vim.api.nvim_win_get_cursor(0)
	local current_search_start_line = 1

	for i, target in ipairs(targets_to_find) do
		local search_pattern
		local search_flags = "w"

		if target.type == "generic" then
			local heading_pattern = create_vim_search_pattern_for_target("heading", target.text)
			vim.api.nvim_win_set_cursor(0, { current_search_start_line, 0 })
			local found_pos = vim.fn.searchpos(heading_pattern, search_flags)

			if found_pos[1] ~= 0 and found_pos[2] ~= 0 then
				vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 })
				current_search_start_line = found_pos[1]
				if i < #targets_to_find then
					current_search_start_line = found_pos[1] + 1
				end
			else
				local label_pattern = create_vim_search_pattern_for_target("label", target.text)
				vim.api.nvim_win_set_cursor(0, { current_search_start_line, 0 })
				found_pos = vim.fn.searchpos(label_pattern, search_flags)
				if found_pos[1] ~= 0 and found_pos[2] ~= 0 then
					vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 })
					current_search_start_line = found_pos[1]
					if i < #targets_to_find then
						current_search_start_line = found_pos[1] + 1
					end
				else
					vim.notify(
						string.format(
							"Generic target '%s' not found as heading or label in %s.",
							target.text,
							current_file_path_for_msg or "current buffer"
						),
						vim.log.levels.INFO
					)
					vim.api.nvim_win_set_cursor(0, original_cursor)
					return false
				end
			end
		else
			search_pattern = create_vim_search_pattern_for_target(target.type, target.text)
			vim.api.nvim_win_set_cursor(0, { current_search_start_line, 0 })
			local found_pos = vim.fn.searchpos(search_pattern, search_flags)

			if found_pos[1] ~= 0 and found_pos[2] ~= 0 then
				vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 })
				current_search_start_line = found_pos[1]
				if i < #targets_to_find then
					current_search_start_line = found_pos[1] + 1
				end
			else
				vim.notify(
					string.format(
						"%s target '%s' (pattern: %s) not found in %s.",
						target.type,
						target.text,
						search_pattern,
						current_file_path_for_msg or "current buffer"
					),
					vim.log.levels.INFO
				)
				vim.api.nvim_win_set_cursor(0, original_cursor)
				return false
			end
		end
	end
	vim.cmd("normal! zvzz")
	return true
end

function M.search_all_articles_globally(target_type, target_text)
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir or notes_dir == "" then
		vim.notify("g:zortex_notes_dir is not set.", vim.log.levels.ERROR)
		return false
	end

	if not target_text or target_text == "" then
		vim.notify("Global search query is empty for type: " .. target_type, vim.log.levels.WARN)
		return false
	end

	local qf_list = {}
	local scandir_handle = vim.loop.fs_scandir(notes_dir)
	if not scandir_handle then
		vim.notify("Could not scan directory: " .. notes_dir, vim.log.levels.WARN)
		return false
	end

	vim.notify("Searching all articles globally for " .. target_type .. ": " .. target_text, vim.log.levels.INFO)

	local lua_search_text = lua_pattern_escape(target_text:lower())
	local lua_primary_pattern, lua_secondary_pattern
	local primary_target_description = target_type
	local secondary_target_description = nil

	if target_type == "generic" then
		lua_primary_pattern = "^#+%s*" .. lua_search_text
		primary_target_description = "heading"
		lua_secondary_pattern = "^%^" .. lua_search_text .. ".*:"
		secondary_target_description = "label"
	elseif target_type == "heading" then
		lua_primary_pattern = "^#+%s*" .. lua_search_text
	elseif target_type == "label" then
		lua_primary_pattern = "^%^" .. lua_search_text .. ".*:"
	elseif target_type == "query" then
		if target_text:match("[A-Z]") then
			lua_primary_pattern = lua_pattern_escape(target_text)
		else
			lua_primary_pattern = lua_search_text
		end
	else
		vim.notify("Unsupported target type for global search: " .. target_type, vim.log.levels.WARN)
		return false
	end

	local function find_matches_in_file(file_path, pattern, description, use_raw_line_for_search)
		local file = io.open(file_path, "r")
		if not file then
			return
		end
		local lnum = 0
		for file_line in file:lines() do
			lnum = lnum + 1
			local line_to_search = use_raw_line_for_search and file_line or file_line:lower()
			local s, e = line_to_search:find(pattern)
			if s then
				table.insert(qf_list, {
					filename = file_path,
					lnum = lnum,
					col = s,
					text = string.format("[%s: %s] %s", description, target_text, file_line:gsub("[\r\n]", "")), -- Ensure text is single line for qf
					valid = 1,
				})
			end
		end
		file:close()
	end

	while true do
		local name, file_type_info = vim.loop.fs_scandir_next(scandir_handle)
		if not name then
			break
		end

		if file_type_info == "file" and (name:match("%.md$") or name:match("%.zortex$") or name:match("%.txt$")) then
			local full_path = joinpath(notes_dir, name)
			if target_type == "query" then
				find_matches_in_file(full_path, lua_primary_pattern, "query", target_text:match("[A-Z]")) -- use raw line if query is case sensitive
			else
				find_matches_in_file(full_path, lua_primary_pattern, primary_target_description, false)
				if lua_secondary_pattern then
					find_matches_in_file(full_path, lua_secondary_pattern, secondary_target_description, false)
				end
			end
		end
	end

	if #qf_list > 0 then
		-- MODIFICATION START: Jump in original window first, then copen
		local original_win_id = vim.api.nvim_get_current_win()
		local first_match = qf_list[1]

		-- Load buffer and set cursor in the original window
		local bufnr_to_load = vim.fn.bufadd(first_match.filename) -- Ensures buffer is loaded
		vim.api.nvim_win_set_buf(original_win_id, bufnr_to_load) -- Set buffer for the original window
		vim.api.nvim_win_set_cursor(
			original_win_id,
			{ first_match.lnum, (first_match.col > 0 and first_match.col - 1 or 0) }
		)
		vim.api.nvim_win_call(original_win_id, function()
			vim.cmd("normal! zz")
		end) -- Center view in original window

		-- Now populate quickfix and open it
		vim.fn.setqflist(qf_list, "r")
		vim.cmd("copen")
		-- MODIFICATION END

		vim.notify(
			string.format(
				"Found %d potential match(es) for global search '%s'. Quickfix list populated. Jumped to first match.",
				#qf_list,
				target_text
			),
			vim.log.levels.INFO
		)
		return true
	else
		vim.notify("No matches found for global search: " .. target_text, vim.log.levels.INFO)
		return false
	end
end

function M.open_external(target)
	if not target or target == "" then
		vim.notify("Error: No target specified for open_external.", vim.log.levels.ERROR)
		return
	end
	local cmd_parts
	if vim.fn.has("macunix") == 1 then
		cmd_parts = { "open", target }
	elseif vim.fn.has("unix") == 1 and vim.fn.executable("xdg-open") then
		cmd_parts = { "xdg-open", target }
	elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		cmd_parts = { "cmd", "/c", "start", "", target:gsub("/", "\\") }
	else
		vim.notify("Unsupported OS or xdg-open not found for opening external links.", vim.log.levels.WARN)
		return
	end
	vim.fn.jobstart(cmd_parts, { detach = true })
end

-- Add this helper function to check if current buffer is a @@Structure file
local function is_structure_file()
	local first_line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
	return first_line and first_line:match("^@@Structure")
end

-- Add this helper function to ensure we have a split and return the target window
local function get_or_create_target_window()
	local current_win = vim.api.nvim_get_current_win()
	local all_wins = vim.api.nvim_list_wins()

	-- If we only have one window, create a split
	if #all_wins == 1 then
		vim.cmd("vsplit") -- Create vertical split, you can change to "split" for horizontal
		-- After split, we want to return to the original window (structure window)
		-- and the target window will be the new one
		local new_wins = vim.api.nvim_list_wins()
		for _, win in ipairs(new_wins) do
			if win ~= current_win then
				return win -- Return the new window
			end
		end
	else
		-- Find a window that's not the current one
		for _, win in ipairs(all_wins) do
			if win ~= current_win then
				return win -- Return the other window
			end
		end
	end

	-- Fallback: create a new split if we couldn't find another window
	vim.cmd("vsplit")
	local new_wins = vim.api.nvim_list_wins()
	for _, win in ipairs(new_wins) do
		if win ~= current_win then
			return win
		end
	end
end

-- Modified version of open_link that accepts a parameter for special behavior
function M.open_link_with_mode(use_split_for_structure)
	local line = vim.api.nvim_get_current_line()
	local current_filename_full = vim.fn.expand("%:p")
	local current_file_dir = vim.fn.expand("%:p:h")

	local link_info = extract_link.extract_link(line)

	if not link_info then
		vim.notify("No link found on the current line.", vim.log.levels.INFO)
		return
	end

	-- Debug info (you can remove this later)
	vim.fn.setreg("+", vim.inspect(link_info))

	-- Check if we should use structure navigation mode
	local should_use_structure_mode = use_split_for_structure and is_structure_file()
	local target_window = nil

	if should_use_structure_mode then
		target_window = get_or_create_target_window()
	end

	if link_info.type == "enhanced_link" then
		local def = link_info.definition_details
		if def.target_type == "query" then
			-- Query links always use global search regardless of structure mode
			if def.scope == "local" then
				vim.notify(
					"Local query: searching current buffer for '%"
						.. def.target_text
						.. "'. (Implement local qf population)",
					vim.log.levels.INFO
				)
				M.search_all_articles_globally("query", def.target_text)
			elseif def.scope == "article_specific" and def.article_specifier then
				vim.notify(
					"Article query: searching "
						.. def.article_specifier
						.. " for '%"
						.. def.target_text
						.. "'. (Implement article qf population)",
					vim.log.levels.INFO
				)
				M.search_all_articles_globally("query", def.target_text)
			else -- global
				M.search_all_articles_globally("query", def.target_text)
			end
			return
		end

		local targets_to_search_for = {}
		if def.chained_parts then
			targets_to_search_for = def.chained_parts
		elseif def.target_text ~= "" or def.target_type == "article_root" then
			if def.target_type == "article_root" then
				-- No further search needed in target article
			else
				table.insert(targets_to_search_for, { type = def.target_type, text = def.target_text })
			end
		else
			vim.notify("Enhanced link has no valid target text.", vim.log.levels.WARN)
			return
		end

		if def.scope == "local" then
			if #targets_to_search_for > 0 then
				if should_use_structure_mode and target_window then
					-- Stay in current window for local links in structure mode
					M.search_in_current_buffer(targets_to_search_for, current_filename_full)
				else
					M.search_in_current_buffer(targets_to_search_for, current_filename_full)
				end
			else
				vim.notify("Link to current article.", vim.log.levels.INFO)
				local win_to_use = should_use_structure_mode and vim.api.nvim_get_current_win()
					or vim.api.nvim_get_current_win()
				vim.api.nvim_win_set_cursor(win_to_use, { 1, 0 })
				vim.api.nvim_win_call(win_to_use, function()
					vim.cmd("normal! zz")
				end)
			end
		elseif def.scope == "article_specific" and def.article_specifier then
			local article_path = M.find_article_file_path(def.article_specifier)
			if article_path then
				local win_to_use = should_use_structure_mode and target_window or vim.api.nvim_get_current_win()
				local target_bufnr = vim.fn.bufadd(article_path)
				vim.api.nvim_win_set_buf(win_to_use, target_bufnr)

				-- Defer search within the new buffer to allow it to load fully
				vim.defer_fn(function()
					vim.api.nvim_set_current_win(win_to_use)
					if #targets_to_search_for > 0 then
						M.search_in_current_buffer(targets_to_search_for, article_path)
					else
						vim.api.nvim_win_set_cursor(win_to_use, { 1, 0 })
						vim.api.nvim_win_call(win_to_use, function()
							vim.cmd("normal! zz")
						end)
					end
				end, 50)
			end
		elseif def.scope == "global" then
			-- Fast-path: a bare [Article] (generic global link) should jump straight to the file
			if def.target_type == "generic" and def.target_text ~= "" then
				local article_path = M.find_article_file_path(def.target_text)
				if article_path then
					local win_to_use = should_use_structure_mode and target_window or vim.api.nvim_get_current_win()
					local bufnr = vim.fn.bufadd(article_path)
					vim.api.nvim_win_set_buf(win_to_use, bufnr)
					vim.api.nvim_win_call(win_to_use, function()
						vim.cmd("normal! ggzz")
					end)
					return
				end
			end

			if #targets_to_search_for > 0 then
				-- Global searches always use the search functionality regardless of structure mode
				M.search_all_articles_globally(targets_to_search_for[1].type, targets_to_search_for[1].text)
			else
				vim.notify("Global enhanced link without specific target.", vim.log.levels.WARN)
			end
		else
			vim.notify("Unknown scope for enhanced link: " .. def.scope, vim.log.levels.WARN)
		end
	elseif link_info.type == "file_path_heuristic" then
		local expanded_path = vim.fn.expand(link_info.path)
		if should_use_structure_mode and target_window then
			local bufnr = vim.fn.bufadd(expanded_path)
			vim.api.nvim_win_set_buf(target_window, bufnr)
		else
			vim.cmd("edit " .. vim.fn.fnameescape(expanded_path))
		end
	elseif link_info.type == "file_md_style" then
		local resolved_url = link_info.url
		if
			not (resolved_url:match("^https?://") or resolved_url:match("^/") or resolved_url:match("^[a-zA-Z]:[\\/]"))
		then
			if
				(resolved_url:sub(1, 2) == "./" or resolved_url:sub(1, 3) == "../")
				and current_file_dir
				and current_file_dir ~= ""
			then
				resolved_url = joinpath(current_file_dir, resolved_url)
			else
				local notes_dir = vim.g.zortex_notes_dir
				if notes_dir and notes_dir ~= "" then
					resolved_url = joinpath(notes_dir, resolved_url)
				end
			end
		end
		if resolved_url:match("^https?://") or not vim.fn.filereadable(vim.fn.expand(resolved_url)) then
			M.open_external(resolved_url)
		else
			if should_use_structure_mode and target_window then
				local bufnr = vim.fn.bufadd(resolved_url)
				vim.api.nvim_win_set_buf(target_window, bufnr)
			else
				vim.cmd("edit " .. vim.fn.fnameescape(resolved_url))
			end
		end
	elseif link_info.type == "footernote_ref" then
		-- Footnotes always search in current buffer regardless of structure mode
		local pattern_str = "^\\[\\^" .. vim.fn.escape(link_info.ref_id, "[].*^$\\") .. "\\]:\\s*"
		local original_cursor = vim.api.nvim_win_get_cursor(0)
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		local found_pos = vim.fn.searchpos(pattern_str, "w")

		if found_pos[1] ~= 0 and found_pos[2] ~= 0 then
			vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 })
			vim.cmd("normal! zvzz")
			-- vim.notify("Found footnote definition: [^" .. link_info.ref_id .. "]", vim.log.levels.INFO)
		else
			-- vim.notify("Footnote definition [^" .. link_info.ref_id .. "]: not found.", vim.log.levels.WARN)
			vim.api.nvim_win_set_cursor(0, original_cursor)
		end
	elseif link_info.type == "website" or link_info.type == "zortex_ref_link" then
		M.open_external(link_info.url)
	elseif
		(link_info.type == "text_heading" or link_info.type == "text_list_item")
		and link_info.name
		and link_info.name ~= ""
	then
		vim.notify(
			"Context is '" .. link_info.type .. "'. Use a dedicated command to search for this text if intended.",
			vim.log.levels.INFO
		)
	else
		vim.notify("Link type not fully handled or invalid: " .. (link_info.type or "unknown"), vim.log.levels.INFO)
	end
end

function M.open_link()
	M.open_link_with_mode(false)
end

function M.open_link_in_split()
	M.open_link_with_mode(true)
end

return M
