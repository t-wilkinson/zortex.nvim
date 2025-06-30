local M = {}

-- Assuming you have these modules available
local extract_link = require("zortex.extract_link")

-- Function to open link at cursor or search forward on the line
function M.open_link_or_search_forward()
	local line = vim.api.nvim_get_current_line()
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local row = cursor_pos[1]
	local col = cursor_pos[2] -- 0-indexed column

	-- First, try to extract link at current cursor position
	local link_data = extract_link.extract_link(line)

	if link_data then
		-- Found a link at cursor, open it
		M.open_link_with_mode(true, link_data) -- true for split mode
		return
	end

	-- No link at cursor, search forward on the line
	-- Save original cursor position
	local original_col = col

	-- Try each position from cursor to end of line
	for new_col = col + 1, #line - 1 do
		-- Temporarily move cursor to new position
		vim.api.nvim_win_set_cursor(0, { row, new_col })

		-- Check for link at new position
		link_data = extract_link.extract_link(line)

		if link_data then
			-- Found a link, open it
			M.open_link_with_mode(true, link_data) -- true for split mode
			return
		end
	end

	-- No link found forward on the line, restore cursor position
	vim.api.nvim_win_set_cursor(0, { row, original_col })
	vim.notify("No link found on current line", vim.log.levels.INFO)
end

-- Core function to open links based on type and mode
-- @param split_mode boolean - true to open in split, false for current window
-- @param link_data table - link information from extract_link
function M.open_link_with_mode(split_mode, link_data)
	if not link_data then
		return
	end

	-- Prepare window command based on mode
	local window_cmd = split_mode and "split" or "edit"

	-- Handle different link types
	if link_data.type == "website" then
		-- Open website in browser
		local url = link_data.url
		if vim.fn.has("mac") == 1 then
			vim.fn.system({ "open", url })
		elseif vim.fn.has("unix") == 1 then
			vim.fn.system({ "xdg-open", url })
		elseif vim.fn.has("win32") == 1 then
			vim.fn.system({ "start", url })
		end
	elseif link_data.type == "file_md_style" or link_data.type == "file_path_heuristic" then
		-- Open file links
		local path = link_data.url or link_data.path
		if path then
			-- Expand path (handle ~, relative paths, etc.)
			path = vim.fn.expand(path)
			if vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1 then
				vim.cmd(window_cmd .. " " .. vim.fn.fnameescape(path))
			else
				vim.notify("File not found: " .. path, vim.log.levels.WARN)
			end
		end
	elseif link_data.type == "enhanced_link" then
		-- Handle enhanced links based on their definition
		local def = link_data.definition_details
		if def then
			if def.article_specifier then
				-- Open specific article
				local article_path = def.article_specifier .. ".md" -- Assuming .md extension
				if vim.fn.filereadable(article_path) == 1 then
					vim.cmd(window_cmd .. " " .. vim.fn.fnameescape(article_path))

					-- Navigate to specific target if specified
					if def.target_type == "heading" and def.target_text ~= "" then
						M.navigate_to_heading(def.target_text)
					elseif def.target_type == "label" and def.target_text ~= "" then
						M.navigate_to_label(def.target_text)
					end
				else
					vim.notify("Article not found: " .. article_path, vim.log.levels.WARN)
				end
			elseif def.scope == "local" then
				-- Navigate within current file
				if def.target_type == "heading" then
					M.navigate_to_heading(def.target_text)
				elseif def.target_type == "label" then
					M.navigate_to_label(def.target_text)
				elseif def.target_type == "article_root" then
					-- Go to top of current file
					vim.cmd("normal! gg")
				end
			else
				-- Global scope - search across files
				vim.notify("Global link search not implemented yet", vim.log.levels.INFO)
			end
		end
	elseif link_data.type == "footernote_ref" then
		-- Navigate to footnote definition
		M.navigate_to_footnote(link_data.ref_id)
	elseif link_data.type == "text_heading" then
		-- For headings, could implement a jump to next/previous heading
		vim.notify("Heading navigation not implemented", vim.log.levels.INFO)
	else
		vim.notify("Unknown link type: " .. (link_data.type or "nil"), vim.log.levels.WARN)
	end
end

-- Helper function to navigate to a heading in the current buffer
function M.navigate_to_heading(heading_text)
	if not heading_text or heading_text == "" then
		return
	end

	-- Search for markdown heading
	local search_pattern = "^#\\+\\s\\+" .. vim.fn.escape(heading_text, "\\")
	local found = vim.fn.search(search_pattern, "w")

	if found == 0 then
		vim.notify("Heading not found: " .. heading_text, vim.log.levels.WARN)
	end
end

-- Helper function to navigate to a label in the current buffer
function M.navigate_to_label(label_name)
	if not label_name or label_name == "" then
		return
	end

	-- Search for label definition: ^LabelName:
	local search_pattern = "^\\^" .. vim.fn.escape(label_name, "\\") .. ":"
	local found = vim.fn.search(search_pattern, "w")

	if found == 0 then
		vim.notify("Label not found: " .. label_name, vim.log.levels.WARN)
	end
end

-- Helper function to navigate to a footnote definition
function M.navigate_to_footnote(ref_id)
	if not ref_id or ref_id == "" then
		return
	end

	-- Search for footnote definition: [^ref_id]:
	local search_pattern = "^\\[\\^" .. vim.fn.escape(ref_id, "\\") .. "\\]:"
	local found = vim.fn.search(search_pattern, "w")

	if found == 0 then
		vim.notify("Footnote definition not found: " .. ref_id, vim.log.levels.WARN)
	end
end

return M
