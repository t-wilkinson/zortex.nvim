-- ui/picker/calendar.lua - Calendar entries, newest day first (the calendar
-- view's "/" key), the calendar feeds' events among them; the preview shows
-- the entry in its note.
local Picker = require("zortex.ui.picker")
local calendar_store = require("zortex.stores.calendar")
local fs = require("zortex.utils.filesystem")

local M = {}

function M.spec()
	local file = fs.get_calendar_file()
	return {
		title = "Calendar",
		items = function()
			local items = calendar_store.get_all_entries({ feeds = true })
			table.sort(items, function(a, b)
				if a.date ~= b.date then
					return a.date > b.date
				end
				return (a.entry.lnum or 0) < (b.entry.lnum or 0)
			end)
			return items
		end,
		text = function(item)
			return item.date .. " " .. vim.trim(item.entry.raw_text or "")
		end,
		format = function(item)
			local out = { { item.date .. "  ", "Comment" }, { vim.trim(item.entry.raw_text or "") } }
			if item.entry.feed then
				out[#out + 1] = { "  · " .. item.entry.feed, "Comment" }
			end
			return out
		end,
		location = function(item)
			return {
				file = item.entry.file or file,
				lnum = item.entry.lnum or 1,
				text = vim.trim(item.entry.raw_text or ""),
			}
		end,
		preview = function(item)
			local lines = fs.read_lines(item.entry.file or file)
			return lines and { lines = lines, lnum = item.entry.lnum, zortex = true, title = item.date } or nil
		end,
	}
end

function M.open()
	return Picker.pick(M.spec())
end

return M
