-- features/preview.lua - Floating preview of a link's target
--
-- Shows the section a link resolves to (same rules as following it) in a
-- floating window next to the cursor, with Zortex highlighting. The matched
-- line is highlighted when the link points inside a section.
--
--   <CR>      open the target (in the target window)
--   q / <Esc> close
-- The preview closes when the cursor moves; calling preview again while it is
-- open focuses it (like LSP hover).
local M = {}

local MAX_LINES = 200
local state = { win = nil, buf = nil }

local function is_open()
	return state.win and vim.api.nvim_win_is_valid(state.win)
end

function M.close()
	if is_open() then
		vim.api.nvim_win_close(state.win, true)
	end
	state.win, state.buf = nil, nil
end

-- What to show for a link: { lines, title, focus (1-based within lines), location }
local function target_content(link_info)
	local link_resolver = require("zortex.utils.link_resolver")

	if link_info.type == "link" or link_info.type == "live_link" then
		local node, result, err = link_resolver.resolve_node(link_info.definition)
		if not node then
			return nil, err or ("No match for " .. link_info.full_match_text)
		end
		local doc = result.doc
		local s, e
		if node:is_root() or node.type == "article" then
			s = result.lnum
			e = math.min(#doc.lines, s + 40)
		else
			s, e = node.start_line, node.end_line
		end
		e = math.min(e, s + MAX_LINES - 1)
		while e > s and not (doc.lines[e] or ""):match("%S") do
			e = e - 1 -- drop trailing blank lines
		end
		local title = node:is_root() and vim.fn.fnamemodify(result.file, ":t") or node:get_breadcrumb(" › ")
		return {
			lines = doc:get_lines(s, e),
			title = title,
			focus = result.lnum - s + 1,
			location = { file = result.file, lnum = result.lnum, col = result.col or 1 },
		}
	elseif link_info.type == "footnote" then
		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		local pattern = "^%[%^" .. vim.pesc(link_info.ref_id) .. "%]:"
		for lnum, line in ipairs(lines) do
			if line:match(pattern) then
				local out = { line }
				for i = lnum + 1, math.min(#lines, lnum + 20) do
					if not lines[i]:match("%S") then
						break
					end
					out[#out + 1] = lines[i]
				end
				return {
					lines = out,
					title = "[^" .. link_info.ref_id .. "]",
					focus = 1,
					location = { file = vim.api.nvim_buf_get_name(0), lnum = lnum, col = 1 },
				}
			end
		end
		return nil, "Footnote [^" .. link_info.ref_id .. "] not found"
	end
	return nil, "Nothing to preview for this link"
end

--- Preview the link under the cursor (or the next one on the line).
function M.preview_link()
	if is_open() then
		vim.api.nvim_set_current_win(state.win)
		return
	end

	local link_info = require("zortex.features.links").link_at_cursor()
	if not link_info then
		vim.notify("No link found on current line", vim.log.levels.INFO)
		return
	end
	local content, err = target_content(link_info)
	if not content then
		vim.notify(err, vim.log.levels.INFO)
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	pcall(function()
		require("zortex.features.highlights").highlight_buffer(buf)
	end)
	local ns = vim.api.nvim_create_namespace("zortex_link_preview")
	if content.focus and content.focus > 1 then
		vim.api.nvim_buf_set_extmark(buf, ns, content.focus - 1, 0, { line_hl_group = "CursorLine" })
	end

	local width = 0
	for _, l in ipairs(content.lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	width = math.max(math.min(width + 2, math.floor(vim.o.columns * 0.8), 100), math.min(#content.title + 4, 60), 20)
	local height = math.max(1, math.min(#content.lines, math.floor(vim.o.lines * 0.5), 25))

	local win_opts = {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. content.title .. " ",
		title_pos = "left",
		footer = " <CR> open · q close ",
		footer_pos = "right",
	}
	local ok, win = pcall(vim.api.nvim_open_win, buf, false, win_opts)
	if not ok then -- older Neovim without footer support
		win_opts.footer, win_opts.footer_pos = nil, nil
		win = vim.api.nvim_open_win(buf, false, win_opts)
	end
	vim.wo[win].wrap = false
	vim.wo[win].conceallevel = 2
	if content.focus then
		pcall(vim.api.nvim_win_set_cursor, win, { content.focus, 0 })
	end
	state.win, state.buf = win, buf

	local function open_target()
		local location = content.location
		M.close()
		require("zortex.features.links").jump_to_location(location, true)
	end
	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, M.close, { buffer = buf, nowait = true, silent = true })
	end
	vim.keymap.set("n", "<CR>", open_target, { buffer = buf, nowait = true, silent = true })

	-- Close when the cursor leaves the link (only while not inside the preview)
	local origin = vim.api.nvim_get_current_buf()
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave", "InsertEnter" }, {
		buffer = origin,
		once = true,
		callback = function()
			if vim.api.nvim_get_current_win() ~= state.win then
				M.close()
			end
		end,
	})
	return win
end

-- Test hook
function M._state()
	return state
end

return M
