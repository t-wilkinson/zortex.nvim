-- ui/calendar/render.lua - Calendar view content: lines and highlights
--
-- Pure rendering for ui/calendar/view: month(date, state, cfg, width) and
-- digest(cfg, width) return the buffer lines, highlight ranges
-- ({ line, col, end_col, hl }, 1-based line, byte or display columns as
-- noted) and, for the month, where each day cell is.
local M = {}
local fn = vim.fn

local datetime = require("zortex.utils.datetime")
local calendar_store = require("zortex.stores.calendar")

local CELL_WIDTH = 7
local MARGIN_STR = "  "
local GRID_WIDTH = 7 * CELL_WIDTH -- 7 days * 7 cols = 49
local CONTENT_WIDTH = fn.strwidth(MARGIN_STR) + GRID_WIDTH -- 2 + 49 = 51

-- Center `text` in a window `win_width` wide (relative to the grid)
local function center(win_width, text)	local win_margin = win_width - CONTENT_WIDTH

	local content_padding = math.floor((CONTENT_WIDTH - fn.strwidth(text) + win_margin) / 2)
	local left_padding = string.rep(" ", math.max(1, content_padding))
	local line = left_padding .. text

	return {
		line = line,
		col = content_padding,
		end_col = 2 * content_padding + fn.strwidth(text),
	}
end

-- Icon for an entry: task (open/done), event, or a generic item
local function entry_icon(entry, cfg)
	if entry.type == "task" then
		return entry.completed and cfg.icons.task_done or cfg.icons.task
	elseif entry.type == "event" then
		return cfg.icons.event
	end
	return cfg.icons.has_items
end

-- Highlight the first time ("14:00-15:00" or "14:00") in a rendered line;
-- `offset` is the byte width of what precedes `text` on the line.
local function time_highlight(highlights, lnum, text, offset, cfg)
	local s, e = text:find("%d%d:%d%d%s*%-%s*%d%d:%d%d")
	if not s then
		s, e = text:find("%d%d:%d%d")
	end
	if s then
		table.insert(highlights, { line = lnum, col = offset + s - 1, end_col = offset + e, hl = cfg.colors.header })
	end
end

