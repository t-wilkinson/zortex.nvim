-- Editing layer and calendar line edits. Runs late and restores the files it
-- changes, because other tests read the same fixture notes.
local T = require("helpers")
local fs = require("zortex.utils.filesystem")
local workspace = require("zortex.core.workspace")
local calendar = require("zortex.stores.calendar")

local cal_path = T.fixture("calendar.zortex")
local original = fs.read_lines(cal_path)

local function restore()
	fs.write_lines(cal_path, original)
	require("zortex.core.document").invalidate(cal_path)
end

T.test("workspace edits the file when no buffer is loaded", function()
	local path = T.fixture("scratch.zortex")
	fs.write_lines(path, { "@@Scratch", "", "a", "b" })
	workspace.set_line(path, 3, "A")
	workspace.insert_lines(path, 4, { "inserted" })
	workspace.delete_lines(path, 5)
	T.eq(fs.read_lines(path), { "@@Scratch", "", "A", "inserted" })
	os.remove(path)
end)

T.test("add_entry inserts a line under its date, styled like its siblings", function()
	local before = fs.read_lines(cal_path)
	local entry = calendar.add_entry("2026-10-09", "17:30 Dinner")
	local after = fs.read_lines(cal_path)
	T.ok(entry and entry.lnum == 8, "returned the new entry")
	T.eq(after[8], "17:30 Dinner") -- after the date's last entry (line 7)
	T.eq(#after, #before + 1)
	-- Everything else is untouched: header, other entries, blank lines
	for i = 1, 7 do
		T.eq(after[i], before[i])
	end
	for i = 8, #before do
		T.eq(after[i + 1], before[i])
	end
	T.eq(#calendar.get_entries_for_date("2026-10-09"), 4)
	restore()
end)

T.test("add_entry creates date headings in date order", function()
	calendar.add_entry("2026-10-08", "Pack")
	calendar.add_entry("2026-10-12", "09:00 Review")
	local lines = fs.read_lines(cal_path)
	T.eq(lines[1], "@@Calendar") -- header kept
	T.eq(lines[4], "**2026-10-08:**") -- new days get a bold label
	T.eq(lines[5], "- Pack") -- untimed entries need "- "
	T.eq(lines[6], "")
	T.eq(lines[7], "2026-10-09:")
	T.eq(lines[#lines - 1], "**2026-10-12:**")
	T.eq(lines[#lines], "09:00 Review")
	restore()
end)

T.test("update and delete edit exactly one line", function()
	local before = fs.read_lines(cal_path)
	T.ok(calendar.update_entry("2026-10-10", "09:00 [Flipping]", "09:30 [Flipping]"))
	local lines = fs.read_lines(cal_path)
	T.eq(lines[10], "09:30 [Flipping]")
	T.eq(#lines, #before)

	local entries = calendar.get_entries_for_date("2026-10-10")
	local target
	for _, e in ipairs(entries) do
		if e.raw_text == "09:30 [Flipping]" then
			target = e
		end
	end
	T.ok(calendar.delete_entry(target))
	lines = fs.read_lines(cal_path)
	T.eq(#lines, #before - 1)
	T.eq(lines[10], "10:00 [P/#1.4 - Zortex]")
	T.eq(lines[9], "2026-10-10:") -- heading stays
	restore()
end)

T.test("edits go to a loaded buffer (unsaved), and the store sees them", function()
	vim.cmd("edit! " .. vim.fn.fnameescape(cal_path))
	local bufnr = vim.api.nvim_get_current_buf()
	calendar.add_entry("2026-10-10", "11:00 Call")
	T.ok(vim.bo[bufnr].modified, "buffer modified")
	T.eq(fs.read_lines(cal_path), original) -- file untouched until :w
	local found = false
	for _, e in ipairs(calendar.get_entries_for_date("2026-10-10")) do
		found = found or e.raw_text == "11:00 Call"
	end
	T.ok(found, "store reloaded from the buffer")
	vim.cmd("bwipeout!")
	restore()
	calendar.load()
end)

T.test("loading the calendar never rewrites it", function()
	calendar.load()
	T.eq(fs.read_lines(cal_path), original)
end)
