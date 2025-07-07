local M = {}

-- =============================================================================
-- EXTRACT LINK FUNCTIONS
-- =============================================================================

--- Get 0-indexed cursor column
local function get_cursor_col_0idx()
	return vim.api.nvim_win_get_cursor(0)[2]
end

--- Extract link from current line at specified position
-- @param line string The line to extract from
-- @param cursor_col_0idx number Optional 0-indexed cursor column (defaults to actual cursor position)
-- Returns link info table or nil if no link found
function M.extract_link(line, cursor_col_0idx)
	-- Use provided position or get current cursor position
	if cursor_col_0idx == nil then
		cursor_col_0idx = get_cursor_col_0idx()
	end

	-- 1. Check for footnote references [^id] - highest priority
	local offset = 0
	while offset < #line do
		local s, e, ref_id = string.find(line, "%[%^([A-Za-z0-9_.-]+)%]", offset + 1)
		if not s then
			break
		end
		if cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			return {
				type = "footnote",
				ref_id = ref_id,
				display_text = string.sub(line, s, e),
				full_match_text = string.sub(line, s, e),
			}
		end
		offset = e
	end

	-- 2. Check for markdown-style links [text](url)
	offset = 0
	while offset < #line do
		local s, e, text, url = string.find(line, "%[([^%]]*)%]%(([^%)]+)%)", offset + 1)
		if not s then
			break
		end
		if cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			return {
				type = "markdown",
				display_text = text,
				url = url,
				full_match_text = string.sub(line, s, e),
			}
		end
		offset = e
	end

	-- 3. Check for zortex-style links [...] (existing functionality)
	offset = 0
	while offset < #line do
		local s, e = string.find(line, "%[([^%]]+)%]", offset + 1)
		if not s then
			break
		end

		-- Check if cursor is within this link
		if cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			local content = string.sub(line, s + 1, e - 1)

			-- Skip if this is a footnote (starts with ^)
			if content:sub(1, 1) == "^" then
				offset = e
				goto continue
			end

			return {
				type = "link",
				display_text = content,
				definition = content,
				full_match_text = string.sub(line, s, e),
			}
		end

		::continue::
		offset = e
	end

	-- 4. Check for website URLs
	offset = 0
	while offset < #line do
		local s, e = string.find(line, "https?://[^%s%]%)};]+", offset + 1)
		if not s then
			break
		end
		if cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			local url = string.sub(line, s, e)
			return {
				type = "website",
				url = url,
				display_text = url,
				full_match_text = url,
			}
		end
		offset = e
	end

	-- 5. Check for file paths
	-- Match paths starting with ~, ., or / (Unix-style paths)
	offset = 0
	while offset < #line do
		local s, e, path = string.find(line, "([~%.]/[^%s]+)", offset + 1)
		if not s then
			-- Also try absolute paths
			s, e, path = string.find(line, "(/[^%s]+)", offset + 1)
		end
		if not s then
			break
		end
		if cursor_col_0idx >= (s - 1) and cursor_col_0idx < e then
			return {
				type = "filepath",
				path = path,
				display_text = path,
				full_match_text = path,
			}
		end
		offset = e
	end

	return nil
end

--- Search forward from cursor position to find next link on line
-- @param line string The line to search
-- @param start_col number Starting column (0-indexed)
-- Returns link info table or nil if no link found
function M.find_next_link_on_line(line, start_col)
	-- Try each position from start_col to end of line
	for col = start_col, #line - 1 do
		local link_info = M.extract_link(line, col)
		if link_info then
			return link_info
		end
	end
	return nil
end

--- Parse a single component
-- @param component string The component to parse
-- @return table Component info
function M.parse_component(component)
	if not component or component == "" then
		return nil
	end

	local first_char = component:sub(1, 1)

	if first_char == "@" then
		return {
			type = "tag",
			text = component:sub(2),
			original = component,
		}
	elseif first_char == "#" then
		-- Handle # Heading (with space) or #Heading (without space)
		local text = component:sub(2)
		if text:sub(1, 1) == " " then
			text = text:sub(2)
		end
		return {
			type = "heading",
			text = text,
			original = component,
		}
	elseif first_char == ":" then
		return {
			type = "label",
			text = component:sub(2),
			original = component,
		}
	elseif first_char == "-" then
		return {
			type = "listitem",
			text = component:sub(2),
			original = component,
		}
	elseif first_char == "*" then
		return {
			type = "highlight",
			text = component:sub(2),
			original = component,
		}
	elseif first_char == "%" then
		return {
			type = "query",
			text = component:sub(2),
			original = component,
		}
	else
		-- No prefix means it's an article reference
		return {
			type = "article",
			text = component,
			original = component,
		}
	end
