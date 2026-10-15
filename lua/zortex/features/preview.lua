-- features/preview.lua - Floating preview of a link's target
--
-- Shows the section a link resolves to (same rules as following it) in a
-- floating window next to the cursor, with Zortex highlighting. The matched
-- line is highlighted when the link points inside a section. A link ending in
-- ">" ([R/#Rust/>The Rust Book]) shows the lines of the links it matches with
-- the notes nested under them, and <CR> goes to that line.
--
--   <CR>      open the target (in the target window)
--   q / <Esc> close
-- The preview closes when the cursor moves; calling preview again while it is
-- open focuses it (like LSP hover).
--
-- Hover: with ui.preview.on_hover = true, resting the cursor on a link
-- (CursorHold, so 'updatetime' sets the delay) previews it without moving
-- focus. Only the link under the cursor counts, and errors stay quiet.
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
	state.win, state.buf, state.link = nil, nil, nil
end

-- The line of each link a ">" link matches, with the lines nested under it
-- (its notes), blocks separated by a blank line
local function follow_content(results)
	local link_mod = require("zortex.core.link")
	local lines = {}
	for i, r in ipairs(results) do
		if #lines >= MAX_LINES then
			break
		end
		-- two links on one line make one block
		local same_line = i > 1 and results[i - 1].lnum == r.lnum and results[i - 1].file == r.file
		if not same_line then
			if #lines > 0 then
				lines[#lines + 1] = ""
			end
			local doc = r.doc
			local indent = #(doc.lines[r.lnum]:match("^%s*"))
			local e = r.lnum
			for l = r.lnum + 1, #doc.lines do
				local line = doc.lines[l]
				if doc:node_starting_at(l) then
					break
				end
				if line:match("%S") then
					if #line:match("^%s*") <= indent then
						break
					end
					e = l
				end
			end
			vim.list_extend(lines, doc:get_lines(r.lnum, math.min(e, r.lnum + MAX_LINES - #lines - 1)))
		end
	end
	local first = results[1]
	local node = first.doc:node_at(first.lnum)
	local where = node:is_root() and vim.fn.fnamemodify(first.file, ":t") or node:get_breadcrumb(" › ")
	local title = #results == 1 and (where .. " › " .. link_mod.follow_text(first.text, first.target))
		or (where .. " · " .. #results .. " links")
	return {
		lines = lines,
		title = title,
		focus = 1,
		location = { file = first.file, lnum = first.lnum, col = first.col or 1 },
	}
end

-- What to show for a link: { lines, title, focus (1-based within lines), location }
local function target_content(link_info)
	local link_mod = require("zortex.core.link")

	if link_info.type == "link" or link_info.type == "live_link" then
		if link_mod.is_parent_relative(link_info.definition) then
			-- [./-Item] under the cursor: relative to its parent line's link
			local abs, err = link_mod.absolute(
				link_info.definition,
				vim.api.nvim_buf_get_lines(0, 0, -1, false),
				vim.api.nvim_win_get_cursor(0)[1]
			)
			if not abs then
				return nil, err
			end
			link_info = vim.tbl_extend("force", link_info, { definition = abs })
		end
		local parsed = link_mod.parse(link_info.definition)
		local last = parsed and parsed.components[#parsed.components]
		if last and last.type == "follow" then
			local results, err = link_mod.resolve(parsed)
			if #results == 0 then
				return nil, err or ("No match for " .. link_info.full_match_text)
			end
			return follow_content(results)
		end
		local node, result, err = link_mod.resolve_node(link_info.definition)
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

local HOVER_TYPES = { link = true, live_link = true, footnote = true }

--- Preview the link under the cursor (or the next one on the line).
---@param opts { hover?: boolean }?  hover: only the link under the cursor, never focus, no messages
function M.preview_link(opts)
	opts = opts or {}
	local link_info
	if opts.hover then
		local line = vim.api.nvim_get_current_line()
		link_info = require("zortex.core.link").at(line, vim.api.nvim_win_get_cursor(0)[2])
		if not (link_info and HOVER_TYPES[link_info.type]) then
			return nil
		end
		if is_open() then
			if state.link == link_info.full_match_text then
				return state.win -- already showing it
			end
			M.close()
		end
	elseif is_open() then
		vim.api.nvim_set_current_win(state.win)
		return
	end

	link_info = link_info or require("zortex.features.links").link_at_cursor()
	if not link_info then
		vim.notify("No link found on current line", vim.log.levels.INFO)
		return
	end
	local content, err = target_content(link_info)
	if not content then
		if not opts.hover then
			vim.notify(err, vim.log.levels.INFO)
		end
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
	state.win, state.buf, state.link = win, buf, link_info.full_match_text

	local function open_target()
		local location = content.location
		M.close()
		require("zortex.features.links").jump_to_location(location)
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
		callback = function(ev)
			local function check()
				if vim.api.nvim_get_current_win() ~= state.win then
					M.close()
				end
			end
			-- BufLeave fires before the switch: entering the preview itself
			-- leaves the origin buffer, so look once the switch is done
			if ev.event == "BufLeave" then
				vim.schedule(check)
			else
				check()
			end
		end,
	})
	return win
end

--- Preview links on hover when ui.preview.on_hover is set.
function M.setup(opts)
	opts = opts or {}
	local group = vim.api.nvim_create_augroup("ZortexLinkPreviewHover", { clear = true })
	if not opts.on_hover then
		return
	end
	vim.api.nvim_create_autocmd("CursorHold", {
		group = group,
		pattern = opts.pattern or "*.zortex",
		callback = function()
			if vim.fn.mode() == "n" and vim.api.nvim_get_current_win() ~= state.win then
				pcall(M.preview_link, { hover = true })
			end
		end,
	})
end

return M
