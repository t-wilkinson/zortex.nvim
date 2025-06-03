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

-- Pre-compile regex objects for performance in iterative matching
M.regex_iterators = {
	zettel = vim.regex("\\v\\[(z:\\d{4}\\.\\d{5}\\.\\d{5})]"),
	footernote_ref = vim.regex("\\[\\^([%w_.-]+)]"), -- Captures identifier in [^id]
	label_def = vim.regex("^\\^([%w_.-]+).*:"), -- Captures LabelName from ^LabelName.*:
}

M.patterns = {
	website = "\\vhttps?://[^);}]+",
	file_markdown_style = "\\v\\[([^]]*)]\\(([^)]+)\\)",
	zortex_link = "\\vref=([^\\s;}]+)",
	enhanced_link = "\\[(?:([^]|]+)\\|)?([^]]+)]", -- Lua pattern
	file_path = "\\v(^|\\s)([~.]?/[/\\S]+)($|\\s)",
	heading = "\\v^#+ (.*)$",
	list_item = "\\v^(\\s*)- (.*)$",
}

local function get_cursor_col_0idx()
	return vim.api.nvim_win_get_cursor(0)[2]
end

local function slugify_heading_text(text)
	if not text then return "" end
	local slug = text:lower()
	slug = slug:gsub("[^%w%s-]", "")
	slug = slug:gsub("%s+", "-")
	slug = slug:gsub("-+", "-")
	slug = slug:gsub("^-", "")
	slug = slug:gsub("-$", "")
	return slug
end

local function extract_link_iteratively(line, cursor_col_0idx, regex_obj, type_name, result_builder)
	local search_offset_0idx = 0
	local final_match_data = nil
	-- DEBUG: Log entry into function for footnotes
	if type_name == "footernote_ref" then
		vim.notify("FootnoteIter: ENTER. Line: '" .. line .. "', CursorCol: " .. cursor_col_0idx, vim.log.levels.DEBUG)
	end

	while search_offset_0idx < #line do
		local captures = regex_obj:match_str(line, search_offset_0idx)
		if not captures then
			if type_name == "footernote_ref" then vim.notify("FootnoteIter: regex_obj:match_str found NO captures. Offset: " .. search_offset_0idx, vim.log.levels.DEBUG) end
			break
		end
		local full_match_info = captures[1]
		if not full_match_info then
			if type_name == "footernote_ref" then vim.notify("FootnoteIter: captures[1] (full_match_info) is nil.", vim.log.levels.DEBUG) end
			break
		end

		local group_infos = {}
		for i = 2, #captures do
			table.insert(group_infos, captures[i]) -- Allow nil if optional group didn't match
		end

		local match_start_0idx, match_end_0idx = full_match_info[1], full_match_info[2]
		if type_name == "footernote_ref" then
			local matched_text = string.sub(line, match_start_0idx + 1, match_end_0idx)
			vim.notify("FootnoteIter: Found potential '" .. matched_text .. "' at [" .. match_start_0idx .. "," .. match_end_0idx .. "). Cursor " .. cursor_col_0idx, vim.log.levels.DEBUG)
		end

		if cursor_col_0idx >= match_start_0idx and cursor_col_0idx < match_end_0idx then
			if type_name == "footernote_ref" then vim.notify("FootnoteIter: Cursor IS in range.", vim.log.levels.DEBUG) end
			final_match_data = result_builder(line, {
				full_match_text = string.sub(line, match_start_0idx + 1, match_end_0idx),
				group_texts = vim.tbl_map(function(info)
					if info then return string.sub(line, info[1] + 1, info[2]) else return nil end
				end, group_infos)
			}, type_name)
			break
		else
			if type_name == "footernote_ref" then vim.notify("FootnoteIter: Cursor NOT in range.", vim.log.levels.DEBUG) end
		end
		search_offset_0idx = match_end_0idx
		if search_offset_0idx >= #line then break end
	end

	-- DEBUG: Log result before returning for footnotes
	if type_name == "footernote_ref" then
		if final_match_data then
			vim.notify("FootnoteIter: EXIT. Match SUCCESS. ID: " .. (final_match_data.ref_id or "N/A_IN_FINAL_DATA"), vim.log.levels.DEBUG)
		else
			vim.notify("FootnoteIter: EXIT. Match FAILED (final_match_data is nil).", vim.log.levels.DEBUG)
		end
	end
	return final_match_data
