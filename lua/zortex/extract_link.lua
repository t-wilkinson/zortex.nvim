local M = {}
-- print(vim.inspect(links.extract_link("- some [text](url)")))

-- Pre-compile regex objects for performance in iterative matching
M.regex_iterators = {
	footernote_ref = vim.regex("\\[\\^\\([A-Za-z0-9_.-]\\+\\)\\]"), -- Original
	-- footernote_ref = vim.regex("\\[\\^\\(.\\{-}\\)\\]"), -- Non-greedy match for any characters

	-- Label definition pattern (for finding where labels are defined, not for link extraction)
	label_def = vim.regex("^\\^([%w_.-]+).*:"), -- Captures LabelName from ^LabelName.*:
}

-- Regex patterns for vim.fn.matchlist (string format)
M.patterns = {
	website = "\\vhttps?://[^);}]+",
	file_markdown_style = "\\v\\[([^]]*)]\\(([^)]+)\\)", -- Captures: 1=name (optional), 2=url. Handles [alt text](url) or [](url)
	zortex_link = "\\vref=([^\\s;}]+)", -- Captures: 1=url
	file_path = "\\v(^|\\s)([~.]?/[/\\S]+)($|\\s)", -- Captures the path in group 3
	heading = "\\v^#+ (.*)$", -- Standard markdown heading
	list_item = "\\v^(\\s*)- (.*)$",
}

--- Helper function to get 0-indexed cursor column
local function get_cursor_col_0idx()
	return vim.api.nvim_win_get_cursor(0)[2]
end

--- Slugify text for heading IDs (lowercase, spaces to hyphens, remove special chars)
-- Based on rules from "Enhanced Document Linking Functionality" II.B.1
local function slugify_heading_text(text)
	if not text then
		return ""
	end
	local slug = text:lower()
	slug = slug:gsub("[^%w%s-]", "") -- Remove non-word, non-space, non-hyphen
	slug = slug:gsub("%s+", "-") -- Replace spaces with hyphens
	slug = slug:gsub("-+", "-") -- Collapse multiple hyphens
	slug = slug:gsub("^-", "") -- Remove leading hyphen
	slug = slug:gsub("-$", "") -- Remove trailing hyphen
	return slug
end

--- Iteratively match a regex on a line for cursor-sensitive links.
local function extract_link_iteratively(line, cursor_col_0idx, regex_obj, type_name, result_builder)
	local search_offset_0idx = 0
	local final_match_data = nil
	while search_offset_0idx < #line do
		-- Using regex_obj:match_str for Neovim regex objects
		local match_result = regex_obj:match_str(line, search_offset_0idx)
		if not match_result then
			break
		end

		-- Handle different return types from match_str
		local captures
		if type(match_result) == "number" then
			-- When match_str returns a number, it's the end position of the match
			-- We need to find the match manually and extract the capture group
			local match_start, match_end = line:find("%[%^([A-Za-z0-9_.-]+)%]", search_offset_0idx + 1)
			if match_start and match_end then
				local full_match_text = line:sub(match_start, match_end)
				local ref_id = line:match("%[%^([A-Za-z0-9_.-]+)%]", match_start)

				-- Convert to 0-indexed positions for consistency
				local match_start_0idx = match_start - 1
				local match_end_0idx = match_end

				if cursor_col_0idx >= match_start_0idx and cursor_col_0idx < match_end_0idx then
					final_match_data = result_builder(line, {
						full_match_text = full_match_text,
						group_texts = { ref_id }, -- First capture group
					}, type_name)
					break
				end
				search_offset_0idx = match_end_0idx
			else
				break
			end
		elseif type(match_result) == "table" then
			captures = match_result
			-- Original table-based logic
			local full_match_info = captures[1]
			if not full_match_info then
				break
			end

			local group_infos = {}
			for i = 2, #captures do
				if captures[i] then
					table.insert(group_infos, captures[i])
				else
					table.insert(group_infos, nil)
				end
			end

			local match_start_0idx, match_end_0idx = full_match_info[1], full_match_info[2]
			if cursor_col_0idx >= match_start_0idx and cursor_col_0idx < match_end_0idx then
				final_match_data = result_builder(line, {
					full_match_text = string.sub(line, match_start_0idx + 1, match_end_0idx),
					group_texts = vim.tbl_map(function(info)
						if info then
							return string.sub(line, info[1] + 1, info[2])
						else
							return nil
						end
					end, group_infos),
				}, type_name)
				break
			end
			search_offset_0idx = match_end_0idx
		else
			vim.notify("Unknown match result type: " .. type(match_result), vim.log.levels.DEBUG)
			break
		end

		if search_offset_0idx >= #line then
			break
		end
	end
	return final_match_data