end

--- Parse a link definition into its components
-- @param definition string The link definition to parse
-- @return table Parsed link structure
function M.parse_link_definition(definition)
	if not definition or definition == "" then
		return nil
	end

	-- Trim leading/trailing whitespace
	definition = definition:match("^%s*(.-)%s*$")

	local result = {
		scope = "global",
		components = {},
	}

	-- Check for local scope (starts with /)
	if definition:sub(1, 1) == "/" then
		result.scope = "local"
		definition = definition:sub(2) -- Remove leading /
	end

	-- Split by / to get components
	for component in definition:gmatch("[^/]+") do
		-- Trim whitespace from component
		component = component:match("^%s*(.-)%s*$")
		if component ~= "" then
			local comp_info = M.parse_component(component)
			if comp_info then
				table.insert(result.components, comp_info)
			end
		end
	end

	-- If no components but we have a definition, it's an article link
	if #result.components == 0 and definition ~= "" then
		table.insert(result.components, {
			type = "article",
			text = definition,
			original = definition,
		})
	end

	return result
end

-- =============================================================================
-- OPEN LINK FUNCTIONS
-- =============================================================================

-- Helpers --

--- Join path components
local function joinpath(...)
	local parts = { ... }
	local path = table.concat(parts, "/")
	return path:gsub("//+", "/")
end

--- Escape string for Lua pattern matching
local function escape_pattern(text)
	if not text then
		return ""
	end
	return text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

--- Check if buffer is special (has article title in g:zortex_special_articles list)
local function is_special_buffer()
	local special_articles = vim.g.zortex_special_articles or {}
	if type(special_articles) ~= "table" or #special_articles == 0 then
		return false
	end

	-- Check first 5 non-blank lines for article titles
	local lines = vim.api.nvim_buf_get_lines(0, 0, 20, false) -- Get more lines to ensure 5 non-blank
	local non_blank_count = 0

	for _, line in ipairs(lines) do
		if line:match("%S") then -- non-blank line
			non_blank_count = non_blank_count + 1
			local title = line:match("^@@(.+)")
			if title then
				title = title:match("^%s*(.-)%s*$"):lower() -- trim and lowercase
				for _, special in ipairs(special_articles) do
					if special:lower() == title then
						return true
					end
				end
			end
			if non_blank_count >= 5 then
				break
			end
		end
	end

	return false
end

--- Get or create target window for special buffer navigation
local function get_target_window()
	local current_win = vim.api.nvim_get_current_win()
	local all_wins = vim.api.nvim_list_wins()

	-- If only one window and in special buffer, create vertical split
	if #all_wins == 1 and is_special_buffer() then
		vim.cmd("vsplit")
		-- Return the new window (not the current one)
		local new_wins = vim.api.nvim_list_wins()
		for _, win in ipairs(new_wins) do
			if win ~= current_win then
				return win
			end
		end
	end

	-- Otherwise use current window
	return current_win
end

--- Open external link (URL or file)
local function open_external(target)
	if not target or target == "" then
		vim.notify("Error: No target specified for open_external.", vim.log.levels.ERROR)
		return
	end

	local cmd_parts
	if vim.fn.has("macunix") == 1 then
		cmd_parts = { "open", target }
	elseif vim.fn.has("unix") == 1 and vim.fn.executable("xdg-open") == 1 then
		cmd_parts = { "xdg-open", target }
	elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		cmd_parts = { "cmd", "/c", "start", "", target:gsub("/", "\\") }
	else
		vim.notify("Unsupported OS or xdg-open not found for opening external links.", vim.log.levels.WARN)
		return
	end

	vim.fn.jobstart(cmd_parts, { detach = true })
end

-- File Finding Functions --