end

function M.parse_link_definition(link_definition)
	if not link_definition or link_definition == "" then return nil end
	local result = {
		original_definition = link_definition, article_specifier = nil, target_specifier = "",
		target_type = "generic", target_text = "", scope = "global", chained_parts = nil,
	}
	local definition_to_parse = link_definition
	local captured_article_name, position_after_slash = definition_to_parse:match("^([^/]+)/()")
	if captured_article_name then
		result.article_specifier = captured_article_name
		definition_to_parse = position_after_slash and definition_to_parse:sub(position_after_slash) or ""
		result.scope = "article_specific"
	elseif definition_to_parse:sub(1, 1) == "/" then
		result.scope = "local"
		definition_to_parse = definition_to_parse:sub(2)
	else
		result.scope = "global"
	end
	result.target_specifier = definition_to_parse
	local chained_match_pos = result.target_specifier:match("/:()")
	if chained_match_pos then
		result.chained_parts = {}
		local primary_target_full = result.target_specifier:sub(1, chained_match_pos - 3)
		local secondary_target_label_name = result.target_specifier:sub(chained_match_pos)
		if primary_target_full:sub(1,1) == "#" then
			table.insert(result.chained_parts, {type = "heading", text = primary_target_full:sub(2), original = primary_target_full})
		else
			vim.notify("Invalid chained link: Primary target must be a heading. Found: " .. primary_target_full, vim.log.levels.WARN)
			return nil
		end
		table.insert(result.chained_parts, {type = "label", text = secondary_target_label_name, original = ":" .. secondary_target_label_name})
		result.target_type = "chained_label"
		result.target_text = result.target_specifier
		return result
	end
	if result.target_specifier:sub(1, 1) == "#" then
		result.target_type = "heading"; result.target_text = result.target_specifier:sub(2)
	elseif result.target_specifier:sub(1, 1) == ":" then
		result.target_type = "label"; result.target_text = result.target_specifier:sub(2)
	elseif result.target_specifier:sub(1, 1) == "%" then
		result.target_type = "query"; result.target_text = result.target_specifier:sub(2)
	else
		result.target_type = "generic"; result.target_text = result.target_specifier
	end
	if result.target_text == "" and result.target_type ~= "generic" then
		if result.scope == "local" and result.target_specifier == "" then
			result.target_type = "article_root"
		else
			vim.notify("Warning: Link target text is empty for type " .. result.target_type, vim.log.levels.WARN)
		end
	end
	return result
end

