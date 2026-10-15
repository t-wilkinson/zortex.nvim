-- features/folding.lua - Fold levels from the document syntax
local M = {}

-- Define a global function for Neovim's foldexpr to call
_G._zortex_foldexpr = function(lnum)
	local bufnr = vim.api.nvim_get_current_buf()
	local folds = vim.b[bufnr].zortex_folds
	if folds and folds[lnum] then
		return folds[lnum]
	end
	return "0"
end

local function get_folding_config()
	local ok, config = pcall(require, "zortex.config")
	if ok and config and type(config) == "table" and config.features and config.features.folding then
		return config.features.folding
	end
	return {}
end

function M.update_folds(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local config = get_folding_config()
	local include_empty = config.include_empty_lines
	if include_empty == nil then
		include_empty = config.fold_empty_lines -- Fallback alias
	end

	local doc = require("zortex.core.document").from_buffer(bufnr)
	local lines = doc.lines

	local raw_levels = {}
	local explicit_starters = {}
	local next_non_blank = {}

	-- Pass 1: Find next non-blank lines for lookahead
	local last_non_blank = nil
	for i = #lines, 1, -1 do
		next_non_blank[i] = last_non_blank
		if lines[i]:match("%S") then
			last_non_blank = i
		end
	end

	-- Pass 2: Hierarchical level of each line, from the document syntax.
	-- Sections start explicit folds (article 0, heading n, bold heading below
	-- the heading, label below that); other lines nest by indentation.
	local base_level = 0
	local bold_level = 0
	local label_level = 0
	local indent_stack = { 0 }

	for i, line in ipairs(lines) do
		local d = doc:info(i)
		if d.kind == "blank" then
			raw_levels[i] = -1 -- Blank placeholder
		else
			local spaces = d.indent or #line:match("^%s*")
			if d.kind == "article" and d.section then
				base_level, bold_level, label_level = 0, 0, 0
				indent_stack = { spaces }
				raw_levels[i] = 0
				explicit_starters[i] = ">0"
			elseif d.kind == "heading" then
				base_level, bold_level, label_level = d.heading, 0, 0
				indent_stack = { spaces }
				raw_levels[i] = base_level
				explicit_starters[i] = ">" .. base_level
			elseif d.kind == "bold_heading" then
				bold_level, label_level = 1, 0
				indent_stack = { spaces }
				raw_levels[i] = base_level + bold_level
				explicit_starters[i] = ">" .. raw_levels[i]
			elseif d.kind == "label" and not d.item then
				label_level = 1
				indent_stack = { spaces }
				raw_levels[i] = base_level + bold_level + label_level
				explicit_starters[i] = ">" .. raw_levels[i]
			else
				-- Indented text / lists
				while #indent_stack > 1 and spaces < indent_stack[#indent_stack] do
					table.remove(indent_stack)
				end
				if spaces > indent_stack[#indent_stack] then
					table.insert(indent_stack, spaces)
				end
				raw_levels[i] = base_level + bold_level + label_level + (#indent_stack - 1)
			end
		end
	end

	-- Pass 3: Resolve final fold expressions
	local levels = {}
	local active_level = 0

	for i = 1, #lines do
		local is_blank = lines[i]:match("^%s*$") ~= nil

		if is_blank then
			if include_empty then
				levels[i] = tostring(active_level)
			else
				levels[i] = "-1"
			end
		else
			-- If this line is an explicit block (Heading/Label), respect its explicit fold start
			if explicit_starters[i] then
				levels[i] = explicit_starters[i]
				active_level = tonumber(levels[i]:sub(2)) or 0
			else
				local this_level = raw_levels[i]
				local next_i = next_non_blank[i]
				local next_level = next_i and raw_levels[next_i] or 0

				-- IMPLICIT STARTER LOGIC:
				-- If the *next* line is indented deeper, AND the next line is NOT
				-- an explicit block (like a Heading resetting things), make THIS line
				-- the start of the deeper fold. This makes "- List" fold its "- Sub" children.
				if next_level > this_level and not explicit_starters[next_i] then
					levels[i] = ">" .. next_level
					active_level = next_level
				else
					levels[i] = tostring(this_level)
					active_level = this_level
				end
			end
		end
	end

	-- Cache the calculated fold expressions to the buffer
	vim.b[bufnr].zortex_folds = levels
end

function M.setup()
	local group = vim.api.nvim_create_augroup("ZortexFolding", { clear = true })

	-- Recalculate folds only when text has settled (avoids insert mode jitter/lag)
	vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWritePost", "TextChanged", "TextChangedI", "InsertLeave" }, {
		group = group,
		pattern = "*.zortex",
		callback = function(args)
			M.update_folds(args.buf)
		end,
	})

	-- Initialize folding behaviors
	vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType" }, {
		group = group,
		pattern = "*.zortex",
		callback = function(args)
			-- Ensure folds are generated on first load
			M.update_folds(args.buf)

			vim.wo.foldmethod = "expr"
			vim.wo.foldexpr = "v:lua._zortex_foldexpr(v:lnum)"

			-- Attempt to use existing fold text from your highlights module
			local has_highlights, highlights = pcall(require, "zortex.features.highlights")
			if has_highlights and highlights.zortex_fold_text then
				vim.wo.foldtext = "v:lua.require('zortex.features.highlights').zortex_fold_text()"
			end
		end,
	})
end

return M