end

--- Parses the Link Definition part of an enhanced link.
-- @param link_definition string The core linking information.
-- @return table|nil A structured table describing the link target, or nil.
function M.parse_link_definition(link_definition)
	if not link_definition or link_definition == "" then
		return nil
	end

	local result = {
		original_definition = link_definition,
		article_specifier = nil, -- Name of the target article
		target_specifier = "", -- The #Heading, :Label, %Query, or GenericText
		target_type = "generic", -- "heading", "label", "query", "generic"
		target_text = "", -- The actual text for heading/label/query/generic
		scope = "global", -- "article_specific", "local", "global"
		chained_parts = nil, -- For [Article/#Heading/:Label]
	}

	local definition_to_parse = link_definition

	-- 1. Check for Article Specifier (ends with /)
	local captured_article_name, position_after_slash = definition_to_parse:match("^([^/]+)/()")
	if captured_article_name then
		result.article_specifier = captured_article_name
		if position_after_slash then
			definition_to_parse = definition_to_parse:sub(position_after_slash)
		else
			definition_to_parse = ""
		end
		result.scope = "article_specific"
	elseif definition_to_parse:sub(1, 1) == "/" then
		-- 2. Check for Local Scope (starts with /)
		result.scope = "local"
		definition_to_parse = definition_to_parse:sub(2) -- Remove leading /
	else
		-- 3. Default to Global Scope (no ArticleSpecifier, no leading /)
		result.scope = "global"
	end

	result.target_specifier = definition_to_parse -- What remains is the target specifier

	-- 4. Parse Chained Links (e.g., #Heading/:Label or /#Heading/:Label)
	local chained_match_pos = result.target_specifier:match("/:()")
	if chained_match_pos then
		result.chained_parts = {}
		local primary_target_full = result.target_specifier:sub(1, chained_match_pos - 3)
		local secondary_target_label_name = result.target_specifier:sub(chained_match_pos)

		if primary_target_full:sub(1, 1) == "#" then
			table.insert(result.chained_parts, {
				type = "heading",
				text = primary_target_full:sub(2),
				original = primary_target_full,
			})
		else
			vim.notify(
				"Invalid chained link: Primary target must be a heading. Found: " .. primary_target_full,
				vim.log.levels.WARN
			)
			return nil
		end

		table.insert(result.chained_parts, {
			type = "label",
			text = secondary_target_label_name,
			original = ":" .. secondary_target_label_name,
		})
		result.target_type = "chained_label"
		result.target_text = result.target_specifier
		return result
	end

	-- 5. Parse Target Type and Text for non-chained links
	if result.target_specifier:sub(1, 1) == "#" then
		result.target_type = "heading"
		result.target_text = result.target_specifier:sub(2)
	elseif result.target_specifier:sub(1, 1) == ":" then
		result.target_type = "label"
		result.target_text = result.target_specifier:sub(2)
	elseif result.target_specifier:sub(1, 1) == "%" then
		result.target_type = "query"
		result.target_text = result.target_specifier:sub(2)
	else
		result.target_type = "generic"
		result.target_text = result.target_specifier
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

--- Extracts link information from a given line of text, prioritizing cursor position.
function M.extract_link(line)
	local match_list
	local cursor_col_0idx = get_cursor_col_0idx()

	-- 1. Footnote references (highest priority for cursor-sensitive matching)
	local footernote_ref_match = extract_link_iteratively(
		line,
		cursor_col_0idx,
		M.regex_iterators.footernote_ref,
		"footernote_ref",
		function(l, captures, type_n)
			return {
				line = l,
				type = type_n,
				ref_id = captures.group_texts[1],
				display_text = captures.full_match_text,
				full_match_text = captures.full_match_text,
			}
		end
	)
	if footernote_ref_match then
		vim.notify("Found footernote", vim.log.levels.DEBUG)
		return footernote_ref_match
	end

	local offset = 0
	while offset < #line do
		local s, e, name, url = string.find(line, M.patterns.file_markdown_style, offset + 1)
		if not s then
			break
		end
		if cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			return {
				line = line,
				type = "file_md_style",
				name = name,
				url = url,
				display_text = name,
				full_match_text = string.sub(line, s, e),
			}
		end
		offset = e
	end

	-- 3. Enhanced links: [Displayed Text|Link Definition] or [Link Definition] - cursor sensitive
	offset = 0
	while offset < #line do
		-- First try to match the pipe format: [DisplayText|LinkDef]
		local s, e, displayed_text_capture, link_definition_capture =
			string.find(line, "%[([^]|]*)%|([^]]+)%]", offset + 1)

		local final_displayed_text = nil
		local final_link_definition = nil

		if s and cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			-- Found pipe format and cursor is within it
			final_displayed_text = displayed_text_capture
			final_link_definition = link_definition_capture
		else
			-- Try to match simple format: [LinkDef] but exclude footnotes [^identifier]
			s, e, link_definition_capture = string.find(line, "%[([^]]+)%]", offset + 1)
			if s and cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
				-- Check if this is a footnote reference (starts with ^)
				if link_definition_capture:sub(1, 1) == "^" then
					-- This is a footnote, skip it - it will be handled by footnote parser
					offset = e
					goto continue_enhanced_link_loop
				end

				-- Make sure this isn't actually a pipe format that we missed
				if not link_definition_capture:find("|", 1, true) then
					final_displayed_text = link_definition_capture
					final_link_definition = link_definition_capture
				else
					-- This is a pipe format, skip it (it will be caught in next iteration)
					offset = e
					goto continue_enhanced_link_loop
				end
			else
				-- No match found, move to next position or break
				if s then
					offset = e
				else
					break
				end
				goto continue_enhanced_link_loop
			end
		end

		-- If we found a valid link definition, process it
		if final_link_definition then
			local parsed_definition = M.parse_link_definition(final_link_definition)
			if parsed_definition then
				return {
					line = line,
					type = "enhanced_link",
					display_text = final_displayed_text,
					definition_details = parsed_definition,
					full_match_text = string.sub(line, s, e),
				}
			else
				-- If parsing failed, this might not be a valid enhanced link
				vim.notify("Failed to parse link definition: " .. final_link_definition, vim.log.levels.DEBUG)
			end
		end

		-- Move to next position
		if s then
			offset = e
		else
			break
		end

		::continue_enhanced_link_loop::
	end

	-- 4. Website links - cursor sensitive
	offset = 0
	while offset < #line do
		local s, e = string.find(line, M.patterns.website, offset + 1)
		if not s then
			break
		end
		if cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			local url = string.sub(line, s, e)
			return { line = line, type = "website", url = url, display_text = url, full_match_text = url }
		end
		offset = e
	end

	-- 5. Zortex specific ref= links - cursor sensitive
	offset = 0
	while offset < #line do
		local s, e, full_match, url = string.find(line, M.patterns.zortex_link, offset + 1)
		if not s then
			break
		end
		if cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			return {
				line = line,
				type = "zortex_ref_link",
				url = url,
				display_text = full_match,
				full_match_text = full_match,
			}
		end
		offset = e
	end

	-- 6. File paths (cursor sensitive)
	match_list = vim.fn.matchlist(line, M.patterns.file_path)
	if match_list[1] and #match_list[1] > 0 and match_list[3] then
		local path_text = match_list[3]
		local s_path, e_path = string.find(line, vim.pesc(path_text), 1)
		if s_path and cursor_col_0idx >= (s_path - 1) and cursor_col_0idx < e_path then
			return {
				line = line,
				type = "file_path_heuristic",
				path = path_text,
				display_text = path_text,
				full_match_text = path_text,
			}
		end
	end

	-- 7. Text context recognition (only if no links found above)
	-- These are lower priority and should only trigger if nothing else matches
	match_list = vim.fn.matchlist(line, M.patterns.list_item)
	if match_list[1] and #match_list[1] > 0 then
		return {
			line = line,
			type = "text_list_item",
			indent = #match_list[2],
			name = match_list[3],
			display_text = match_list[3],
		}
	end

	match_list = vim.fn.matchlist(line, M.patterns.heading)
	if match_list[1] and #match_list[1] > 0 then
		return { line = line, type = "text_heading", name = match_list[2], display_text = match_list[2] }
	end

	return nil
end

return M
