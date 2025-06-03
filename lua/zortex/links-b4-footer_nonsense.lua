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
	-- Label definition pattern (for finding where labels are defined, not for link extraction)
	label_def = vim.regex("^\\^([%w_.-]+).*:"), -- Captures LabelName from ^LabelName.*:
}

-- Regex patterns for vim.fn.matchlist (string format)
M.patterns = {
	website = "\\vhttps?://[^);}]+",
	file_markdown_style = "\\v\\[([^]]*)]\\(([^)]+)\\)", -- Captures: 1=name (optional), 2=url. Handles [alt text](url) or [](url)
	zortex_link = "\\vref=([^\\s;}]+)", -- Captures: 1=url
	-- Generic bracket link: [[Displayed Text|Link Definition]] or [[Link Definition]]
	-- Group 1: Displayed Text (optional, including the |)
	-- Group 2: Link Definition
	-- Group 3: Content if no pipe (used if group 1 is nil)
	enhanced_link = "\\[(?:([^]|]+)\\|)?([^]]+)]", -- Lua pattern
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
	if not text then return "" end
	local slug = text:lower()
	slug = slug:gsub("[^%w%s-]", "") -- Remove non-word, non-space, non-hyphen
	slug = slug:gsub("%s+", "-")    -- Replace spaces with hyphens
	slug = slug:gsub("-+", "-")     -- Collapse multiple hyphens
	slug = slug:gsub("^-", "")      -- Remove leading hyphen
	slug = slug:gsub("-$", "")      -- Remove trailing hyphen
	return slug
end


--- Iteratively match a regex on a line for cursor-sensitive links.
local function extract_link_iteratively(line, cursor_col_0idx, regex_obj, type_name, result_builder)
	local search_offset_0idx = 0
	local final_match_data = nil
	while search_offset_0idx < #line do
		-- Using regex_obj:match_str for Neovim regex objects
		local captures = regex_obj:match_str(line, search_offset_0idx)
		if not captures then
			break
		end
		-- captures[1] is the full match info, captures[2] is the first group info, etc.
		local full_match_info = captures[1]
		if not full_match_info then break end -- Should always exist if captures is not nil

		local group_infos = {}
		for i = 2, #captures do
			if captures[i] then
				table.insert(group_infos, captures[i])
			else
				-- If a capture group is optional and didn't match, it might be nil.
				-- Add a placeholder or handle as needed by result_builder.
				table.insert(group_infos, nil)
			end
		end

		if not full_match_info then
			break
		end

		local match_start_0idx, match_end_0idx = full_match_info[1], full_match_info[2]
		if cursor_col_0idx >= match_start_0idx and cursor_col_0idx < match_end_0idx then
			final_match_data = result_builder(line, {
				full_match_text = string.sub(line, match_start_0idx + 1, match_end_0idx),
				-- Pass all group texts to the builder
				group_texts = vim.tbl_map(function(info)
					if info then return string.sub(line, info[1] + 1, info[2]) else return nil end
				end, group_infos)
			}, type_name)
			break
		end
		search_offset_0idx = match_end_0idx
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
		article_specifier = nil,   -- Name of the target article
		target_specifier = "",     -- The #Heading, :Label, %Query, or GenericText
		target_type = "generic",   -- "heading", "label", "query", "generic"
		target_text = "",          -- The actual text for heading/label/query/generic
		scope = "global",          -- "article_specific", "local", "global"
		chained_parts = nil,       -- For [Article/#Heading/:Label]
	}

	local definition_to_parse = link_definition

	-- 1. Check for Article Specifier (ends with /)
	-- Pattern: ^([^/]+)/()
	--   ^([^/]+)  - Captures the article name (one or more non-slash characters from the start)
	--   /          - Matches the literal slash
	--   ()         - Captures the numerical position *after* the slash
	local captured_article_name, position_after_slash = definition_to_parse:match("^([^/]+)/()")
	if captured_article_name then -- If the pattern matched (meaning captured_article_name is not nil)
		result.article_specifier = captured_article_name
		if position_after_slash then -- Should always be true if captured_article_name is not nil
		    definition_to_parse = definition_to_parse:sub(position_after_slash)
        else
            -- This case should ideally not be reached if captured_article_name is set,
            -- but as a fallback, if position_after_slash is somehow nil:
            definition_to_parse = "" -- Or handle error, an article name must be followed by /
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
	--    A chained link has a primary target and a secondary target, separated by '/:'
	local chained_match_pos = result.target_specifier:match("/:()") -- This returns the position *after* "/:"
	if chained_match_pos then
		result.chained_parts = {}
		-- Text before "/:" is primary_target_full. chained_match_pos is start index of label name.
		-- So, end index of primary_target_full is chained_match_pos - 3
		-- Example: "#Heading/:Label"
		-- "/:" is found. chained_match_pos points to start of "Label".
		-- Primary target is "#Heading", which is from index 1 to (chained_match_pos - 1 (for :) - 1 (for /) -1) = chained_match_pos - 3
		local primary_target_full = result.target_specifier:sub(1, chained_match_pos - 3)
		local secondary_target_label_name = result.target_specifier:sub(chained_match_pos) -- This will be "LabelName"

		-- Parse primary target (should be a heading)
		if primary_target_full:sub(1,1) == "#" then
			table.insert(result.chained_parts, {
				type = "heading",
				text = primary_target_full:sub(2),
				original = primary_target_full
			})
		else
			-- Invalid chained link if primary is not a heading
			vim.notify("Invalid chained link: Primary target must be a heading. Found: " .. primary_target_full, vim.log.levels.WARN)
			return nil -- Or handle as a non-chained link to primary_target_full
		end

		-- Secondary target is always a label
		table.insert(result.chained_parts, {
			type = "label",
			text = secondary_target_label_name,
			original = ":" .. secondary_target_label_name
		})
		result.target_type = "chained_label" -- Special type for chained links
		result.target_text = result.target_specifier -- Keep full specifier as target_text for now
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
		-- e.g. [/#] or [ArticleName/:] is invalid if not generic
		-- A link like [/] (local, generic, empty target_text) could mean "current article root"
		if result.scope == "local" and result.target_specifier == "" then
			-- This is a link to the current article itself, like `[ArticleName/]` or `[/]`
			result.target_type = "article_root" -- Special type for this case
		else
			vim.notify("Warning: Link target text is empty for type " .. result.target_type, vim.log.levels.WARN)
			-- It could be an intentional link to an empty generic string, but usually not for #, :, %
		end
	end

	return result
end


--- Extracts link information from a given line of text, prioritizing cursor position.
function M.extract_link(line)
	local match_list
	local cursor_col_0idx -- Lazily initialized

	-- Helper to ensure cursor_col_0idx is available
	local function ensure_cursor_col()
		if not cursor_col_0idx then
			cursor_col_0idx = get_cursor_col_0idx()
		end
	end

	-- 1. Standard Markdown file links: [text](url)
	-- This needs to be cursor sensitive if multiple on a line.
	-- Using string.find for multiple occurrences and checking cursor position.
	ensure_cursor_col()
	local offset = 0
	while offset < #line do
		local s, e, name, url = string.find(line, M.patterns.file_markdown_style, offset + 1)
		if not s then break end
		if cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			return {
				line = line,
				type = "file_md_style",
				name = name,
				url = url,
				display_text = name,
				full_match_text = string.sub(line, s, e)
			}
		end
		offset = e
	end

	-- 2. Enhanced links: [Displayed Text|Link Definition] or [Link Definition]
	-- This also needs to be cursor sensitive.
	ensure_cursor_col()
	offset = 0
	while offset < #line do
		-- string.find with Lua patterns:
		-- captures[1]: displayed_text (optional, without the trailing '|')
		-- captures[2]: link_definition
		local s, e, displayed_text_capture, link_definition_capture =
			string.find(line, "%[([^]|]*)%|([^]]+)%]", offset + 1) -- Pattern for [Display|Definition]

		local final_displayed_text = nil
		local final_link_definition = nil

		if s and cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			-- Matched [Display|Definition]
			final_displayed_text = displayed_text_capture
			final_link_definition = link_definition_capture
		else
			-- Try matching [Definition] only
			s, e, link_definition_capture = string.find(line, "%[([^]]+)%]", offset + 1)
			if s and cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
				-- Check if it contains '|', if so, it was already handled or is malformed for this simple pattern
				if not link_definition_capture:find("|", 1, true) then
					final_displayed_text = link_definition_capture -- Definition is display text
					final_link_definition = link_definition_capture
				else
					-- It has a pipe but didn't match the [Display|Definition] structure correctly,
					-- or cursor is not in a more specific part. Could be malformed.
					-- Or, it could be that the first pattern was too greedy.
					-- For now, we'll skip if it has a pipe and didn't match the first pattern.
					offset = e
					goto continue_enhanced_link_loop -- Skips parsing this as a simple [Definition]
				end
			else
				-- No enhanced link found at this offset or cursor not within it
				if s then offset = e else break end -- Advance offset or break if no more matches
				goto continue_enhanced_link_loop
			end
		end

		if final_link_definition then
			local parsed_definition = M.parse_link_definition(final_link_definition)
			if parsed_definition then
				return {
					line = line,
					type = "enhanced_link",
					display_text = final_displayed_text,
					definition_details = parsed_definition,
					full_match_text = string.sub(line, s, e)
				}
			else
				-- Parsing the definition failed, but we found a bracket structure.
				-- Treat as a simple bracketed text if parsing fails? Or ignore?
				-- For now, let's assume if parse_link_definition returns nil, it's not a valid enhanced link.
			end
		end
		offset = e
		::continue_enhanced_link_loop::
	end


	-- 3. Website links
	match_list = vim.fn.matchlist(line, M.patterns.website) -- Not cursor sensitive by default with matchlist
	if match_list[1] and #match_list[1] > 0 then
		-- To make it cursor sensitive, we'd need iterative find like above.
		-- For simplicity, if only one, or if cursor is generally on the line, this might be acceptable.
		-- Let's assume for now that if an enhanced link was not found, this can be checked.
		-- A more robust solution would iterate for websites too.
		ensure_cursor_col()
		local s, e = string.find(line, M.patterns.website, 1) -- Find first
		if s and cursor_col_0idx >= (s-1) and cursor_col_0idx < e then -- Basic check for first URL
			return { line = line, type = "website", url = match_list[1], display_text = match_list[1], full_match_text = match_list[1] }
		end
	end


	-- 4. Zortex specific ref= links
	match_list = vim.fn.matchlist(line, M.patterns.zortex_link)
	if match_list[1] and #match_list[1] > 0 then
		-- Similar cursor sensitivity considerations as website links
		return { line = line, type = "zortex_ref_link", url = match_list[2], display_text = match_list[1], full_match_text = match_list[1] }
	end

	-- 5. Iterative, cursor-sensitive links (Zettel, Footnote)
	ensure_cursor_col() -- ensure cursor_col_0idx is initialized

	local zettel_match = extract_link_iteratively(
		line,
		cursor_col_0idx,
		M.regex_iterators.zettel,
		"zettel_id_link",
		function(l, captures, type_n) -- captures.group_texts[1] is the zettel id
			return { line = l, type = type_n, zettel_id = captures.group_texts[1], display_text = captures.full_match_text, full_match_text = captures.full_match_text }
		end
	)
	if zettel_match then
		return zettel_match
	end

	local footernote_ref_match = extract_link_iteratively(
		line,
		cursor_col_0idx,
		M.regex_iterators.footernote_ref,
		"footernote_ref",
		function(l, captures, type_n) -- captures.group_texts[1] is the footnote identifier
			return { line = l, type = type_n, ref_id = captures.group_texts[1], display_text = captures.full_match_text, full_match_text = captures.full_match_text }
		end
	)
	if footernote_ref_match then
		return footernote_ref_match
	end

	-- 6. File paths (heuristic, might be broad)
	match_list = vim.fn.matchlist(line, M.patterns.file_path)
	if match_list[1] and #match_list[1] > 0 and match_list[3] then
		-- Cursor sensitivity for file paths
		ensure_cursor_col()
		local path_text = match_list[3]
		local s, e = string.find(line, vim.pesc(path_text), 1) -- Find the path
		if s and cursor_col_0idx >= (s-1) and cursor_col_0idx < e then
			return { line = line, type = "file_path_heuristic", path = path_text, display_text = path_text, full_match_text = path_text }
		end
	end


	-- Fallback: if no specific link type is found, consider current line as text for other operations
	-- This part is from the original, might be useful for context actions not strictly "opening links"
	match_list = vim.fn.matchlist(line, M.patterns.list_item)
	if match_list[1] and #match_list[1] > 0 then
		return { line = line, type = "text_list_item", indent = #match_list[2], name = match_list[3], display_text = match_list[3] }
	end

	match_list = vim.fn.matchlist(line, M.patterns.heading)
	if match_list[1] and #match_list[1] > 0 then
		return { line = line, type = "text_heading", name = match_list[2], display_text = match_list[2] }
	end

	return nil
end


--- Finds an article file based on its @@ArticleName title.
-- (This function remains largely the same, assuming article names are unique for now)
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

		-- Assuming articles have a specific extension, e.g., .md or .zortex
		if file_type == "file" and (name:match("%.md$") or name:match("%.zortex$") or name:match("%.txt$")) then
			local full_path = joinpath(notes_dir, name)
			local file = io.open(full_path, "r")
			if file then
				local line_num = 0
				for file_line in file:lines() do
					line_num = line_num + 1
					if line_num > 20 then -- Limit search to first few lines for performance
						break
					end
					-- Assuming article title is defined like @@Article Title in the file
					if file_line:sub(1, 2) == "@@" then
						local article_title_in_file = file_line:sub(3):gsub("^%s*(.-)%s*$", "%1") -- Trim
						if article_title_in_file:lower() == lower_case_query then
							file:close()
							return full_path
						end
						break -- Stop after finding the first @@ line
					elseif line_num == 1 and not file_line:match("^%s*$") and not file_line:match("^#") then
						-- If first line is not blank and not a heading, could be implicit title
						-- This part is heuristic and depends on conventions
					end
				end
				file:close()
			end
		end
	end
	vim.notify("Article file not found for: " .. article_name_query, vim.log.levels.INFO)
	return nil
end

--- Creates a Vim search pattern for a target part (heading, label, generic).
-- This is a simplified version. "Best Matching" would require more complex logic here
-- or in the calling search functions.
local function create_vim_search_pattern_for_target(target_type, target_text, for_global_search)
	local search_pattern
	local base_text = vim.fn.escape(target_text, "\\") -- Escape for Vim regex

	if target_type == "heading" then
		-- Match: # Heading Text (case insensitive for text part)
		-- Slugification and matching against slugified IDs would be more robust here.
		search_pattern = "\\c^#\\+\\s*" .. base_text
	elseif target_type == "label" then
		-- Match: ^LabelName.*: (case insensitive for LabelName)
		-- The `.*` is not part of the matchable name in the spec, so we match `^LabelName:`
		search_pattern = "\\c^" .. base_text .. ".*:"
	elseif target_type == "query" then
		-- For query, we need to implement smart case.
		-- If target_text has uppercase, use \C for case-sensitive. Else \c for case-insensitive.
		if target_text:match("[A-Z]") then
			search_pattern = "\\C" .. base_text
		else
			search_pattern = "\\c" .. base_text
		end
	else -- generic
		-- For generic, the spec says try Headings then Labels.
		-- This function just creates one pattern. The calling logic would try both.
		-- For now, let's make a generic text search pattern.
		search_pattern = "\\c" .. base_text -- Case-insensitive generic text search
	end
	return search_pattern
end

local function lua_pattern_escape(text)
	if text == nil then
		return ""
	end
	return text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

--- Searches within the current buffer for specified targets.
-- `targets_to_find` is an array of {type, text} from parsed link definition (e.g., chained_parts or single target)
-- TODO: Implement "Best Matching" and heading scope for chained links.
function M.search_in_current_buffer(targets_to_find, current_file_path_for_msg)
	if not targets_to_find or #targets_to_find == 0 then
		vim.notify("No targets specified for search in current buffer.", vim.log.levels.INFO)
		return true -- Or false, depending on desired outcome for empty targets
	end

	local original_cursor = vim.api.nvim_win_get_cursor(0)
	local current_search_start_line = 1 -- Start search from this line

	for i, target in ipairs(targets_to_find) do
		local search_pattern
		local search_flags = "w" -- Wrap search by default

		if target.type == "generic" then
			-- Priority 1: Search as Heading
			local heading_pattern = create_vim_search_pattern_for_target("heading", target.text)
			vim.api.nvim_win_set_cursor(0, { current_search_start_line, 0 })
			local found_pos = vim.fn.searchpos(heading_pattern, search_flags)

			if found_pos[1] ~= 0 and found_pos[2] ~= 0 then
				vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 })
				current_search_start_line = found_pos[1] -- Next search starts from this line
				if i < #targets_to_find then current_search_start_line = found_pos[1] + 1 end -- For chained, next part starts after current
			else
				-- Priority 2: Search as Label
				local label_pattern = create_vim_search_pattern_for_target("label", target.text)
				vim.api.nvim_win_set_cursor(0, { current_search_start_line, 0 }) -- Reset start for this attempt
				found_pos = vim.fn.searchpos(label_pattern, search_flags)
				if found_pos[1] ~= 0 and found_pos[2] ~= 0 then
					vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 })
					current_search_start_line = found_pos[1]
					if i < #targets_to_find then current_search_start_line = found_pos[1] + 1 end
				else
					vim.notify(
						string.format("Generic target '%s' not found as heading or label in %s.", target.text, current_file_path_for_msg or "current buffer"),
						vim.log.levels.INFO
					)
					vim.api.nvim_win_set_cursor(0, original_cursor)
					return false
				end
			end
		else -- Specific type (heading, label)
			search_pattern = create_vim_search_pattern_for_target(target.type, target.text)
			vim.api.nvim_win_set_cursor(0, { current_search_start_line, 0 })
			local found_pos = vim.fn.searchpos(search_pattern, search_flags)

			if found_pos[1] ~= 0 and found_pos[2] ~= 0 then
				vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 })
				current_search_start_line = found_pos[1]
				if i < #targets_to_find then current_search_start_line = found_pos[1] + 1 end
			else
				vim.notify(
					string.format("%s target '%s' (pattern: %s) not found in %s.", target.type, target.text, search_pattern, current_file_path_for_msg or "current buffer"),
					vim.log.levels.INFO
				)
				vim.api.nvim_win_set_cursor(0, original_cursor)
				return false
			end
		end
		-- TODO: For chained links, after finding a heading, the next search (for label)
		-- must be constrained to the scope of that heading. This requires parsing the
		-- buffer to determine heading scope (e.g., until next heading of same/higher level or EOF).
		-- The current `current_search_start_line` update is a simplification.
	end
	vim.cmd("normal! zvzz") -- Open folds, center view
	return true
