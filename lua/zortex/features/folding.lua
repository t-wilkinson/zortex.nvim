-- features/folding.lua - Folding logic for Zortex
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

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local raw_levels = {}
	local explicit_starters = {}
	local next_non_blank = {}

	-- Pass 1: Find next non-blank lines for lookahead
	local last_non_blank = nil
	for i = #lines, 1, -1 do
		local is_blank = lines[i]:match("^%s*$") ~= nil
		if not is_blank then
			next_non_blank[i] = last_non_blank
			last_non_blank = i
		else
			next_non_blank[i] = last_non_blank
		end
	end

	-- Pass 2: Calculate raw hierarchical levels for each line
	local base_level = 0
	local bold_level = 0
	local label_level = 0
	local indent_stack = { 0 }

	for i, line in ipairs(lines) do
		local is_blank = line:match("^%s*$") ~= nil

		if is_blank then
			raw_levels[i] = -1 -- Blank placeholder
		else
			local is_article = line:match("^@@")
			local is_heading = line:match("^(#+)%s+")
			local is_bold = line:match("^%s*%*%*[^%*]+%*%*:?%s*$")
			local is_label = line:match("^%s*(%w[^:]*):%s*$")

			local spaces = #line:match("^%s*")

			if is_article then
				base_level = 0
				bold_level = 0
				label_level = 0
				indent_stack = { spaces }
				raw_levels[i] = 0
				explicit_starters[i] = ">0"
			elseif is_heading then
				base_level = #line:match("^(#+)")
				bold_level = 0
				label_level = 0
				indent_stack = { spaces }
				raw_levels[i] = base_level
				explicit_starters[i] = ">" .. base_level
			elseif is_bold then
				bold_level = 1
				label_level = 0
				indent_stack = { spaces }
				raw_levels[i] = base_level + bold_level
				explicit_starters[i] = ">" .. raw_levels[i]
			elseif is_label then
				label_level = 1
				indent_stack = { spaces }
				raw_levels[i] = base_level + bold_level + label_level
				explicit_starters[i] = ">" .. raw_levels[i]
			else
				-- Indented text / Lists
				while #indent_stack > 1 and spaces < indent_stack[#indent_stack] do
					table.remove(indent_stack)
				end

				if spaces > indent_stack[#indent_stack] then
					table.insert(indent_stack, spaces)
				end

				local indent_level = #indent_stack - 1
				raw_levels[i] = base_level + bold_level + label_level + indent_level
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

	-- Force Neovim to recompute folds from the updated cache.
	-- Without this, Neovim reads stale values because it evaluates
	-- foldexpr *before* the TextChanged autocmd updates the table.
	-- for _, win in ipairs(vim.api.nvim_list_wins()) do
	-- 	if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
	-- 		vim.api.nvim_win_call(win, function()
	-- 			local saved = vim.fn.winsaveview()
	-- 			vim.cmd("normal! zx")
	-- 			vim.fn.winrestview(saved)
	-- 		end)
	-- 	end
	-- end
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
