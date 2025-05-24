-- Personal Wikipedia Link Parser and Opener
-- Updated with advanced article link parsing and navigation

-- M.open_link()
-- Remove: M.open_external(
--   "https://en.wikipedia.org/wiki/Special:Search/" .. vim.fn.fnameescape(link.article_name_query)
-- )
--
-- create_search_pattern_for_part()
-- the `+` in search_pattern regex should be escaped `\\+`. So:
-- search_pattern = "\\c^#\\+\\s*" .. vim.fn.escape(part:sub(2), "\\")

local M = {}

-- For Neovim 0.7+ path joining, otherwise use manual concatenation.
local joinpath = vim.fs and vim.fs.joinpath
	or function(...)
		local parts = { ... }
		local path = table.remove(parts, 1)
		for _, part in ipairs(parts) do
			if path:sub(-1) ~= "/" and part:sub(1, 1) ~= "/" then
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
	footernote = vim.regex("\\[^(\\d\\+)]"),
	fragment = vim.regex("\\v\\|([^|]+)\\|"),
}

-- Regex patterns for vim.fn.matchlist (string format)
M.patterns = {
	website = "\\vhttps?://[^);}]+",
	file = "\\v\\[([^]]+)]\\(([^)]+)\\)", -- Captures: 1=name, 2=url
	zortex_link = "\\vref=([^\\s;}]+)", -- Captures: 1=url
	generic_bracket_link = "\\v\\[([^]]+)]", -- For initial catch of [Content]
	file_path = "\\v(^|\\s)([~.]?/[/\\S]+)($|\\s)",
	heading = "\\v^#+ (.*)$", -- This is for the simple "heading" type, not complex article search
	list_item = "\\v^(\\s*)- (.*)$",
}

--- Helper function to get 0-indexed cursor column
local function get_cursor_col_0idx()
	return vim.api.nvim_win_get_cursor(0)[2]
end