function M.extract_link(line)
	local match_list
	local cursor_col_0idx

	local function ensure_cursor_col()
		if not cursor_col_0idx then cursor_col_0idx = get_cursor_col_0idx() end
	end

	ensure_cursor_col()
	vim.notify("M.extract_link: ENTER. Line: '" .. line .. "' CursorCol: " .. cursor_col_0idx, vim.log.levels.DEBUG)


	local zettel_match = extract_link_iteratively(line, cursor_col_0idx, M.regex_iterators.zettel, "zettel_id_link",
		function(l, captures, type_n)
			return { line = l, type = type_n, zettel_id = captures.group_texts[1], display_text = captures.full_match_text, full_match_text = captures.full_match_text }
		end)
	if zettel_match then vim.notify("M.extract_link: Zettel match found.", vim.log.levels.DEBUG); return zettel_match end

	local footernote_ref_match = extract_link_iteratively(line, cursor_col_0idx, M.regex_iterators.footernote_ref, "footernote_ref",
		function(l, captures, type_n)
			return { line = l, type = type_n, ref_id = captures.group_texts[1], display_text = captures.full_match_text, full_match_text = captures.full_match_text }
		end)

	if footernote_ref_match then
		vim.notify("M.extract_link: footernote_ref_match IS NOT NIL. Type: " .. footernote_ref_match.type .. ", ID: " .. footernote_ref_match.ref_id, vim.log.levels.DEBUG)
		return footernote_ref_match
	else
		vim.notify("M.extract_link: footernote_ref_match IS NIL. Proceeding to other link types.", vim.log.levels.DEBUG)
	end

	local offset = 0
	while offset < #line do
		local s, e, name, url = string.find(line, M.patterns.file_markdown_style, offset + 1)
		if not s then break end
		if cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			vim.notify("M.extract_link: file_md_style match.", vim.log.levels.DEBUG)
			return {line = line, type = "file_md_style", name = name, url = url, display_text = name, full_match_text = string.sub(line, s, e)}
		end
		offset = e
	end

	offset = 0
	while offset < #line do
		local s, e, displayed_text_capture, link_definition_capture = string.find(line, "%[([^]|]*)%|([^]]+)%]", offset + 1)
		local final_displayed_text, final_link_definition = nil, nil
		if s and cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			final_displayed_text = displayed_text_capture; final_link_definition = link_definition_capture
		else
			s, e, link_definition_capture = string.find(line, "%[([^]]+)%]", offset + 1)
			if s and cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
				if not link_definition_capture:find("|", 1, true) then
					final_displayed_text = link_definition_capture; final_link_definition = link_definition_capture
				else
					offset = e; goto continue_enhanced_link_loop
				end
			else
				if s then offset = e else break end
				goto continue_enhanced_link_loop
			end
		end

		if final_link_definition then
			vim.notify("M.extract_link: Potential enhanced_link. Definition: '" .. final_link_definition .. "'", vim.log.levels.DEBUG)
			if final_link_definition:sub(1,1) == "^" then
				local content_after_caret = final_link_definition:sub(2)
				-- YOUR CORRECTED REGEX FOR THE SAFEGUARD:
				if content_after_caret ~= "" and not content_after_caret:match("[/#:]") then
                     vim.notify("M.extract_link: Enhanced link safeguard: SKIPPING footnote-like content: [" .. final_link_definition .. "]", vim.log.levels.DEBUG)
					 -- Skip this match, let the loop continue
				else
					vim.notify("M.extract_link: Enhanced link safeguard: PASSED (not simple footnote) or empty after caret. Parsing: [" .. final_link_definition .. "]", vim.log.levels.DEBUG)
					local parsed_definition = M.parse_link_definition(final_link_definition)
					if parsed_definition then
						vim.notify("M.extract_link: Enhanced_link parsed successfully.", vim.log.levels.DEBUG)
						return {line = line, type = "enhanced_link", display_text = final_displayed_text, definition_details = parsed_definition, full_match_text = string.sub(line, s, e)}
					else
						vim.notify("M.extract_link: Enhanced_link parsing FAILED for: [" .. final_link_definition .. "]", vim.log.levels.DEBUG)
					end
				end
			else
				vim.notify("M.extract_link: Enhanced_link (not starting with ^). Parsing: [" .. final_link_definition .. "]", vim.log.levels.DEBUG)
				local parsed_definition = M.parse_link_definition(final_link_definition)
				if parsed_definition then
					vim.notify("M.extract_link: Enhanced_link parsed successfully.", vim.log.levels.DEBUG)
					return {line = line, type = "enhanced_link", display_text = final_displayed_text, definition_details = parsed_definition, full_match_text = string.sub(line, s, e)}
				else
					vim.notify("M.extract_link: Enhanced_link parsing FAILED for: [" .. final_link_definition .. "]", vim.log.levels.DEBUG)
				end
			end
		end
		offset = e
		::continue_enhanced_link_loop::
	end

	match_list = vim.fn.matchlist(line, M.patterns.website)
	if match_list[1] and #match_list[1] > 0 then
		ensure_cursor_col()
		local s_web, e_web = string.find(line, M.patterns.website, 1)
		if s_web and cursor_col_0idx >= (s_web-1) and cursor_col_0idx < e_web then
			vim.notify("M.extract_link: website match.", vim.log.levels.DEBUG)
			return { line = line, type = "website", url = match_list[1], display_text = match_list[1], full_match_text = match_list[1] }
		end
	end

	match_list = vim.fn.matchlist(line, M.patterns.zortex_link)
	if match_list[1] and #match_list[1] > 0 then
		vim.notify("M.extract_link: zortex_ref_link match.", vim.log.levels.DEBUG)
		return { line = line, type = "zortex_ref_link", url = match_list[2], display_text = match_list[1], full_match_text = match_list[1] }
	end

	match_list = vim.fn.matchlist(line, M.patterns.file_path)
	if match_list[1] and #match_list[1] > 0 and match_list[3] then
		ensure_cursor_col()
		local path_text = match_list[3]
		local s_path, e_path = string.find(line, vim.pesc(path_text), 1)
		if s_path and cursor_col_0idx >= (s_path-1) and cursor_col_0idx < e_path then
			vim.notify("M.extract_link: file_path_heuristic match.", vim.log.levels.DEBUG)
			return { line = line, type = "file_path_heuristic", path = path_text, display_text = path_text, full_match_text = path_text }
		end
	end

	match_list = vim.fn.matchlist(line, M.patterns.list_item)
	if match_list[1] and #match_list[1] > 0 then
		vim.notify("M.extract_link: text_list_item match (fallback).", vim.log.levels.DEBUG)
		return { line = line, type = "text_list_item", indent = #match_list[2], name = match_list[3], display_text = match_list[3] }
	end

	match_list = vim.fn.matchlist(line, M.patterns.heading)
	if match_list[1] and #match_list[1] > 0 then
		vim.notify("M.extract_link: text_heading match (fallback).", vim.log.levels.DEBUG)
		return { line = line, type = "text_heading", name = match_list[2], display_text = match_list[2] }
	end

	vim.notify("M.extract_link: EXIT. No link type matched.", vim.log.levels.DEBUG)
	return nil
end

function M.find_article_file_path(article_name_query)
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir or notes_dir == "" then vim.notify("g:zortex_notes_dir is not set.", vim.log.levels.ERROR); return nil end
	local lower_case_query = article_name_query:lower()
	local scandir_handle = vim.loop.fs_scandir(notes_dir)
	if not scandir_handle then vim.notify("Could not scan directory: " .. notes_dir, vim.log.levels.WARN); return nil end
	while true do
		local name, file_type = vim.loop.fs_scandir_next(scandir_handle)
		if not name then break end
		if file_type == "file" and (name:match("%.md$") or name:match("%.zortex$") or name:match("%.txt$")) then
			local full_path = joinpath(notes_dir, name)
			local file = io.open(full_path, "r")
			if file then
				local line_num = 0
				for file_line in file:lines() do
					line_num = line_num + 1
					if line_num > 20 then break end
					if file_line:sub(1, 2) == "@@" then
						local article_title_in_file = file_line:sub(3):gsub("^%s*(.-)%s*$", "%1")
						if article_title_in_file:lower() == lower_case_query then file:close(); return full_path end
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
	local base_text = vim.fn.escape(target_text, "\\")
	if target_type == "heading" then return "\\c^#\\+\\s*" .. base_text
	elseif target_type == "label" then return "\\c^\\^" .. base_text .. ".*:"
	elseif target_type == "query" then
		if target_text:match("[A-Z]") then return "\\C" .. base_text else return "\\c" .. base_text end
	else return "\\c" .. base_text end
end

local function lua_pattern_escape(text)
	if text == nil then return "" end
	return text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

function M.search_in_current_buffer(targets_to_find, current_file_path_for_msg)
	if not targets_to_find or #targets_to_find == 0 then vim.notify("No targets for search_in_current_buffer.", vim.log.levels.INFO); return true end
	local original_cursor = vim.api.nvim_win_get_cursor(0)
	local current_search_start_line = 1
	for i, target in ipairs(targets_to_find) do
		local search_pattern; local search_flags = "w"; local found_pos
		if target.type == "generic" then
			local heading_pattern = create_vim_search_pattern_for_target("heading", target.text)
			vim.api.nvim_win_set_cursor(0, { current_search_start_line, 0 })
			found_pos = vim.fn.searchpos(heading_pattern, search_flags)
			if not (found_pos[1] ~= 0 and found_pos[2] ~= 0) then
				local label_pattern = create_vim_search_pattern_for_target("label", target.text)
				vim.api.nvim_win_set_cursor(0, { current_search_start_line, 0 })
				found_pos = vim.fn.searchpos(label_pattern, search_flags)
			end
		else
			search_pattern = create_vim_search_pattern_for_target(target.type, target.text)
			vim.api.nvim_win_set_cursor(0, { current_search_start_line, 0 })
			found_pos = vim.fn.searchpos(search_pattern, search_flags)
		end
		if found_pos[1] ~= 0 and found_pos[2] ~= 0 then
			vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 })
			current_search_start_line = found_pos[1]
			if i < #targets_to_find then current_search_start_line = found_pos[1] + 1 end
		else
			local msg = string.format("%s target '%s' not found in %s.", target.type, target.text, current_file_path_for_msg or "current buffer")
			if search_pattern then msg = msg .. " (Pattern: " .. search_pattern .. ")" end
			vim.notify(msg, vim.log.levels.INFO)
			vim.api.nvim_win_set_cursor(0, original_cursor)
			return false
		end
	end
	vim.cmd("normal! zvzz"); return true