--- Find all article files in notes directory
local function get_all_article_files()
	local notes_dir = vim.g.zortex_notes_dir
	if not notes_dir or notes_dir == "" then
		vim.notify("g:zortex_notes_dir is not set", vim.log.levels.ERROR)
		return {}
	end

	local files = {}
	local scandir = vim.loop.fs_scandir(notes_dir)
	if not scandir then
		return files
	end

	while true do
		local name, type = vim.loop.fs_scandir_next(scandir)
		if not name then
			break
		end

		if type == "file" and (name:match("%.md$") or name:match("%.zortex$") or name:match("%.txt$")) then
			-- Fix: Ensure we're using table.insert correctly
			local full_path = joinpath(notes_dir, name)
			files[#files + 1] = full_path
		end
	end

	return files
end

--- Find article files by title/alias
local function find_article_files(article_name)
	local files = get_all_article_files()
	local matches = {}
	local search_name = article_name:lower()

	for _, file_path in ipairs(files) do
		local file = io.open(file_path, "r")
		if file then
			local non_blank_count = 0
			for line in file:lines() do
				if line:match("%S") then
					non_blank_count = non_blank_count + 1
					local title = line:match("^@@(.+)")
					if title and title:match("^%s*(.-)%s*$"):lower() == search_name then
						matches[#matches + 1] = file_path
						break
					end
					if non_blank_count >= 5 then
						break
					end
				end
			end
			file:close()
		end
	end

	return matches
end

--- Check if line is a bold heading (format: **text** or **text**:)
local function is_bold_heading(line)
	return line:match("^%*%*[^%*]+%*%*:?$") ~= nil
end

--- Get heading level from line
local function get_heading_level(line)
	local level = 0
	for i = 1, #line do
		if line:sub(i, i) == "#" then
			level = level + 1
		else
			break
		end
	end
	-- Only count as heading if followed by space or end of string
	if level > 0 and (line:sub(level + 1, level + 1) == " " or level == #line) then
		return level
	end
	return 0
end

--- Determine section end based on component type and current position
local function get_section_end(lines, start_lnum, component)
	local num_lines = #lines

	if component.type == "heading" then
		-- Get the level of the heading we found
		local heading_level = get_heading_level(lines[start_lnum])

		-- Section ends at next heading of same or higher level
		for i = start_lnum + 1, num_lines do
			local line_level = get_heading_level(lines[i])
			if line_level > 0 and line_level <= heading_level then
				return i - 1
			end
		end
		return num_lines
	elseif component.type == "tag" then
		-- Tags don't create sections in the traditional sense
		-- But we'll treat the tag line itself as the section
		return start_lnum
	elseif component.type == "label" then
		-- Labels end at next heading, bold heading, or empty line
		for i = start_lnum + 1, num_lines do
			local line = lines[i]
			if line:match("^%s*$") or get_heading_level(line) > 0 or is_bold_heading(line) then
				return i - 1
			end
		end
		return num_lines
	elseif component.type == "listitem" then
		-- List items are single lines
		return start_lnum
	elseif component.type == "highlight" or component.type == "query" then
		-- These don't create sections, just match within current scope
		return start_lnum
	else
		-- Default: no section
		return start_lnum
	end
end

-- Search Functions --

--- Create search pattern for component
local function create_search_pattern(component)
	local text = escape_pattern(component.text)

	if component.type == "tag" then
		return "^@" .. text .. "$"
	elseif component.type == "heading" then
		return "^#+%s*" .. text .. "$"
	elseif component.type == "label" then
		return "^" .. text .. ":"
	elseif component.type == "listitem" then
		return "^%s*- " .. text .. "$"
	elseif component.type == "highlight" then
		-- Match *, **, or *** wrapping
		return "%*%*?%*?" .. text .. "%*%*?%*?"
	elseif component.type == "query" then
		-- Plain substring search
		return text
	elseif component.type == "article" then
		-- This is handled differently - by finding article files
		return nil
	end
end

--- Search for component in files with section boundaries
local function search_component_in_files(component, file_paths, section_bounds)
	local pattern = create_search_pattern(component)
	if not pattern then
		return {}
	end

	local results = {}
	local case_sensitive = component.type == "query" and component.text:match("[A-Z]")

	for _, file_path in ipairs(file_paths) do
		local file = io.open(file_path, "r")
		if file then
			local lines = {}
			for line in file:lines() do
				lines[#lines + 1] = line
			end
			file:close()

			-- Determine search bounds for this file
			local start_line = 1
			local end_line = #lines

			if section_bounds and section_bounds[file_path] then
				start_line = section_bounds[file_path].start_line or 1
				end_line = section_bounds[file_path].end_line or #lines
			end

			-- Search within bounds
			for lnum = start_line, end_line do
				local line = lines[lnum]
				local search_line = case_sensitive and line or line:lower()
				local search_pattern = case_sensitive and pattern or pattern:lower()

				if search_line:find(search_pattern) then
					results[#results + 1] = {
						file = file_path,
						lnum = lnum,
						col = search_line:find(search_pattern),
						text = line,
						component = component,
						lines = lines, -- Store lines for section determination
					}
				end
			end
		end
	end

	return results
end

--- Search in current buffer with section boundaries
local function search_in_buffer(component, start_line, end_line)
	local pattern = create_search_pattern(component)
	if not pattern then
		return {}
	end

	local results = {}
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local case_sensitive = component.type == "query" and component.text:match("[A-Z]")
	local current_file = vim.fn.expand("%:p")

	start_line = start_line or 1
	end_line = end_line or #lines

	for lnum = start_line, end_line do
		local line = lines[lnum]
		local search_line = case_sensitive and line or line:lower()
		local search_pattern = case_sensitive and pattern or pattern:lower()

		if search_line:find(search_pattern) then
			results[#results + 1] = {
				file = current_file,
				lnum = lnum,
				col = search_line:find(search_pattern),
				text = line,
				component = component,
				lines = lines,
			}
		end
	end

	return results
end

--- Populate quickfix list with results
local function populate_quickfix(results)
	local qf_list = {}

	for _, result in ipairs(results) do
		local text = string.format("[%s: %s] %s", result.component.type, result.component.text, result.text:sub(1, 80))

		qf_list[#qf_list + 1] = {
			filename = result.file,
			lnum = result.lnum,
			col = result.col,
			text = text,
			valid = 1,
		}
	end

	vim.fn.setqflist(qf_list, "r")
	if #qf_list > 0 then
		vim.cmd("copen")
	end
end

--- Jump to location
local function jump_to_location(location, use_target_window)
	local target_win = use_target_window and get_target_window() or vim.api.nvim_get_current_win()

	-- Load file in target window
	local bufnr = vim.fn.bufadd(location.file)
	vim.api.nvim_win_set_buf(target_win, bufnr)

	-- Set cursor position
	vim.api.nvim_win_set_cursor(target_win, { location.lnum, location.col - 1 })

	-- Center view
	vim.api.nvim_win_call(target_win, function()
		vim.cmd("normal! zz")
	end)
end

-- Main Functions --

--- Process link components and return results
local function process_link(parsed_link)
	local results = {}
	local file_set = nil
	local section_bounds = {} -- Track section boundaries per file

	-- Determine initial file set based on scope
	if parsed_link.scope == "local" then
		-- Local scope - search only in current buffer
		local current_bounds = { start_line = 1, end_line = nil }

		for i, component in ipairs(parsed_link.components) do
			local component_results = search_in_buffer(component, current_bounds.start_line, current_bounds.end_line)

			if i == #parsed_link.components then
				-- Last component - return all matches
				for _, r in ipairs(component_results) do
					results[#results + 1] = r
				end
			else
				-- Not last component - narrow search scope
				if #component_results == 0 then
					vim.notify("No matches found for: " .. component.original, vim.log.levels.INFO)
					return {}
				end

				-- Use first match to determine new bounds
				local first_match = component_results[1]
				current_bounds.start_line = first_match.lnum
				current_bounds.end_line = get_section_end(first_match.lines, first_match.lnum, component)
			end
		end

		return results
	else
		-- Global scope - start with all files
		file_set = get_all_article_files()
	end

	-- Process components sequentially
	for i, component in ipairs(parsed_link.components) do
		if component.type == "article" then
			-- Narrow file set to matching articles
			file_set = find_article_files(component.text)
			if #file_set == 0 then
				vim.notify("No article found: " .. component.text, vim.log.levels.INFO)
				return {}
			end
			-- Reset section bounds for new file set
			section_bounds = {}

			-- If this is the last component and we found exactly one file, create a result
			if i == #parsed_link.components and #file_set == 1 then
				results[#results + 1] = {
					file = file_set[1],
					lnum = 1,
					col = 1,
					text = "Article: " .. component.text,
					component = component,
				}
			end
		else
			-- Search for component in current file set with section bounds
			local component_results = search_component_in_files(component, file_set, section_bounds)

			if i == #parsed_link.components then
				-- Last component - these are our final results
				for _, r in ipairs(component_results) do
					results[#results + 1] = r
				end
			else
				-- Not last component - update section bounds for next iteration
				if #component_results == 0 then
					vim.notify("No matches found for: " .. component.original, vim.log.levels.INFO)
					return {}
				end

				-- Create new section bounds based on matches
				local new_file_set = {}
				local new_section_bounds = {}
				local seen_files = {}

				for _, match in ipairs(component_results) do
					if not seen_files[match.file] then
						seen_files[match.file] = true
						new_file_set[#new_file_set + 1] = match.file

						-- Calculate section bounds for this match
						local section_end = get_section_end(match.lines, match.lnum, component)
						new_section_bounds[match.file] = {
							start_line = match.lnum,
							end_line = section_end,
						}
					end
				end

				file_set = new_file_set
				section_bounds = new_section_bounds

				if #file_set == 0 then
					vim.notify("No matches found for: " .. component.original, vim.log.levels.INFO)
					return {}
				end
			end
		end
	end

	return results
end

--- Search for footnote definition in current buffer
local function search_footnote(ref_id)
	local pattern = "^%[%^" .. escape_pattern(ref_id) .. "%]:%s*"
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

	for lnum, line in ipairs(lines) do
		if line:find(pattern) then
			return { lnum = lnum, col = 1 }
		end
	end

	return nil
end

--- Open link at cursor or search forward
function M.open_link()
	local line = vim.api.nvim_get_current_line()
	local cursor_col = get_cursor_col_0idx()

	-- First try to extract link at cursor position
	local link_info = M.extract_link(line)

	-- If no link at cursor, search forward on the line
	if not link_info then
		link_info = M.find_next_link_on_line(line, cursor_col + 1)

		if not link_info then
			vim.notify("No link found on current line", vim.log.levels.INFO)
			return
		end
	end

	-- Handle different link types
	if link_info.type == "link" then
		-- Zortex-style link format
		local parsed = M.parse_link_definition(link_info.definition)
		if not parsed then
			vim.notify("Invalid link format", vim.log.levels.WARN)
			return
		end

		-- Process the link
		local results = process_link(parsed)

		if #results == 0 then
			-- Already notified by process_link
			return
		elseif #results == 1 then
			-- Single result - jump directly
			jump_to_location(results[1], true)
		else
			-- Multiple results - jump to first and populate quickfix
			jump_to_location(results[1], true)
			populate_quickfix(results)
			vim.notify(string.format("Found %d matches. Quickfix list populated.", #results), vim.log.levels.INFO)
		end
	elseif link_info.type == "footnote" then
		-- Handle footnote reference
		local footnote_loc = search_footnote(link_info.ref_id)
		if footnote_loc then
			vim.api.nvim_win_set_cursor(0, { footnote_loc.lnum, footnote_loc.col - 1 })
			vim.cmd("normal! zz")
		else
			vim.notify("Footnote definition [^" .. link_info.ref_id .. "] not found", vim.log.levels.WARN)
		end
	elseif link_info.type == "markdown" then
		-- Handle markdown-style link
		local url = link_info.url

		-- Check if it's a web URL
		if url:match("^https?://") then
			open_external(url)
		else
			-- It's a file path
			local current_dir = vim.fn.expand("%:p:h")
			local resolved_path = url

			-- Handle relative paths
			if not url:match("^/") and not url:match("^[a-zA-Z]:[\\/]") then
				if url:sub(1, 2) == "./" or url:sub(1, 3) == "../" then
					resolved_path = joinpath(current_dir, url)
				else
					-- Try notes directory
					local notes_dir = vim.g.zortex_notes_dir
					if notes_dir and notes_dir ~= "" then
						resolved_path = joinpath(notes_dir, url)
					end
				end
			end

			-- Check if file exists
			if vim.fn.filereadable(vim.fn.expand(resolved_path)) == 1 then
				local target_win = get_target_window()
				local bufnr = vim.fn.bufadd(resolved_path)
				vim.api.nvim_win_set_buf(target_win, bufnr)
			else
				-- If file doesn't exist, try opening as external URL
				open_external(url)
			end
		end
	elseif link_info.type == "website" then
		-- Handle direct URL
		open_external(link_info.url)
	elseif link_info.type == "filepath" then
		-- Handle file path
		local expanded_path = vim.fn.expand(link_info.path)
		if vim.fn.filereadable(expanded_path) == 1 or vim.fn.isdirectory(expanded_path) == 1 then
			local target_win = get_target_window()
			local bufnr = vim.fn.bufadd(expanded_path)
			vim.api.nvim_win_set_buf(target_win, bufnr)
		else
			vim.notify("File not found: " .. link_info.path, vim.log.levels.WARN)
		end
	end
end

return M