--- Iteratively match a regex on a line for cursor-sensitive links.
local function extract_link_iteratively(line, cursor_col_0idx, regex_obj, type_name, result_builder)
	local search_offset_0idx = 0
	local final_match_data = nil
	while search_offset_0idx < #line do
		local captures = regex_obj:match_str(line, search_offset_0idx)
		if not captures then
			break
		end
		local full_match_info, group1_info = captures[1], captures[2]
		if not full_match_info or not group1_info then
			break
		end

		local match_start_0idx, match_end_0idx = full_match_info[1], full_match_info[2]
		if cursor_col_0idx < match_end_0idx then
			final_match_data = result_builder(line, {
				full_match_text = string.sub(line, match_start_0idx + 1, match_end_0idx),
				group1_text = string.sub(line, group1_info[1] + 1, group1_info[2]),
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

--- Parses the content of a generic bracket link `[content]` for complex article syntaxes.
-- @param link_content string The text inside the brackets.
-- @return table|nil A structured table describing the article link, or nil.
function M.parse_complex_article_link_text(link_content)
	if link_content == "" then
		return nil
	end

	local result = {
		original_text = link_content,
		article_name_query = nil,
		search_path_parts = {}, -- e.g., {"#Heading", ":Label", "General Text"}
		search_globally = false,
		search_current_only = false,
	}

	-- Check for global search: [#text] or [:text]
	if link_content:sub(1, 1) == "#" or link_content:sub(1, 1) == ":" then
		result.type = "article_spec"
		result.search_globally = true
		table.insert(result.search_path_parts, link_content) -- Store the full #text or :text
		return result
	end

	-- Check for current article search: [/text]
	-- Allow [/], [/#Heading], [/:Label]
	if link_content:sub(1, 1) == "/" then
		result.type = "article_spec"
		result.search_current_only = true
		local part_after_slash = link_content:sub(2)
		if part_after_slash == "" then -- Case: [/] - search for article name in current file? Or just open current file?
		-- For now, let's assume [/] means search for nothing specific, just be in current article.
		-- Or it could mean search for the current buffer's main article name.
		-- This behavior might need further clarification. Let's make it a no-op for search_path_parts.
		else
			table.insert(result.search_path_parts, part_after_slash)
		end
		return result
	end

	-- Check for [ArticleName/path/parts] or [ArticleName]
	local parts = {}
	-- Split by / but keep # and : as part of the subsequent token if they are after /
	-- Example: "Article/#Head/:Label/Text" -> {"Article", "#Head", ":Label", "Text"}
	for part in string.gmatch(link_content, "([^/]+)") do
		table.insert(parts, part)
	end

	if #parts == 0 then
		return nil
	end

	result.type = "article_spec"
	result.article_name_query = parts[1]
	if #parts > 1 then
		for i = 2, #parts do
			table.insert(result.search_path_parts, parts[i])
		end
	end
	return result
end

--- Extracts link information from a given line of text.
function M.extract_link(line)
	local match_list
	local cursor_col_0idx -- Lazily initialized
	vim.notify(match_list)

	-- 1. Website Link
	match_list = vim.fn.matchlist(line, M.patterns.website)
	if match_list and match_list[1] and #match_list[1] > 0 then
		return { line = line, type = "website", url = match_list[1] }
	end

	-- 2. File Link: [name](url)
	match_list = vim.fn.matchlist(line, M.patterns.file)
	if match_list and match_list[1] and #match_list[1] > 0 then
		return { line = line, type = "file", name = match_list[2], url = match_list[3] }
	end

	-- 3. Zortex Link: ref=url
	match_list = vim.fn.matchlist(line, M.patterns.zortex_link)
	if match_list and match_list[1] and #match_list[1] > 0 then
		return { line = line, type = "zortex-link", url = match_list[2] }
	end

	local function ensure_cursor_col()
		if not cursor_col_0idx then
			cursor_col_0idx = get_cursor_col_0idx()
		end
	end

	ensure_cursor_col() -- Ensure cursor_col_0idx is available for subsequent checks

	-- 4. Zettel Link: [z:id] (cursor sensitive)
	local zettel_match = extract_link_iteratively(
		line,
		cursor_col_0idx,
		M.regex_iterators.zettel,
		"zettel-link",
		function(l, captures, type_n)
			return { line = l, type = type_n, zettel_id = captures.group1_text }
		end
	)
	if zettel_match then
		return zettel_match
	end

	-- 5. Footernote Link: [^ref] (cursor sensitive)
	local footernote_match = extract_link_iteratively(
		line,
		cursor_col_0idx,
		M.regex_iterators.footernote,
		"footernote",
		function(l, captures, type_n)
			return { line = l, type = type_n, ref = captures.group1_text }
		end
	)
	if footernote_match then
		vim.notify(footernote_match)
		return footernote_match
	end

	-- 6. Fragment Link: |fragment| (cursor sensitive)
	local fragment_match = extract_link_iteratively(
		line,
		cursor_col_0idx,
		M.regex_iterators.fragment,
		"fragment-link",
		function(l, captures, type_n)
			return { line = l, type = type_n, fragment = captures.group1_text }
		end
	)
	if fragment_match then
		return fragment_match
	end

	-- 7. Complex Article Link Parser
	match_list = vim.fn.matchlist(line, M.patterns.generic_bracket_link)
	if match_list and match_list[1] and #match_list[1] > 0 then
		local complex_article_link = M.parse_complex_article_link_text(match_list[2])
		if complex_article_link then
			complex_article_link.line = line
			return complex_article_link
		end
	end

	-- 8. File Path Link
	match_list = vim.fn.matchlist(line, M.patterns.file_path)
	if match_list and match_list[1] and #match_list[1] > 0 then
		return { line = line, type = "path", path = match_list[3] }
	end

	-- 9. List Item
	match_list = vim.fn.matchlist(line, M.patterns.list_item)
	if match_list and match_list[1] and #match_list[1] > 0 then
		return { line = line, type = "text", indent = #match_list[2], name = match_list[3] }
	end

	-- 10. Heading Link (simple type, not complex article search)
	match_list = vim.fn.matchlist(line, M.patterns.heading)
	if match_list and match_list[1] and #match_list[1] > 0 then
		return { line = line, type = "heading", name = match_list[2] }
	end

	return nil
end

function M.find_article_file_path(article_name_query)
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir or notes_dir == "" then
		vim.notify("g:zortex_notes_dir is not set.", vim.log.levels.ERROR)
		return nil
	end

	-- Case-insensitive query matching
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
		end -- No more files

		if file_type == "file" and name:match("%.zortex$") then
			local full_path = joinpath(notes_dir, name)
			local file = io.open(full_path, "r")
			if file then
				local line_num = 0
				for file_line in file:lines() do
					line_num = line_num + 1
					if line_num > 20 then
						break
					end -- Optimization

					if file_line:sub(1, 2) == "@@" then
						local article_title_in_file = file_line:sub(3):gsub("^%s*(.-)%s*$", "%1") -- Trim
						if article_title_in_file:lower() == lower_case_query then
							file:close()
							return full_path
						end
					else
						if line_num == 1 then
							break
						end -- Must start with @@
					end
				end
				file:close()
			end
		end
	end
	vim.notify("Article file not found for: " .. article_name_query, vim.log.levels.INFO)
	return nil
end

--- Creates a search pattern for headings, labels, or general text.
-- @param part string: The search part (e.g., "#Heading", ":Label", "General Text")
-- @return string: The Vim regex pattern.
local function create_search_pattern_for_part(part)
	local search_pattern
	if part:sub(1, 1) == "#" then -- Heading: # Example one
		-- Matches one or more '#', optional spaces, then the text part
		-- Case-insensitive for the text part.
		search_pattern = "\\c^#\\+\\s*" .. vim.fn.escape(part:sub(2), "\\")
	elseif part:sub(1, 1) == ":" then -- Label: Example one:
		-- Matches the text part at the start of the line, followed by anything, ending with ':'
		-- Case-insensitive for the text part.
		search_pattern = "\\c^" .. vim.fn.escape(part:sub(2), "\\") .. ".*:$"
	else -- General text: Example one
		-- Case-insensitive, anywhere on the line (could be refined further if needed)
		search_pattern = "\\c\\V" .. vim.fn.escape(part, "\\")
	end
	return search_pattern
end

function M.search_in_current_buffer(search_parts, current_file_path)
	if not search_parts or #search_parts == 0 then
		return true
	end

	local original_cursor = vim.api.nvim_win_get_cursor(0)
	local current_search_line = 1 -- Start search from the top for the first part

	for i, part_text in ipairs(search_parts) do
		local search_pattern = create_search_pattern_for_part(part_text)
		local search_flags = "w" -- Wrap search by default
		-- \c^#+\s*Hyperfocus

		-- Set cursor to start of search for this part
		vim.api.nvim_win_set_cursor(0, { current_search_line, 0 })

		local found_pos = vim.fn.searchpos(search_pattern, search_flags)

		if found_pos[1] ~= 0 and found_pos[2] ~= 0 then -- Found
			vim.api.nvim_win_set_cursor(0, { found_pos[1], found_pos[2] - 1 })
			current_search_line = found_pos[1] + 1 -- Start next search from the line after the current match
			if current_search_line > vim.api.nvim_buf_line_count(0) then
				current_search_line = vim.api.nvim_buf_line_count(0) -- Don't go past last line
			end

			-- If general text, check for specific forms like ## Text or Text:
			-- This logic might be too aggressive if the initial general text match is sufficient.
			if part_text:sub(1, 1) ~= "#" and part_text:sub(1, 1) ~= ":" then
				local line_content = vim.api.nvim_get_current_line()
				-- Check if the found line itself is a more specific heading/label
				local alt_heading_pattern = create_search_pattern_for_part("##" .. part_text) -- Treat as sub-heading
				local alt_label_pattern = create_search_pattern_for_part(":" .. part_text) -- Treat as label

				if
					not line_content:match(search_pattern) -- if initial broad search landed mid-text
					or (not line_content:match(alt_heading_pattern) and not line_content:match(alt_label_pattern))
				then
					-- Try to find a more specific ## Heading or Label: form from the current position
					vim.api.nvim_win_set_cursor(0, { found_pos[1], 0 }) -- Reset to start of found line
					local found_alt_h = vim.fn.searchpos(alt_heading_pattern, "w")
					vim.api.nvim_win_set_cursor(0, { found_pos[1], 0 }) -- Reset again for label search
					local found_alt_l = vim.fn.searchpos(alt_label_pattern, "w")

					-- Prioritize the more specific match if found on the same line or very close
					if found_alt_h[1] == found_pos[1] then
						vim.api.nvim_win_set_cursor(0, { found_alt_h[1], found_alt_h[2] - 1 })
					elseif found_alt_l[1] == found_pos[1] then
						vim.api.nvim_win_set_cursor(0, { found_alt_l[1], found_alt_l[2] - 1 })
					end
				end
			end
		else
			vim.notify(
				string.format("Search part '%s' not found in %s.", part_text, current_file_path or "current buffer"),
				vim.log.levels.INFO
			)
			vim.api.nvim_win_set_cursor(0, original_cursor)
			return false
		end
	end
	return true -- All parts found
end

function M.search_all_articles_globally(search_text_with_prefix)
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir or notes_dir == "" then
		vim.notify("g:zortex_notes_dir is not set.", vim.log.levels.ERROR)
		return false
	end

	local search_pattern = create_search_pattern_for_part(search_text_with_prefix)
	if not search_pattern then
		vim.notify("Invalid global search query: " .. search_text_with_prefix, vim.log.levels.WARN)
		return false
	end
	-- \c^#+\s*Hyperfocus

	local qf_list = {}
	local scandir_handle = vim.loop.fs_scandir(notes_dir)
	if not scandir_handle then
		vim.notify("Could not scan directory: " .. notes_dir, vim.log.levels.WARN)
		return false
	end

	vim.notify(
		"Searching all articles for: " .. search_text_with_prefix .. " (pattern: " .. search_pattern .. ")",
		vim.log.levels.INFO
	)

	while true do
		local name, file_type = vim.loop.fs_scandir_next(scandir_handle)
		if not name then
			break
		end -- No more files

		if file_type == "file" and name:match("%.zortex$") then
			local full_path = joinpath(notes_dir, name)
			local file = io.open(full_path, "r")
			if file then
				local lnum = 0
				for file_line in file:lines() do
					lnum = lnum + 1
					-- Using string.find with Lua patterns for file line matching,
					-- as vim.fn.matchstr is not available here directly.
					-- We need to convert Vim regex to Lua pattern or use a simpler match.
					-- For now, let's use a direct Lua pattern match, less robust than Vim's regex engine.
					-- This is a key area for potential improvement if complex Vim regex features are needed here.
					-- A simple approach:
					local simplified_text_to_match
					local line_matches = false
					if search_text_with_prefix:sub(1, 1) == "#" then
						simplified_text_to_match = search_text_with_prefix:sub(2) -- Text after #
						if file_line:match("^#+%s*" .. vim.fn.escape(simplified_text_to_match, "%^$().[]*+-?")) then
							line_matches = true
						end
					elseif search_text_with_prefix:sub(1, 1) == ":" then
						simplified_text_to_match = search_text_with_prefix:sub(2) -- Text after :
						if
							file_line:match("^" .. vim.fn.escape(simplified_text_to_match, "%^$().[]*+-?") .. ".*:$")
						then
							line_matches = true
						end
					end

					if line_matches then
						-- Find column of actual text match for better cursor placement
						local col_match_start, _ = file_line:lower():find(simplified_text_to_match:lower(), 1, true)
						table.insert(qf_list, {
							filename = full_path,
							lnum = lnum,
							col = col_match_start or 1,
							text = string.format("[%s] %s", search_text_with_prefix, file_line),
							valid = 1,
						})
					end
				end
				file:close()
			end
		end
	end

	if #qf_list > 0 then
		vim.fn.setqflist(qf_list, "r") -- Replace qf list
		vim.cmd("copen")
		local first_match = qf_list[1]
		vim.cmd("edit " .. vim.fn.fnameescape(first_match.filename))
		vim.api.nvim_win_set_cursor(0, { first_match.lnum, (first_match.col > 0 and first_match.col - 1 or 0) })
		vim.notify(
			string.format("Found %d match(es) for '%s'. First match opened.", #qf_list, search_text_with_prefix),
			vim.log.levels.INFO
		)
		return true
	else
		vim.notify("No matches found for global search: " .. search_text_with_prefix, vim.log.levels.INFO)
		return false
	end
end

function M.open_external(target)
	if not target or target == "" then
		print("Error: No target specified for open_external.")
		return
	end
	local cmd_parts
	if vim.fn.has("macunix") then
		cmd_parts = { "open", target }
	elseif vim.fn.has("unix") then
		cmd_parts = { "xdg-open", target }
	elseif vim.fn.has("win32") or vim.fn.has("win64") then
		cmd_parts = { "cmd", "/c", "start", "", target }
	else
		vim.notify("Unsupported OS for opening external links.", vim.log.levels.WARN)
		return
	end
	vim.fn.jobstart(cmd_parts, { detach = true })
end

function M.open_link()
	local line = vim.api.nvim_get_current_line()
	local current_filename_full = vim.fn.expand("%:p")
	-- local current_filename_no_ext = vim.fn.expand("%:t:r") -- Not used currently

	local link = M.extract_link(line)

	if not link then
		vim.notify("No link found on the current line.", vim.log.levels.INFO)
		return
	end

	vim.fn.setreg("z", vim.inspect(link)) -- Debug register

	if link.type == "article_spec" then
		if link.search_globally then
			M.search_all_articles_globally(link.search_path_parts[1])
		elseif link.search_current_only then
			if #link.search_path_parts > 0 then
				M.search_in_current_buffer(link.search_path_parts, current_filename_full)
			else
				-- If it's just "[/]", it implies current article, no specific search.
				-- Could focus window or do nothing if already in the article.
				vim.notify("Current article context selected.", vim.log.levels.INFO)
			end
		elseif link.article_name_query then
			local article_path = M.find_article_file_path(link.article_name_query)
			if article_path then
				local target_bufnr = vim.fn.bufnr(article_path, true) -- Create buffer if not exists
				if target_bufnr ~= vim.api.nvim_get_current_buf() then
					vim.api.nvim_set_current_buf(target_bufnr)
					-- Or use vim.cmd("edit " .. vim.fn.fnameescape(article_path)) if you prefer 'edit' behavior
				end
				-- vim.cmd("edit " .. vim.fn.fnameescape(article_path))
				vim.defer_fn(function()
					M.search_in_current_buffer(link.search_path_parts, article_path)
				end, 50)
			end
		else
			vim.notify("Invalid article link specification.", vim.log.levels.WARN)
		end
	elseif link.type == "path" then
		local expanded_path = vim.fn.expand(link.path:gsub("^~", vim.fn.expand("~")))
		local stat = vim.loop.fs_stat(expanded_path)
		if stat and stat.type == "directory" then
			vim.cmd("edit " .. vim.fn.fnameescape(expanded_path))
		else
			vim.cmd("edit " .. vim.fn.fnameescape(expanded_path))
		end
	elseif link.type == "fragment-link" then
		local search_pattern = "\\c\\s*- " .. vim.fn.escape(link.fragment, "\\")
		vim.cmd('call search("' .. search_pattern:gsub('"', '\\"') .. '", "sw")')
	elseif link.type == "footernote" then
		local search_pattern = "[^" .. vim.fn.escape(link.ref, "[]") .. "]: "
		vim.cmd('call search("' .. search_pattern:gsub('"', '\\"') .. '", "b")')
	elseif link.type == "zortex-link" then
		M.open_external(link.url)
	elseif link.type == "website" or link.type == "file" then
		if link.url and type(link.url) == "string" and link.url:sub(1, 2) == "./" then
			local notes_dir = vim.g.zortex_notes_dir
			if notes_dir and notes_dir ~= "" then
				link.url = joinpath(notes_dir, link.url:sub(3))
			else
				vim.notify("g:zortex_notes_dir is not set. Cannot resolve relative file path.", vim.log.levels.WARN)
				return
			end
		end
		M.open_external(link.url)
	elseif (link.type == "heading" or link.type == "text") and link.name and link.name ~= "" then
		M.search_in_current_buffer({ link.name }, current_filename_full)
	else
		vim.notify("Link type not fully handled: " .. link.type, vim.log.levels.INFO)
	end
end

return M