end

function M.search_all_articles_globally(target_type, target_text)
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir or notes_dir == "" then vim.notify("g:zortex_notes_dir is not set.", vim.log.levels.ERROR); return false end
	if not target_text or target_text == "" then vim.notify("Global search query empty for type: " .. target_type, vim.log.levels.WARN); return false end
	local qf_list = {}; local scandir_handle = vim.loop.fs_scandir(notes_dir)
	if not scandir_handle then vim.notify("Could not scan directory: " .. notes_dir, vim.log.levels.WARN); return false end
	vim.notify("Searching globally for " .. target_type .. ": " .. target_text, vim.log.levels.INFO)
	local lua_search_text = lua_pattern_escape(target_text:lower())
	local lua_primary_pattern, lua_secondary_pattern, primary_desc = target_type, nil, target_type
	if target_type == "generic" then
		lua_primary_pattern = "^#+%s*" .. lua_search_text; primary_desc = "heading"
		lua_secondary_pattern = "^%^" .. lua_search_text .. ".*:"; local secondary_desc = "label"
	elseif target_type == "heading" then lua_primary_pattern = "^#+%s*" .. lua_search_text
	elseif target_type == "label" then lua_primary_pattern = "^%^" .. lua_search_text .. ".*:"
	elseif target_type == "query" then
		if target_text:match("[A-Z]") then lua_primary_pattern = lua_pattern_escape(target_text) else lua_primary_pattern = lua_search_text end
	else vim.notify("Unsupported global search type: " .. target_type, vim.log.levels.WARN); return false end

	local function find_matches_in_file(file_path, pattern, description, use_raw_line)
		local file = io.open(file_path, "r"); if not file then return end
		local lnum = 0
		for file_line in file:lines() do
			lnum = lnum + 1
			local line_to_search = use_raw_line and file_line or file_line:lower()
			local s, e = line_to_search:find(pattern)
			if s then table.insert(qf_list, {filename = file_path, lnum = lnum, col = s, text = string.format("[%s: %s] %s", description, target_text, file_line:gsub("[\r\n]", "")), valid = 1}) end
		end
		file:close()
	end

	while true do
		local name, file_type_info = vim.loop.fs_scandir_next(scandir_handle); if not name then break end
		if file_type_info == "file" and (name:match("%.md$") or name:match("%.zortex$") or name:match("%.txt$")) then
			local full_path = joinpath(notes_dir, name)
			if target_type == "query" then find_matches_in_file(full_path, lua_primary_pattern, "query", target_text:match("[A-Z]"))
			else
				find_matches_in_file(full_path, lua_primary_pattern, primary_desc, false)
				if lua_secondary_pattern then find_matches_in_file(full_path, lua_secondary_pattern, "label", false) end
			end
		end
	end
	if #qf_list > 0 then
		local original_win_id = vim.api.nvim_get_current_win(); local first_match = qf_list[1]
		local bufnr_to_load = vim.fn.bufadd(first_match.filename)
		vim.api.nvim_win_set_buf(original_win_id, bufnr_to_load)
		vim.api.nvim_win_set_cursor(original_win_id, { first_match.lnum, (first_match.col > 0 and first_match.col - 1 or 0) })
		vim.api.nvim_win_call(original_win_id, function() vim.cmd("normal! zz") end)
		vim.fn.setqflist(qf_list, "r"); vim.cmd("copen")
		vim.notify(string.format("Found %d match(es) for global '%s'. QF populated. Jumped to first.", #qf_list, target_text), vim.log.levels.INFO)
		return true
	else vim.notify("No matches for global search: " .. target_text, vim.log.levels.INFO); return false end
end

function M.open_external(target)
	if not target or target == "" then vim.notify("No target for open_external.", vim.log.levels.ERROR); return end
	local cmd_parts
	if vim.fn.has("macunix") == 1 then cmd_parts = { "open", target }
	elseif vim.fn.has("unix") == 1 and vim.fn.executable("xdg-open") then cmd_parts = { "xdg-open", target }
	elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then cmd_parts = { "cmd", "/c", "start", "", target:gsub("/", "\\") }
	else vim.notify("Unsupported OS or xdg-open not found.", vim.log.levels.WARN); return end
	vim.fn.jobstart(cmd_parts, { detach = true })
end

function M.open_link()
	vim.notify("M.open_link: ENTER", vim.log.levels.DEBUG) -- DEBUG
	local line = vim.api.nvim_get_current_line()
	local current_filename_full = vim.fn.expand("%:p")
	local current_file_dir = vim.fn.expand("%:p:h")

	local link_info = M.extract_link(line)
	vim.notify("M.open_link: M.extract_link returned. Value (see + register): " .. vim.inspect(link_info), vim.log.levels.DEBUG) -- DEBUG
	vim.fn.setreg("+", vim.inspect(link_info)) -- For debugging

	if not link_info then
		vim.notify("No link found on the current line.", vim.log.levels.INFO)
		return
	end

	vim.notify("M.open_link: Link type: " .. link_info.type, vim.log.levels.DEBUG) -- DEBUG

	if link_info.type == "enhanced_link" then
		local def = link_info.definition_details
		vim.notify("M.open_link: Enhanced link. Target type: " .. def.target_type .. ", Scope: " .. def.scope, vim.log.levels.DEBUG) -- DEBUG
		if def.target_type == "query" then
			if def.scope == "local" then
				M.search_all_articles_globally("query", def.target_text) -- Placeholder
			elseif def.scope == "article_specific" and def.article_specifier then
				M.search_all_articles_globally("query", def.target_text) -- Placeholder
			else M.search_all_articles_globally("query", def.target_text) end
			return
		end
		local targets_to_search_for = {}
		if def.chained_parts then targets_to_search_for = def.chained_parts
		elseif def.target_text ~= "" or def.target_type == "article_root" then
			if def.target_type ~= "article_root" then table.insert(targets_to_search_for, { type = def.target_type, text = def.target_text }) end
		else vim.notify("Enhanced link has no valid target text.", vim.log.levels.WARN); return end

		if def.scope == "local" then
			if #targets_to_search_for > 0 then M.search_in_current_buffer(targets_to_search_for, current_filename_full)
			else vim.notify("Link to current article.", vim.log.levels.INFO); vim.api.nvim_win_set_cursor(0, {1,0}); vim.cmd("normal! zz") end
		elseif def.scope == "article_specific" and def.article_specifier then
			local article_path = M.find_article_file_path(def.article_specifier)
			if article_path then
				local original_win_id = vim.api.nvim_get_current_win(); local target_bufnr = vim.fn.bufadd(article_path)
				vim.api.nvim_win_set_buf(original_win_id, target_bufnr)
				vim.defer_fn(function()
					vim.api.nvim_set_current_win(original_win_id)
					if #targets_to_search_for > 0 then M.search_in_current_buffer(targets_to_search_for, article_path)
					else vim.api.nvim_win_set_cursor(original_win_id, {1,0}); vim.api.nvim_win_call(original_win_id, function() vim.cmd("normal! zz") end) end
				end, 50)
			end
		elseif def.scope == "global" then
			if #targets_to_search_for > 0 then M.search_all_articles_globally(targets_to_search_for[1].type, targets_to_search_for[1].text)
			else vim.notify("Global enhanced link without specific target.", vim.log.levels.WARN) end
		else vim.notify("Unknown scope for enhanced link: " .. def.scope, vim.log.levels.WARN) end

	elseif link_info.type == "file_path_heuristic" then
		vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.expand(link_info.path)))
	elseif link_info.type == "file_md_style" then
		local resolved_url = link_info.url
		if not (resolved_url:match("^https?://") or resolved_url:match("^/") or resolved_url:match("^[a-zA-Z]:[\\/]")) then
			if (resolved_url:sub(1,2) == "./" or resolved_url:sub(1,3) == "../") and current_file_dir and current_file_dir ~= "" then
				resolved_url = joinpath(current_file_dir, resolved_url)
			else
				local notes_dir = vim.g.zortex_notes_dir
				if notes_dir and notes_dir ~= "" then resolved_url = joinpath(notes_dir, resolved_url) end
			end
		end
		if resolved_url:match("^https?://") or not vim.fn.filereadable(vim.fn.expand(resolved_url)) then M.open_external(resolved_url)
		else vim.cmd("edit " .. vim.fn.fnameescape(resolved_url)) end
	elseif link_info.type == "footernote_ref" then
		vim.notify("M.open_link: Handling footernote_ref. ID: " .. link_info.ref_id, vim.log.levels.DEBUG) -- DEBUG
		local pattern_str = "^\\%V\\[\\^" .. vim.fn.escape(link_info.ref_id, "[].*^$") .. "\\]:\\s*"
		local original_cursor = vim.api.nvim_win_get_cursor(0)
		vim.api.nvim_win_set_cursor(0, {1,0})
		local found_pos = vim.fn.searchpos(pattern_str, "w")
		if found_pos[1] ~= 0 and found_pos[2] ~= 0 then
			vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 }); vim.cmd("normal! zvzz")
		else
			vim.notify("Footnote definition [^" .. link_info.ref_id .. "]: not found.", vim.log.levels.WARN)
			vim.api.nvim_win_set_cursor(0, original_cursor)
		end
	elseif link_info.type == "website" or link_info.type == "zortex_ref_link" then
		M.open_external(link_info.url)
	elseif (link_info.type == "text_heading" or link_info.type == "text_list_item") and link_info.name and link_info.name ~= "" then
		vim.notify("Context is '".. link_info.type .."'. Use dedicated command to search this text.", vim.log.levels.INFO)
	else
		vim.notify("Link type not fully handled or invalid: " .. (link_info.type or "unknown"), vim.log.levels.INFO)
	end
	vim.notify("M.open_link: EXIT", vim.log.levels.DEBUG) -- DEBUG
end

return M