end

--- Searches all articles globally for a target.
-- TODO: Implement "Best Matching", tie-breaking (quickfix for multiple matches).
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

	-- Determine search patterns for Lua string matching
	local lua_search_text = lua_pattern_escape(target_text:lower())
	local lua_primary_pattern, lua_secondary_pattern
	local primary_target_description = target_type
	local secondary_target_description = nil

	if target_type == "generic" then
		-- Priority 1: Heading
		lua_primary_pattern = "^#+%s*" .. lua_search_text
		primary_target_description = "heading"
		-- Priority 2: Label
		lua_secondary_pattern = "^%^" .. lua_search_text .. ".*:" -- Lua pattern for ^LabelName.*:
		secondary_target_description = "label"
	elseif target_type == "heading" then
		lua_primary_pattern = "^#+%s*" .. lua_search_text
	elseif target_type == "label" then
		lua_primary_pattern = "^%^" .. lua_search_text .. ".*:"
	elseif target_type == "query" then
		-- Smart case for Lua pattern
		if target_text:match("[A-Z]") then -- Case-sensitive
			lua_primary_pattern = lua_pattern_escape(target_text)
		else -- Case-insensitive
			lua_primary_pattern = lua_search_text -- Already lowercased
		end
	else
		vim.notify("Unsupported target type for global search: " .. target_type, vim.log.levels.WARN)
		return false
	end

	local function find_matches_in_file(file_path, pattern, description, use_raw_line)
		local file = io.open(file_path, "r")
		if not file then return end
		local lnum = 0
		for file_line in file:lines() do
			lnum = lnum + 1
			local line_to_search = use_raw_line and file_line or file_line:lower()
			local s, e = line_to_search:find(pattern)
			if s then
				table.insert(qf_list, {
					filename = file_path,
					lnum = lnum,
					col = s,
					text = string.format("[%s: %s] %s", description, target_text, file_line),
					valid = 1,
				})
				-- For non-query types, if we are not building a disambiguation list,
				-- we might stop after the first match per file or overall.
				-- For now, collect all for potential disambiguation.
			end
		end
		file:close()
	end

	while true do
		local name, file_type_info = vim.loop.fs_scandir_next(scandir_handle)
		if not name then break end

		if file_type_info == "file" and (name:match("%.md$") or name:match("%.zortex$") or name:match("%.txt$")) then
			local full_path = joinpath(notes_dir, name)
			if target_type == "query" then
				find_matches_in_file(full_path, lua_primary_pattern, "query", not target_text:match("[A-Z]")) -- use raw line if case sensitive
			else
				find_matches_in_file(full_path, lua_primary_pattern, primary_target_description, false)
				if lua_secondary_pattern then -- For generic, try label if heading not found or also collect labels
					-- Simple logic: if generic, collect both. Refined logic would apply "best match" across all.
					find_matches_in_file(full_path, lua_secondary_pattern, secondary_target_description, false)
				end
			end
		end
	end

	if #qf_list > 0 then
		-- TODO: Implement "Best Matching" here. If multiple "best" matches of same quality,
		-- show all in qf_list. If one unique best match, jump to it directly.
		-- For now, just populate qf_list with all found.
		vim.fn.setqflist(qf_list, "r")
		vim.cmd("copen")
		local first_match = qf_list[1]
		vim.defer_fn(function()
			-- Navigate to the first match
			if vim.fn.bufloaded(first_match.filename) == 0 or vim.fn.bufwinnr(first_match.filename) == -1 then
				vim.cmd("edit " .. vim.fn.fnameescape(first_match.filename))
			else
				local bufnr = vim.fn.bufnr(first_match.filename)
				if bufnr ~= -1 then vim.api.nvim_set_current_buf(bufnr) end
			end
			vim.api.nvim_win_set_cursor(0, { first_match.lnum, (first_match.col > 0 and first_match.col - 1 or 0) })
			vim.cmd("normal! zz")
		end, 50)

		vim.notify(
			string.format("Found %d potential match(es) for global search '%s'. Quickfix list populated.", #qf_list, target_text),
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

--- Main function to open a link found on the current line.
function M.open_link()
	local line = vim.api.nvim_get_current_line()
	local current_filename_full = vim.fn.expand("%:p")
	local current_file_dir = vim.fn.expand("%:p:h")

	local link_info = M.extract_link(line)

	if not link_info then
		vim.notify("No link found on the current line.", vim.log.levels.INFO)
		return
	end

	vim.fn.setreg("+", vim.inspect(link_info)) -- For debugging the extracted link object

	if link_info.type == "enhanced_link" then
		local def = link_info.definition_details
		if def.target_type == "query" then
			-- Handle query links: search and populate quickfix list
			if def.scope == "local" then
				-- TODO: Implement local query: search current buffer, populate quickfix
				M.search_all_articles_globally("query", def.target_text) -- Placeholder, should be local
				vim.notify("Local query: searching current buffer for '%" .. def.target_text .. "' (populate qf list).", vim.log.levels.INFO)
			elseif def.scope == "article_specific" and def.article_specifier then
				-- TODO: Implement article-specific query
				M.search_all_articles_globally("query", def.target_text) -- Placeholder
				vim.notify("Article query: searching " .. def.article_specifier .. " for '%" .. def.target_text .. "' (populate qf list).", vim.log.levels.INFO)
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
				-- Special case: link to the article itself, no further search needed in target article
			else
				table.insert(targets_to_search_for, { type = def.target_type, text = def.target_text })
			end
		else
			vim.notify("Enhanced link has no valid target text.", vim.log.levels.WARN)
			return
		end


		if def.scope == "local" then
			if #targets_to_search_for > 0 then
				M.search_in_current_buffer(targets_to_search_for, current_filename_full)
			else -- e.g. '[/]' link to current article root
				vim.notify("Link to current article.", vim.log.levels.INFO)
				-- No action needed if already in the article, or could go to top.
				vim.api.nvim_win_set_cursor(0, {1,0})
				vim.cmd("normal! zz")
			end
		elseif def.scope == "article_specific" and def.article_specifier then
			local article_path = M.find_article_file_path(def.article_specifier)
			if article_path then
				local target_bufnr = vim.fn.bufadd(article_path)
				vim.api.nvim_set_current_buf(target_bufnr) -- Switch buffer first
				vim.cmd.edit(vim.fn.fnameescape(article_path)) -- Then edit to load/focus

				vim.defer_fn(function()
					if #targets_to_search_for > 0 then
						M.search_in_current_buffer(targets_to_search_for, article_path)
					else -- Link to the article root, e.g. [ArticleName/]
						vim.api.nvim_win_set_cursor(0, {1,0}) -- Go to top of article
						vim.cmd("normal! zz")
					end
				end, 100) -- Increased delay for buffer switch and load
			end
		elseif def.scope == "global" then
			if #targets_to_search_for > 0 then
				-- For global, we expect one primary target part for now
				-- Chained global links [#GlobalHeading/:LabelInThatHeadingScope] are more complex.
				M.search_all_articles_globally(targets_to_search_for[1].type, targets_to_search_for[1].text)
			else
				vim.notify("Global enhanced link without specific target.", vim.log.levels.WARN)
			end
		else
			vim.notify("Unknown scope for enhanced link: " .. def.scope, vim.log.levels.WARN)
		end

	elseif link_info.type == "file_path_heuristic" then
		local expanded_path = vim.fn.expand(link_info.path)
		vim.cmd("edit " .. vim.fn.fnameescape(expanded_path))
	elseif link_info.type == "file_md_style" then -- [text](url)
		local resolved_url = link_info.url
		-- Basic relative path resolution (assuming relative to current file or notes_dir)
		if not (resolved_url:match("^https?://") or resolved_url:match("^/") or resolved_url:match("^[a-zA-Z]:[\\/]")) then
			if (resolved_url:sub(1,2) == "./" or resolved_url:sub(1,3) == "../") and current_file_dir and current_file_dir ~= "" then
				resolved_url = joinpath(current_file_dir, resolved_url)
			else
				local notes_dir = vim.g.zortex_notes_dir
				if notes_dir and notes_dir ~= "" then
					resolved_url = joinpath(notes_dir, resolved_url)
				end
			end
		end
		-- Check if it's a local file path that should be edited or an external URL
		if resolved_url:match("^https?://") or not vim.fn.filereadable(vim.fn.expand(resolved_url)) then
			M.open_external(resolved_url)
		else
			vim.cmd("edit " .. vim.fn.fnameescape(resolved_url))
		end
	elseif link_info.type == "footernote_ref" then
		local pattern_str = "^\\%V\\[\\^" .. vim.fn.escape(link_info.ref_id, "") .. "\\]:\\s*"
		local original_cursor = vim.api.nvim_win_get_cursor(0)
		vim.api.nvim_win_set_cursor(0, {1,0}) -- Start search from beginning of buffer
		local found_pos = vim.fn.searchpos(pattern_str, "w")

		if found_pos[1] ~= 0 and found_pos[2] ~= 0 then
			vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 })
			vim.cmd("normal! zvzz")
		else
			vim.notify("Footnote definition [^" .. link_info.ref_id .. "]: not found.", vim.log.levels.WARN)
			vim.api.nvim_win_set_cursor(0, original_cursor)
		end
	elseif link_info.type == "website" or link_info.type == "zortex_ref_link" then
		M.open_external(link_info.url)
	elseif (link_info.type == "text_heading" or link_info.type == "text_list_item") and link_info.name and link_info.name ~= "" then
		-- This is for non-link text that happens to be a heading/list item on the line.
		-- The original code searched for this text. This might be for a different feature.
		-- For "open link", this shouldn't trigger unless it was parsed as an actual link.
		vim.notify("Context is '".. link_info.type .."'. Use a dedicated command to search for this text if intended.", vim.log.levels.INFO)
		-- M.search_in_current_buffer({{ type = "generic", text = link_info.name }}, current_filename_full)
	else
		vim.notify("Link type not fully handled or invalid: " .. (link_info.type or "unknown"), vim.log.levels.INFO)
	end
end

return M