--- The month grid around `date`, then the selected day's entries.
---@return string[] lines, table[] highlights, table marks  marks[date_str] = { line, col, end_col, day } (display columns)
function M.month(date, state, cfg, win_width)
	local lines = {}
	local highlights = {}
	local today = datetime.get_current_date()

	table.insert(lines, "")

	-- Calculate centering
	local total_padding = win_width - CONTENT_WIDTH
	local left_pad_str = string.rep(" ", math.max(0, math.floor(total_padding / 2)))

	-- Header with navigation hints
	local header_text = datetime.format_month_year(date)
	local view_mode_text = state.view_mode == "month" and "Month View" or "Week View"
	local space_between = CONTENT_WIDTH - (fn.strwidth(header_text) + fn.strwidth(view_mode_text))
	local header_padding = string.rep(" ", math.max(1, space_between))
	local header_line = left_pad_str .. header_text .. header_padding .. view_mode_text

	table.insert(lines, header_line)
	table.insert(highlights, {
		line = 2,
		col = fn.strwidth(left_pad_str),
		end_col = fn.strwidth(header_line),
		hl = cfg.colors.header,
	})

	table.insert(lines, "")

	-- ── Navigation help (top) ────────────────────────────────────────────────
	local nav_hint = "←/→/↑/↓ move • H/L year • J/K • g today • q quit"
	local nav_center = center(win_width, nav_hint)

	table.insert(lines, nav_center.line)
	table.insert(highlights, {
		line = #lines,
		col = nav_center.col,
		end_col = nav_center.end_col,
		hl = cfg.colors.footer,
	})

	-- Separator
	table.insert(lines, "")
	table.insert(lines, string.rep("─", win_width))
	table.insert(lines, "")

	-- Day headers
	local day_header_parts = {}
	for _, name in ipairs({ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }) do
		table.insert(day_header_parts, "  " .. name .. "  ")
	end

	table.insert(lines, left_pad_str .. MARGIN_STR .. table.concat(day_header_parts, ""))
	table.insert(lines, "")

	-- Build calendar grid
	local days_in_month = datetime.get_days_in_month(date.year, date.month)
	local first_weekday = datetime.get_first_weekday(date.year, date.month)
	local current_day = 1
	local line_num = #lines + 1

	local marks = {}

	for week = 1, 6 do
		if current_day > days_in_month then
			break
		end

		local shift_hl = 0 -- bytes the icons so far take beyond their display width
		local week_line_parts = { left_pad_str, MARGIN_STR }

		for weekday = 1, 7 do
			local day_cell_str

			if (week == 1 and weekday >= first_weekday) or (week > 1 and current_day <= days_in_month) then
				local day_num = current_day
				local date_str = string.format("%04d-%02d-%02d", date.year, date.month, day_num)
				local entries = calendar_store.get_entries_for_date(date_str)
				local is_today = date.year == today.year and date.month == today.month and day_num == today.day
				local is_selected = state.current_date
					and date.year == state.current_date.year
					and date.month == state.current_date.month
					and day_num == state.current_date.day

				-- Determine icon
				local hl_group = nil
				local hl_group_icon = nil
				local day_icon = cfg.icons.none

				if #entries > 0 then
					day_icon = cfg.icons.has_items

					-- Prioritize icons
					local has_notification = false
					local has_incomplete_task = false
					local has_complete_task = false
					local has_event = false

					for _, entry in ipairs(entries) do
						if entry.attributes.notify then
							has_notification = true
						end
						if entry.type == "task" then
							if entry.completed then
								has_complete_task = true
							else
								has_incomplete_task = true
							end
						elseif entry.type == "event" then
							has_event = true
						end
					end

					-- Set icon by priority
					if has_notification then
						day_icon = cfg.icons.notification
					elseif has_event then
						day_icon = cfg.icons.event
					elseif has_incomplete_task then
						day_icon = cfg.icons.task
					elseif has_complete_task then
						day_icon = cfg.icons.task_done
					end
				end

				-- Selected days drop the padding (the selection extmark marks them)
				local day_num_str = is_selected and string.format("%02d", day_num) or string.format(" %2d ", day_num)
				local cell_content = day_icon .. day_num_str
				local content_w = fn.strwidth(cell_content)
				local padding_w = CELL_WIDTH - content_w
				local lpad = string.rep(" ", math.max(0, math.floor(padding_w / 2)))
				local rpad = string.rep(" ", math.max(0, math.ceil(padding_w / 2)))
				day_cell_str = lpad .. cell_content .. rpad

				-- Calculate position
				local base_col_0based = fn.strwidth(left_pad_str) + fn.strwidth(MARGIN_STR) + (weekday - 1) * CELL_WIDTH

				-- Add highlight for whole cell (but not for selected - we'll use extmark)
				if is_today and not is_selected then
					hl_group = cfg.colors.today
				elseif weekday == 1 or weekday == 7 then
					hl_group = cfg.colors.weekend
				end

				-- Highlight icon if entries exist
				-- Icons
				if #entries > 0 and not is_today then
					local icon_col_start = base_col_0based + fn.strwidth(lpad)
					table.insert(highlights, {
						line = line_num,
						col = icon_col_start + shift_hl,
						end_col = icon_col_start + #day_icon + shift_hl,
						hl = is_selected and cfg.colors.selected_icon or cfg.colors.has_entry,
					})
				end

				-- Highlights are in bytes, cells in display columns: an icon that
				-- takes more bytes than columns shifts everything after it
				shift_hl = shift_hl + (#day_icon - fn.strwidth(day_icon))

				-- Date highlights
				if hl_group then
					table.insert(highlights, {
						line = line_num,
						col = base_col_0based + shift_hl,
						end_col = base_col_0based + CELL_WIDTH + shift_hl,
						hl = hl_group,
					})
				end

				-- Store position for navigation and extmark
				marks[date_str] = {
					line = line_num,
					col = base_col_0based,
					day = day_num,
					end_col = base_col_0based + CELL_WIDTH,
				}

				current_day = current_day + 1
			else
				day_cell_str = string.rep(" ", CELL_WIDTH)
			end
			table.insert(week_line_parts, day_cell_str)
		end

		table.insert(lines, table.concat(week_line_parts, ""))
		line_num = line_num + 1
	end

	-- Add summary section
	table.insert(lines, "")
	table.insert(lines, left_pad_str .. MARGIN_STR .. string.rep("─", GRID_WIDTH))
	table.insert(lines, "")

	-- Show entries for selected date
	if state.current_date then
		local date_str = datetime.format_datetime(state.current_date, "YYYY-MM-DD")
		local entries = calendar_store.get_entries_for_date(date_str)

		local summary_header = string.format(
			"%s - %s",
			os.date("%A, %B %d, %Y", os.time(state.current_date)),
			#entries > 0 and string.format("%d items", #entries) or "No items"
		)

		table.insert(lines, left_pad_str .. MARGIN_STR .. summary_header)
		table.insert(highlights, {
			line = #lines,
			col = fn.strwidth(left_pad_str .. MARGIN_STR),
			end_col = fn.strwidth(left_pad_str .. MARGIN_STR .. summary_header),
			hl = cfg.colors.digest_header,
		})
		table.insert(lines, left_pad_str)

		if #entries > 0 then
			for _, entry in ipairs(entries) do
				-- notifying entries get a plain bullet here
				local icon = entry.attributes.notify and "•" or entry_icon(entry, cfg)

				-- Use the entry's format method to get the properly formatted string
				local formatted_entry = entry:format()
				local entry_line = string.format("  %s %s", icon, formatted_entry)
				table.insert(lines, left_pad_str .. MARGIN_STR .. entry_line)

				time_highlight(highlights, #lines, entry_line, #left_pad_str + #MARGIN_STR, cfg)
			end
		else
			table.insert(lines, left_pad_str .. MARGIN_STR .. "  (no entries)")
		end

		-- Minimum height of 10 lines
		while #lines < line_num + 10 do
			table.insert(lines, "")
		end
	end

	-- ── Footer key‑hints (bottom) ───────────────────────────────────────────
	-- Separator
	table.insert(lines, "")
	table.insert(lines, string.rep("─", win_width))
	table.insert(lines, "")

	local footer_text = "↵ open • a add‑event • d delete • r rename • ? help"
	local footer_center = center(win_width, footer_text)

	table.insert(lines, footer_center.line)
	table.insert(highlights, {
		line = #lines,
		col = footer_center.col,
		end_col = footer_center.end_col,
		hl = cfg.colors.key_hint,
	})

	return lines, highlights, marks
end

--- Today and the coming days (services/agenda), then high-priority projects.
---@return string[] lines, table[] highlights
function M.digest(cfg, win_width)
	local lines = {}
	local highlights = {}
	local today = datetime.get_current_date()

	-- Header
	table.insert(lines, "")
	local header = "📋 Today's Digest & Upcoming Week"
	local header_padding = math.max(0, math.floor((win_width - fn.strwidth(header)) / 2))
	table.insert(lines, string.rep(" ", header_padding) .. header)
	table.insert(highlights, {
		line = 2,
		col = header_padding,
		end_col = header_padding + fn.strwidth(header),
		hl = cfg.colors.header,
	})
	table.insert(lines, string.rep("─", win_width))
	table.insert(lines, "")

	-- Today and the next days (services/agenda: calendar entries plus project
	-- tasks/projects due that day)
	local days = require("zortex.services.agenda").upcoming(cfg.digest.show_upcoming_days + 1)
	local today_str = datetime.format_datetime(today, "YYYY-MM-DD")
	for _, day in ipairs(days) do
		local date = datetime.parse_date(day.date)
		local offset = datetime.days_between(datetime.parse_date(today_str), date)

		-- Date header
		local date_header = datetime.format_relative_date(date)
		if offset > 1 then
			date_header = date_header .. string.format(" (%s)", os.date("%b %d", os.time(date)))
		end
		table.insert(lines, string.format("  %s", date_header))
		table.insert(highlights, {
			line = #lines,
			col = 2,
			end_col = 2 + fn.strwidth(date_header),
			hl = cfg.colors.digest_header,
		})

		for _, item in ipairs(day.items) do
			local entry_line
			if item.entry then
				local entry = item.entry
				local icon = entry.attributes.notify and cfg.icons.notification or entry_icon(entry, cfg)
				entry_line = string.format("    %s %s", icon, entry:format())
			else
				-- Project task or project due today
				local icon = item.done and cfg.icons.task_done or cfg.icons.task
				local where = item.project and (" · " .. item.project:breadcrumb()) or ""
				local what = item.kind == "project_due" and ("Project due: " .. item.text) or (item.text .. " (due)")
				entry_line = string.format("    %s %s%s", icon, what, where)
			end
			table.insert(lines, entry_line)

			time_highlight(highlights, #lines, entry_line, 0, cfg)
		end
		table.insert(lines, "")
	end

	-- Show high priority projects
	if cfg.digest.show_high_priority then
		local high_priority = require("zortex.services.projects").query({
			sort = "priority",
			include_done = false,
			filter = function(p)
				return p.attributes.p == "1" or p.attributes.i == "1"
			end,
		})

		if #high_priority > 0 then
			table.insert(lines, string.rep("─", win_width))
			table.insert(lines, "")
			table.insert(lines, "  🎯 High Priority Projects")
			table.insert(highlights, {
				line = #lines,
				col = 2,
				end_col = 2 + fn.strwidth("🎯 High Priority Projects"),
				hl = cfg.colors.digest_header,
			})
			table.insert(lines, "")

			for _, project in ipairs(high_priority) do
				local priority_str = ""
				if project.attributes.p == "1" then
					priority_str = priority_str .. " [P1]"
				end
				if project.attributes.i == "1" then
					priority_str = priority_str .. " [I1]"
				end

				local project_line = string.format("    • %s%s", project.name, priority_str)
				table.insert(lines, project_line)
			end
		end
	end

	return lines, highlights
end

-- Byte offset (0-based) of display column `col` in `line`: the start of the
-- first character at or after that column, clamped to the line length.
function M.display_col_to_byte(line, col)
	local width, byte = 0, 0
	local nchars = fn.strchars(line)
	for i = 0, nchars - 1 do
		if width >= col then
			return byte
		end
		local ch = fn.strcharpart(line, i, 1)
		width = width + fn.strwidth(ch)
		byte = byte + #ch
	end
	return #line
end

return M
