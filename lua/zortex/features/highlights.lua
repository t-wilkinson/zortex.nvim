-- features/highlights.lua - Complete syntax highlighting for Zortex
local M = {}

--------------------------------------------------------------------------
-- Syntax map ----------------------------------------------------------
--------------------------------------------------------------------------
local Syntax = {
	----------------------------------------------------------------------
	-- Headings (dynamic level → group name) ------------------------------
	----------------------------------------------------------------------
	Heading = {
		patterns = {
			{
				regex = "^(#+)%s+",
				dynamic_group = function(caps)
					local level = #caps[1]
					return "ZortexHeading" .. math.min(level, 3)
				end,
				range = function(match, line)
					return 0, -1 -- full line
				end,
			},
		},
	},

	----------------------------------------------------------------------
	-- Article titles -----------------------------------------------------
	----------------------------------------------------------------------
	Article = {
		opts = { bold = true, fg = "#c4a7e7" },
		patterns = {
			{
				regex = "^@@",
				range = function()
					return 0, -1
				end,
			},
		},
	},

	----------------------------------------------------------------------
	-- Tags ---------------------------------------------------------------
	----------------------------------------------------------------------
	Tag = {
		opts = { fg = "#ea9a97" },
		patterns = {
			{
				regex = "^@[^@([]",
				range = function()
					return 0, -1
				end,
			},
		},
	},

	----------------------------------------------------------------------
	-- Bold headings ------------------------------------------------------
	----------------------------------------------------------------------
	BoldHeading = {
		opts = { bold = true },
		patterns = {
			{
				regex = "^%*%*[^%*]+%*%*:?$",
				range = function()
					return 0, -1
				end,
			},
		},
	},

	----------------------------------------------------------------------
	-- Labels (4 distinct types) ------------------------------------------
	----------------------------------------------------------------------
	Label = {
		opts = { bold = true, fg = "#3e8fb0" },
		patterns = {
			{
				regex = "^(%w[^:]+):$",
				condition = function(line)
					return not line:find("%.%s.-:")
				end,
				range = function(match)
					return 0, match.end_col - 1
				end,
			},
		},
	},

	LabelText = {
		opts = { bold = true, fg = "#f6c177" },
		patterns = {
			{
				regex = "^(%w[^:]+):%s",
				condition = function(line)
					return not line:find("%.%s.-:")
				end,
				range = function(match)
					return 0, match.start_col + #match.caps[1] + 1
				end,
			},
		},
	},

	LabelList = {
		opts = { bold = true, fg = "#3e8fb0" },
		patterns = {
			{
				regex = "^%s*-%s*(%w[^:]+):$",
				condition = function(line)
					return not line:find("%.%s.-:")
				end,
				range = function(match, line)
					local label_end = line:find(":")
					return 0, label_end
				end,
			},
		},
	},

	LabelListText = {
		opts = { bold = true, fg = "#f6c177" },
		patterns = {
			{
				regex = "^%s*-%s*(%w[^:]+):%s",
				condition = function(line)
					return not line:find("%.%s.-:")
				end,
				range = function(match, line)
					local label_end = line:find(":")
					return 0, label_end
				end,
			},
		},
	},

	----------------------------------------------------------------------
	-- List bullets (dynamic based on indent) -----------------------------
	----------------------------------------------------------------------
	ListBullet = {
		patterns = {
			{
				regex = "^(%s*)(%-)",
				dynamic_group = function(caps, line)
					local indent_level = math.floor(#caps[1] / 2) + 1
					return "ZortexBullet" .. math.min(indent_level, 4)
				end,
				conceal = {
					type = "bullet",
					get_text = function(caps, line)
						local indent_level = math.floor(#caps[1] / 2) + 1
						local bullets = { "•", "◦", "▸", "▹" }
						return bullets[math.min(indent_level, #bullets)]
					end,
				},
			},
		},
	},

	----------------------------------------------------------------------
	-- Number lists -------------------------------------------------------
	----------------------------------------------------------------------
	NumberList = {
		opts = { fg = "#3e8fb0", bold = true },
		patterns = {
			{
				regex = "^(%s*)(%d+)%.",
				range = function(match)
					return match.start_col, match.end_col
				end,
			},
		},
	},

	----------------------------------------------------------------------
	-- Text lists (A. B. C. etc) ------------------------------------------
	----------------------------------------------------------------------
	TextList = {
		opts = { fg = "#3e8fb0", bold = true },
		patterns = {
			{
				regex = "^(%s*)([A-Z]%w*)%.",
				range = function(match)
					return match.start_col, match.end_col
				end,
			},
		},
	},

	----------------------------------------------------------------------
	-- Tasks with checkboxes ----------------------------------------------
	----------------------------------------------------------------------
	TaskCheckbox = {
		opts = { fg = "#ea9a97" },
		patterns = {
			{
				regex = "(%s*)%-%s*(%[(.?)%])",
				range = function(match)
					local checkbox_start = match.start_col + #match.caps[1] + 1
					local checkbox_end = checkbox_start + #match.caps[2] + 1
					return checkbox_start, checkbox_end
				end,
				conceal = {
					type = "task",
					get_text = function(caps)
						local marker = caps[3]:lower()
						if marker == "" or marker == " " then
							return " "
						end
						return nil -- keep original
					end,
				},
			},
		},
	},

	TaskText = {
		opts = { fg = "#f6c177" },
		patterns = {
			{
				regex = "(%s*)%-%s*%[(.?)%]%s+(.+)",
				range = function(match)
					-- Find the position after "] "
					local bracket_pos = match.line:find("%]", match.start_col)
					if bracket_pos then
						-- Start highlighting after the space following ]
						local text_start = bracket_pos + 1
						-- Skip any spaces
						while text_start <= #match.line and match.line:sub(text_start, text_start):match("%s") do
							text_start = text_start + 1
						end
						return text_start - 1, -1
					end
					return nil, nil
				end,
				condition = function(line, match)
					local marker = match.caps[2]:lower()
					return marker ~= "x"
				end,
			},
		},
	},

	TaskDone = {
		opts = { fg = "#908caa", strikethrough = true },
		patterns = {
			{
				regex = "(%s*)%-%s*%[(.?)%]%s+(.+)",
				range = function(match)
					-- Same logic as TaskText
					local bracket_pos = match.line:find("%]", match.start_col)
					if bracket_pos then
						local text_start = bracket_pos + 1
						while text_start <= #match.line and match.line:sub(text_start, text_start):match("%s") do
							text_start = text_start + 1
						end
						return text_start - 1, -1
					end
					return nil, nil
				end,
				condition = function(line, match)
					local marker = match.caps[2]:lower()
					return marker == "x"
				end,
			},
		},
	},

	----------------------------------------------------------------------
	-- Links and references -----------------------------------------------
	----------------------------------------------------------------------
	Link = {
		opts = { fg = "#3e8fb0", underline = true },
		patterns = {
			{
				regex = "%[([^]]+)%]",
				condition = function(line, match)
					-- Not a footnote and not a task
					local char = line:sub(match.start_col + 2, match.start_col + 2)
					local task_chars = " xX~@"
					return char ~= "^" and not (match.caps[1]:len() == 1 and task_chars:find(match.caps[1], 1, true))
				end,
				range = function(match)
					return match.start_col + 1, match.end_col - 1
				end,
				conceal = {
					type = "link",
					brackets = true,
					icon = "🔗",
				},
			},
		},
	},

	Footnote = {
		opts = { fg = "#9ccfd8", italic = true },
		patterns = { "%[%^([^]]+)%]" },
	},

	URL = {
		opts = { fg = "#3e8fb0", underline = true },
		patterns = { "https?://[^%s]+" },
	},

	----------------------------------------------------------------------
	-- Text styling -------------------------------------------------------
	----------------------------------------------------------------------
	Bold = {
		opts = { bold = true },
		patterns = {
			{
				regex = "%*%*([^%*]+)%*%*",
				condition = function(line)
					-- Not a bold heading
					return not line:match("^%*%*[^%*]+%*%*:?$")
				end,
				conceal = { type = "markers", chars = 2 },
			},
		},
	},

	Italic = {
		opts = { italic = true },
		patterns = {
			{
				regex = "%*([^%*]+)%*",
				condition = function(line, match)
					-- Not within bold text
					for s, e in line:gmatch("()%*%*[^%*]+%*%*()") do
						if match.start_col >= s - 1 and match.end_col <= e - 1 then
							return false
						end
					end
					return true
				end,
				conceal = { type = "markers", chars = 1 },
			},
		},
	},

	----------------------------------------------------------------------
	-- Code and LaTeX -----------------------------------------------------
	----------------------------------------------------------------------
	CodeInline = {
		opts = { fg = "#f2ae49", bg = "#2d2a2e" },
		patterns = {
			{
				regex = "%s`([^`]+)`%s",
				range = function(match)
					-- Adjust to exclude leading space
					return match.start_col + 1, match.end_col - 1
				end,
			},
			{
				regex = "%s`([^`]+)`$",
				range = function(match)
					-- At end of line
					return match.start_col + 1, match.end_col
				end,
			},
			{
				regex = "^`([^`]+)`%s",
				range = function(match)
					-- At start of line
					return match.start_col, match.end_col - 1
				end,
			},
		},
	},

	MathInline = {
		opts = { fg = "#a9d977", italic = true },
		patterns = {
			{
				regex = "%s%$([^%s$][^$]*)%$%s",
				range = function(match)
					return match.start_col + 1, match.end_col - 1
				end,
			},
			{
				regex = "%s%$([^%s$][^$]*)%$$",
				range = function(match)
					return match.start_col + 1, match.end_col
				end,
			},
			{
				regex = "^%$([^%s$][^$]*)%$%s",
				range = function(match)
					return match.start_col, match.end_col - 1
				end,
			},
		},
	},

	MathBlock = {
		opts = { fg = "#a9d977", italic = true },
		patterns = {
			"%$%$(.-)%$%$",
			"\\%[(.-)\\%]",
		},
	},

	----------------------------------------------------------------------
	-- Attributes (ONLY on headings and tasks) ----------------------------
	----------------------------------------------------------------------
	Attribute = {
		opts = { fg = "#908caa", italic = true },
		patterns = {
			{
				regex = "@%w+%(.-%)",
				condition = function(line)
					-- Only on lines with headings or tasks
					return line:match("^#") or line:match("^%s*-%s*%[.?%]")
				end,
			},
			{
				regex = "@%w+",
				condition = function(line, match)
					-- Only on lines with headings or tasks, and not followed by (
					return (line:match("^#") or line:match("^%s*-%s*%[.?%]"))
						and not line:sub(match.end_col + 1, match.end_col + 1):match("%(")
				end,
			},
		},
	},

	----------------------------------------------------------------------
	-- Special elements ---------------------------------------------------
	----------------------------------------------------------------------
	Time = {
		opts = { fg = "#f6c177" },
		patterns = { "%d%d?:%d%d" },
	},

	Percent = {
		opts = { fg = "#9ccfd8" },
		patterns = { "%d+%%" },
	},

	Operator = {
		opts = { fg = "#ea9a97" },
		patterns = {
			{ regex = "%s(:=)%s", capture = 1 },
			{ regex = "%s(<->)%s", capture = 1 },
			{ regex = "%s(->)%s", capture = 1 },
			{ regex = "%s(<-)%s", capture = 1 },
			{ regex = "%s(=>)%s", capture = 1 },
			{ regex = "%s(~>)%s", capture = 1 },
			{ regex = "%s(!=)%s", capture = 1 },
			{ regex = "%s(+)%s", capture = 1 },
			{ regex = "%s(vs.)%s", capture = 1 },
		},
	},

	Punctuation = {
		opts = { fg = "#ea9a97" },
		patterns = {
			{ regex = "(%.)%s", capture = 1 },
			{ regex = "(%.)$", capture = 1 },
			{ regex = "(,)%s", capture = 1 },
			{ regex = "(?)%s", capture = 1 },
			{ regex = "(?)$", capture = 1 },
		},
	},

	Quote = {
		opts = { fg = "#c4a7e7", italic = true },
		patterns = { '"([^"]*)"' },
	},
}

--------------------------------------------------------------------------
-- Highlight groups setup ----------------------------------------------
--------------------------------------------------------------------------
local function setup_highlight_groups()
	-- Heading colors
	vim.api.nvim_set_hl(0, "ZortexHeading1", { bold = true, italic = true, fg = "#eb6f92" })
	vim.api.nvim_set_hl(0, "ZortexHeading2", { bold = true, italic = true, fg = "#ea9a97" })
	vim.api.nvim_set_hl(0, "ZortexHeading3", { bold = true, italic = true, fg = "#f6c177" })

	-- Bullet colors
	vim.api.nvim_set_hl(0, "ZortexBullet1", { fg = "#3e8fb0" })
	vim.api.nvim_set_hl(0, "ZortexBullet2", { fg = "#9ccfd8" })
	vim.api.nvim_set_hl(0, "ZortexBullet3", { fg = "#c4a7e7" })
	vim.api.nvim_set_hl(0, "ZortexBullet4", { fg = "#908caa" })

	-- Code block highlight
	vim.api.nvim_set_hl(0, "ZortexCodeBlock", { fg = "#f2ae49", bg = "#1e1c1f" })

	-- Set up highlights from syntax definitions
	for name, def in pairs(Syntax) do
		if def.opts then
			vim.api.nvim_set_hl(0, "Zortex" .. name, def.opts)
		end
	end
end

--------------------------------------------------------------------------
-- Pattern matching engine ---------------------------------------------
--------------------------------------------------------------------------
local function find_pattern_matches(line, pattern_def)
	local matches = {}
	local regex = pattern_def.regex or pattern_def
	local is_string = type(pattern_def) == "string"

	local start = 1
	while true do
		local s, e, cap1, cap2, cap3 = line:find(regex, start)
		if not s then
			break
		end

		local match = {
			start_col = s - 1,
			end_col = e,
			caps = { cap1, cap2, cap3 },
			line = line,
		}

		-- Apply condition check
		if not is_string and pattern_def.condition then
			if pattern_def.condition(line, match) then
				table.insert(matches, match)
			end
		else
			table.insert(matches, match)
		end

		start = e + 1
	end

	return matches
end

--------------------------------------------------------------------------
-- Code block tracking -------------------------------------------------
--------------------------------------------------------------------------
-- Table keyed by bufnr → { {start_row, end_row}, ... }
local code_block_ranges = {}

--- Detect all fenced code‑blocks in the buffer.
--  * opening fence  : INDENT … ```[lang]\n  (lang optional)
--  * closing fence  : INDENT … ```        (same INDENT, no lang needed)
--  The INDENT (any mix of spaces/tabs) **must match** for the fences to
--  pair, mirroring GitHub‑flavoured Markdown behaviour inside lists.
local function find_code_blocks(bufnr)
	code_block_ranges[bufnr] = {}

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local in_block = false ---@type boolean
	local block_start = nil ---@type integer|nil
	local block_indent = "" ---@type string  -- stores the exact indent that opened the block

	---@param line string
	---@return string indent|nil, string lang
	local function parse_fence(line)
		-- capture leading whitespace + ```, optionally language id, then only
		-- whitespace to EOL. eg: "    ```python   "
		return line:match("^([ \t]*)```([%w%-%+_]*)%s*$")
	end

	for i, line in ipairs(lines) do
		local indent, _ = parse_fence(line)
		if indent then
			if not in_block then
				-- Opening fence → start new block
				in_block = true
				block_start = i - 1 -- 0‑indexed row for nvim API
				block_indent = indent
			else
				-- Potential closing fence: only accept if indent matches opener
				if indent == block_indent then
					in_block = false
					table.insert(code_block_ranges[bufnr], { block_start, i - 1 })
					block_start = nil
					block_indent = ""
				end
			end
		end
	end

	-- Handle unclosed fence at EOF
	if in_block and block_start then
		table.insert(code_block_ranges[bufnr], { block_start, #lines - 1 })
	end
end

--- Return true if the given row is inside any recorded code‑block.
local function is_in_code_block(bufnr, row)
	for _, range in ipairs(code_block_ranges[bufnr] or {}) do
		if row >= range[1] and row <= range[2] then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------
-- Main highlighting function ------------------------------------------
--------------------------------------------------------------------------
function M.highlight_buffer(bufnr)
	bufnr = bufnr or 0
	local ns_id = vim.api.nvim_create_namespace("zortex_highlights")

	-- Clear
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

	-- Re‑index fenced blocks *first*
	find_code_blocks(bufnr)

	-- Block background highlight
	for _, range in ipairs(code_block_ranges[bufnr]) do
		for row = range[1], range[2] do
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, "ZortexCodeBlock", row, 0, -1)
		end
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- Ordered processing list (unchanged)
	local processing_order = {
		"Article",
		"Tag",
		"Heading",
		"BoldHeading",
		"NumberList",
		"TextList",
		"TaskCheckbox",
		"TaskText",
		"TaskDone",
		"Label",
		"LabelText",
		"LabelList",
		"LabelListText",
		"ListBullet",
		"Link",
		"Footnote",
		"URL",
		"Bold",
		"Italic",
		"CodeInline",
		"MathInline",
		"MathBlock",
		"Attribute",
		"Time",
		"Percent",
		"Operator",
		"Punctuation",
		"Quote",
	}

	for lnum, line in ipairs(lines) do
		local row = lnum - 1 -- 0‑indexed

		-- Skip highlighting for lines *inside* fenced block (but *not* the fences)
		if is_in_code_block(bufnr, row) and not line:match("^[ \t]*```") then
			goto continue
		end

		-- Process each syntax type in order
		for _, syntax_name in ipairs(processing_order) do
			local syntax_def = Syntax[syntax_name]
			if syntax_def then
				for _, pattern_def in ipairs(syntax_def.patterns) do
					local matches = find_pattern_matches(line, pattern_def)

					for _, match in ipairs(matches) do
						-- Determine highlight group
						local hl_group
						if type(pattern_def) == "table" and pattern_def.dynamic_group then
							hl_group = pattern_def.dynamic_group(match.caps, line)
						else
							hl_group = "Zortex" .. syntax_name
						end

						-- Determine range
						local start_col, end_col
						if type(pattern_def) == "table" and pattern_def.range then
							start_col, end_col = pattern_def.range(match, line)
						elseif type(pattern_def) == "table" and pattern_def.capture then
							-- Highlight only the captured group
							local cap_val = match.caps[pattern_def.capture]
							if cap_val then
								local cap_start = line:find(cap_val, match.start_col + 1, true)
								if cap_start then
									start_col = cap_start - 1
									end_col = start_col + #cap_val
								end
							end
						else
							start_col = match.start_col
							end_col = match.end_col
						end

						-- Apply highlight
						if start_col and end_col then
							vim.api.nvim_buf_add_highlight(bufnr, ns_id, hl_group, row, start_col, end_col)
						end

						-- Handle concealing
						if type(pattern_def) == "table" and pattern_def.conceal then
							local conceal = pattern_def.conceal

							if conceal.type == "bullet" then
								local marker_col = #match.caps[1]
								local bullet_text = conceal.get_text(match.caps, line)
								vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, marker_col, {
									virt_text = { { bullet_text, hl_group } },
									virt_text_pos = "overlay",
									conceal = "",
								})
							elseif conceal.type == "task" then
								local text = conceal.get_text(match.caps)
								if text then
									local checkbox_start = line:find("%[", match.start_col)
									if checkbox_start then
										vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, checkbox_start, {
											virt_text = { { text, "ZortexTaskCheckbox" } },
											virt_text_pos = "overlay",
											conceal = " ",
										})
									end
								end
							elseif conceal.type == "link" then
								-- Hide opening bracket and show icon
								vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, match.start_col, {
									conceal = "",
									end_col = match.start_col + 1,
								})
								vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, match.start_col, {
									virt_text = { { conceal.icon, "ZortexLinkDelimiter" } },
									virt_text_pos = "inline",
								})
								-- Hide closing bracket
								vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, match.end_col - 1, {
									conceal = "",
									end_col = match.end_col,
								})
							elseif conceal.type == "markers" then
								-- Conceal start markers
								vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, match.start_col, {
									conceal = "",
									end_col = match.start_col + conceal.chars,
								})
								-- Conceal end markers
								vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, match.end_col - conceal.chars, {
									conceal = "",
									end_col = match.end_col,
								})
							end
						end
					end
				end
			end
		end

		::continue::
	end
end

--------------------------------------------------------------------------
-- Setup functions -----------------------------------------------------
--------------------------------------------------------------------------
function M.setup()
	M.setup_autocmd()
	M.setup_highlights()
end

M.setup_highlights = setup_highlight_groups

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
