-- core/highlights.lua - Complete syntax highlighting for Zortex
local M = {}

-- TODO: where applicable, move patterns to a combined table "groups" that has highlight name, and regex
-- Define highlight groups
local highlight_groups = {
	-- Headings
	ZortexHeading1 = { bold = true, italic = true, fg = "#eb6f92" },
	ZortexHeading2 = { bold = true, italic = true, fg = "#ea9a97" },
	ZortexHeading3 = { bold = true, italic = true, fg = "#f6c177" },

	-- List markers based on indentation
	ZortexBullet1 = { fg = "#3e8fb0" }, -- • (level 1)
	ZortexBullet2 = { fg = "#9ccfd8" }, -- ◦ (level 2)
	ZortexBullet3 = { fg = "#c4a7e7" }, -- ▸ (level 3)
	ZortexBullet4 = { fg = "#908caa" }, -- ▹ (level 4+)

	-- Tasks
	ZortexTask = { fg = "#f6c177" },
	ZortexTaskDone = { fg = "#908caa", strikethrough = true },
	ZortexTaskCheckbox = { fg = "#ea9a97" },

	-- Links and references
	ZortexLink = { fg = "#3e8fb0", underline = true },
	ZortexLinkDelimiter = { fg = "#908caa" },
	ZortexFootnote = { fg = "#9ccfd8", italic = true },
	ZortexURL = { fg = "#3e8fb0", underline = true },

	-- Text styling
	ZortexBold = { bold = true },
	ZortexItalic = { italic = true },
	ZortexBoldItalic = { bold = true, italic = true },

	-- Structural elements
	ZortexTag = { fg = "#ea9a97" },
	ZortexArticle = { bold = true, fg = "#c4a7e7" },
	ZortexAttribute = { fg = "#908caa", italic = true },
	ZortexLabel = { bold = true, fg = "#3e8fb0" },
	ZortexLabelText = { bold = true, fg = "#f6c177" },
	ZortexLabelList = { bold = true, fg = "#3e8fb0" },
	ZortexLabelListText = { bold = true, fg = "#f6c177" },

	-- Special
	ZortexOperator = { fg = "#ea9a97" },
	ZortexTime = { fg = "#f6c177" },
	ZortexPercent = { fg = "#9ccfd8" },
	ZortexQuote = { fg = "#c4a7e7", italic = true },
}

