-- features/size_hint.lua - What a @size is worth, beside it as you type
--
-- On the cursor line of a note, a @size(sm) (or a bare @sm) gets a hint at
-- the end of the line: "sm ≈ 30m · 5 XP", from your xp.sizes and
-- xp.xp_per_hour; a heading's size is a project's (an objective's in the
-- OKR note). Only the cursor line is looked at, so it costs one line's
-- parse per move. features.size_hint = { enabled = false } turns it off;
-- completion (features/completion) shows the same numbers for each size.
local M = {}

local NS = vim.api.nvim_create_namespace("zortex_size_hint")

local function calc()
	return require("zortex.services.xp.calculator")
end

--- What kind of thing a line's @size sizes: "task", "project", "objective".
function M.kind_of(line, path)
	local info = require("zortex.core.syntax").classify(line)
	if info.kind == "heading" or info.kind == "bold_heading" then
		local okr = require("zortex.utils.filesystem").get_okr_file()
		if okr and path and vim.fn.fnamemodify(path, ":p") == vim.fn.fnamemodify(okr, ":p") then
			return "objective"
		end
		return "project"
	end
	return "task"
end

--- The size on a line and its hint text: size, text (nil, nil without one).
function M.hint(line, path)
	local attributes = require("zortex.utils.attributes")
	-- @size(x) as written (any word, so a size of the wrong kind can be
	-- said), else a bare @sm; @p/@i for the multipliers
	local attrs = attributes.parse_attributes(line, attributes.schemas.project)
	local size = attributes.extract_attribute(line, "size")
	size = size and vim.trim(size):lower() or select(1, attributes.parse_attributes(line)).size
	if not size or size == "" then
		return nil
	end
	local kind = M.kind_of(line, path)
	local text = calc().size_hint(kind, size, attrs)
	if not text then
		local names = table.concat(calc().size_names(kind), " ")
		return size, string.format("%s: not a %s size (%s)", size, kind, names)
	end
	return size, string.format("%s ≈ %s", size, text)
end

function M.update(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	if not calc().enabled() then
		return
	end
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	if not line or not line:find("@", 1, true) then
		return
	end
	local _, text = M.hint(line, vim.api.nvim_buf_get_name(bufnr))
	if text then
		vim.api.nvim_buf_set_extmark(bufnr, NS, row, 0, {
			virt_text = { { "  " .. text, "Comment" } },
			virt_text_pos = "eol",
			hl_mode = "combine",
		})
	end
end

function M.setup(opts)
	opts = opts or {}
	local group = vim.api.nvim_create_augroup("ZortexSizeHint", { clear = true })
	if opts.enabled == false then
		return
	end
	local ext = require("zortex.config").extension or ".zortex"
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "BufEnter" }, {
		group = group,
		pattern = "*" .. ext,
		callback = function(ev)
			pcall(M.update, ev.buf)
		end,
		desc = "Zortex: what the @size on the cursor line is worth",
	})
	vim.api.nvim_create_autocmd({ "BufLeave", "InsertLeave" }, {
		group = group,
		pattern = "*" .. ext,
		callback = function(ev)
			if ev.event == "BufLeave" then
				pcall(vim.api.nvim_buf_clear_namespace, ev.buf, NS, 0, -1)
			end
		end,
	})
end

M._ns = NS

return M