-- Setup highlight groups
function M.setup_highlights()
	for name, opts in pairs(highlight_groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

-- Pattern matching helpers
local function iter_pattern_matches(line, pattern)
	local start = 1
	return function()
		local s, e, capture = line:find(pattern, start)
		if not s then
			return nil
		end
		start = e + 1
		return { start_col = s - 1, end_col = e, capture = capture }
	end
end

-- Apply syntax highlighting using extmarks
function M.highlight_buffer(bufnr)
	bufnr = bufnr or 0
	local ns_id = vim.api.nvim_create_namespace("zortex_highlights")

	-- Clear existing highlights
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	for lnum, line in ipairs(lines) do
		local row = lnum - 1 -- 0-indexed

		-- Calculate indentation level
		local indent_level = math.floor(#(line:match("^%s*") or "") / 2) + 1

		-- Article titles (@@Title)
		if line:match("^@@") then
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexArticle", row, 0, -1)
		end

		-- Tags (@tag)
		if line:match("^@[^@%(]") then
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexTag", row, 0, -1)
		end

		-- Headings with attribute support
		local heading_level, heading_start, heading_end = line:match("^(#+)()%s+.-()")
		if heading_level then
			local level = #heading_level
			local hl_group = "ZortexHeading" .. math.min(level, 3)

			-- Highlight the heading
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, hl_group, row, 0, -1)

			-- Find and highlight attributes within the heading
			for match in iter_pattern_matches(line, "@%w+%(.-%)") do
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexAttribute", row, match.start_col, match.end_col)
			end
			for match in iter_pattern_matches(line, "@%w+") do
				-- Only highlight if not followed by (
				if not line:sub(match.end_col + 1, match.end_col + 1):match("%(") then
					vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexAttribute", row, match.start_col, match.end_col)
				end
			end
		end

		-- Bold headings (**Text**)
		local bold_heading = line:match("^%*%*[^%*]+%*%*:?$")
		if bold_heading then
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexBold", row, 0, -1)
		end

		-- Labels (...Label:...)
		if not line:find("%.%s.-:") then
			local label_end = line:find(":")
			-- Pure label (^Label:\n)
			if line:match("^%w[^:]+:$") then
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexLabel", row, 0, label_end)
			-- Label with text following (^Label:)
			elseif line:match("^%w[^:]+:%s") then
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexLabelText", row, 0, label_end)
			-- Label on a list (- Label:\n)
			elseif line:match("^%s*-%s*%w[^:]+:$") then
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexLabelList", row, 0, label_end)
			-- Label with text on a list (- Label:)
			elseif line:match("^%s*-%s*%w[^:]+:%s") then
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexLabelListText", row, 0, label_end)
			end
		end

		-- List items with dynamic bullets
		local list_indent, list_marker = line:match("^(%s*)(%-)")
		if list_marker then
			local marker_col = #list_indent
			local bullet_hl = "ZortexBullet" .. math.min(indent_level, 4)

			-- Hide the dash and show a bullet
			local bullets = { "•", "◦", "▸", "▹" }
			local bullet = bullets[math.min(indent_level, #bullets)]

			vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, marker_col, {
				virt_text = { { bullet, bullet_hl } },
				virt_text_pos = "overlay",
				conceal = "", -- Hide the original character
			})
		end

		-- Tasks with checkboxes
		local task_indent, task_marker = line:match("^(%s*)%-%s*%[(.?)%]")
		if task_marker then
			local is_done = task_marker:lower() == "x"
			local checkbox_start = line:find("%[")
			local checkbox_end = line:find("%]") + 1

			-- Highlight the checkbox
			vim.api.nvim_buf_add_highlight(
				bufnr,
				ns_id,
				"ZortexTaskCheckbox",
				row,
				checkbox_start - 1,
				checkbox_end - 1
			)

			-- Apply strikethrough to done tasks
			if is_done then
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexTaskDone", row, checkbox_end, -1)
			end
		end

		if not task_marker then
			-- Links with concealing
			-- [text] style links
			for match in iter_pattern_matches(line, "%[([^%]]+)%]") do
				if not line:sub(match.start_col + 1, match.start_col + 1):match("%^") then -- Not a footnote
					-- Hide the first bracket
					vim.api.nvim_buf_set_extmark(
						bufnr,
						ns_id,
						row,
						match.start_col,
						{ conceal = "", end_col = match.start_col + 1 }
					)
					-- Show the link icon
					vim.api.nvim_buf_set_extmark(
						bufnr,
						ns_id,
						row,
						match.start_col,
						{ virt_text = { { "🔗", "ZortexLinkDelimiter" } }, virt_text_pos = "inline" }
					)

					-- Highlight the link text
					vim.api.nvim_buf_add_highlight(
						bufnr,
						ns_id,
						"ZortexLink",
						row,
						match.start_col + 1,
						match.end_col - 1
					)

					-- Conceal the closing bracket
					vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, match.end_col - 1, {
						conceal = "",
						end_col = match.end_col,
					})
				end
			end

			-- Footnotes [^ref]
			for match in iter_pattern_matches(line, "%[%^([^%]]+)%]") do
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexFootnote", row, match.start_col, match.end_col)
			end
		end

		-- URLs
		for match in iter_pattern_matches(line, "https?://[^%s]+") do
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexURL", row, match.start_col, match.end_col)
		end

		-- Bold text **text**
		for match in iter_pattern_matches(line, "%*%*([^%*]+)%*%*") do
			-- Don't apply if it's a bold heading
			if not bold_heading then
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexBold", row, match.start_col, match.end_col)

				-- Conceal the asterisks
				vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, match.start_col, {
					conceal = "",
					end_col = match.start_col + 2,
				})
				vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, match.end_col - 2, {
					conceal = "",
					end_col = match.end_col,
				})
			end
		end

		-- Italic text *text*
		for match in iter_pattern_matches(line, "%*([^%*]+)%*") do
			-- Skip if within bold text
			local is_within_bold = false
			for bold_match in iter_pattern_matches(line, "%*%*[^%*]+%*%*") do
				if match.start_col >= bold_match.start_col and match.end_col <= bold_match.end_col then
					is_within_bold = true
					break
				end
			end

			if not is_within_bold then
				vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexItalic", row, match.start_col, match.end_col)

				-- Conceal the asterisks
				vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, match.start_col, {
					conceal = "",
					end_col = match.start_col + 1,
				})
				vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, match.end_col - 1, {
					conceal = "",
					end_col = match.end_col,
				})
			end
		end

		-- Times (HH:MM)
		for match in iter_pattern_matches(line, "%d%d?:%d%d") do
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexTime", row, match.start_col, match.end_col)
		end

		-- Percentages
		for match in iter_pattern_matches(line, "%d+%%") do
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexPercent", row, match.start_col, match.end_col)
		end

		-- Operators
		for _, op in ipairs({ ":=", "<->", "->", "<-", "=>", "~>", "!=" }) do
			for match in iter_pattern_matches(line, "%s" .. vim.pesc(op) .. "%s") do
				vim.api.nvim_buf_add_highlight(
					bufnr,
					ns_id,
					"ZortexOperator",
					row,
					match.start_col + 1,
					match.end_col - 1
				)
			end
		end

		-- Quotes
		for match in iter_pattern_matches(line, '"[^"]*"') do
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexQuote", row, match.start_col, match.end_col)
		end
	end
end

-- Setup autocmd for highlighting
function M.setup_autocmd()
	local group = vim.api.nvim_create_augroup("ZortexHighlights", { clear = true })

	-- Enable concealing
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		group = group,
		pattern = "*.zortex",
		callback = function()
			vim.wo.conceallevel = 2
			vim.wo.concealcursor = ""
		end,
	})

	-- Apply highlighting
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile", "TextChanged", "InsertLeave" }, {
		group = group,
		pattern = "*.zortex",
		callback = function(args)
			M.highlight_buffer(args.buf)
		end,
	})
end

return M
