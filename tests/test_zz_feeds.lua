local T = require("helpers")

-- Calendar feeds: `zortex serve -feeds` writes each feed's events into
-- z/feeds/<name>.zortex (app/feeds); the plugin shows them read-only.
local Config = require("zortex.config")
local calendar = require("zortex.stores.calendar")
local fs = require("zortex.utils.filesystem")

local DAY = "2026-12-01"
local dir = Config.notes_dir .. "z/feeds/"
local cozi = dir .. "cozi.zortex"

local function write_feed(path, lines)
	vim.fn.mkdir(dir, "p")
	fs.write_lines(path, lines)
end

local function with_feeds(setting, fn)
	Config.features = Config.features or {}
	local before = Config.features.calendar_feeds
	Config.features.calendar_feeds = setting
	local ok, err = pcall(fn)
	Config.features.calendar_feeds = before
	calendar.load()
	if not ok then
		error(err, 0)
	end
end

local function texts(entries)
	return vim.tbl_map(function(e)
		return (e:get_time_string() or "") .. " " .. e.text .. (e.feed and (" · " .. e.feed) or "")
	end, entries)
end

local cal_path = fs.get_calendar_file()
local cal_original = fs.read_lines(cal_path)

T.test("feeds: a feed's events join the day, read-only, by time", function()
	fs.write_lines(cal_path, vim.list_extend(vim.deepcopy(cal_original), {
		"",
		"**" .. DAY .. ":**",
		"09:00 Work",
		"17:00 Gym",
	}))
	write_feed(cozi, {
		"@@Cozi",
		"@CalendarFeed",
		"",
		'Written by zortex serve from the "cozi" feed; edits here are replaced.',
		"",
		"**" .. DAY .. ":**",
		"- Camping",
		"12:30 - 13:00 Dentist · Room 2 @n(no)",
		"14:00 - 15:00 Piano @free @n(no)",
	})
	-- a note in z/feeds without the marker isn't a feed
	write_feed(dir .. "stray.zortex", { "@@Stray", "", "**" .. DAY .. ":**", "10:00 Not a feed" })
	with_feeds({}, function()
		calendar.load()
		T.eq(calendar.feeds(), { "cozi" })
		T.eq(texts(calendar.get_day_entries(DAY)), {
			" Camping · cozi",
			"09:00 Work",
			"12:30 Dentist · Room 2 · cozi",
			"14:00 Piano · cozi",
			"17:00 Gym",
		})
		local dentist = calendar.get_day_entries(DAY)[3]
		T.eq(dentist.file, cozi)
		T.eq(dentist.attributes.notify, "no")
		local ui = Config.ui
		Config.ui = { calendar = { pretty_attributes = false } }
		local shown = dentist:format()
		Config.ui = ui
		T.ok(shown:find("· cozi$"), shown)
		T.eq(select(2, calendar.delete_entry(dentist)), "Calendar feed entries are read-only")
		-- the calendar's own entries only, when asked
		T.eq(#calendar.get_entries_for_date(DAY, { feeds = false }), 2)
		-- the picker lists them, at their note
		local all = calendar.get_all_entries({ feeds = true })
		local found
		for _, item in ipairs(all) do
			if item.entry.feed then
				found = item
			end
		end
		T.ok(found and found.entry.file == cozi)
		T.eq(#vim.tbl_filter(function(i)
			return i.entry.feed ~= nil
		end, calendar.get_all_entries()), 0)

		-- agenda items point at the feed's note, without a project
		local items = require("zortex.services.agenda").day(DAY)
		local feed_items = vim.tbl_filter(function(i)
			return i.feed == "cozi"
		end, items)
		T.eq(#feed_items, 3)
		for _, i in ipairs(feed_items) do
			T.eq(i.file, cozi)
			T.eq(i.project, nil)
		end
		-- busy: the dentist (30m), not the @free piano lesson
		local c = require("zortex.services.planner").capacity(DAY, { today = "2026-11-30" })
		-- and Work and Gym, 30m each (no end: capacity.event_minutes)
		T.eq(c.busy, 30 + 30 + 30, vim.inspect(c))
	end)
end)

T.test("feeds: a feed note changing on disk is picked up", function()
	with_feeds({}, function()
		calendar.load()
		write_feed(cozi, { "@@Cozi", "@CalendarFeed", "", "**" .. DAY .. ":**", "08:00 - 08:30 School run @n(no)" })
		-- a newer mtime than the first write
		vim.uv.fs_utime(cozi, os.time() + 5, os.time() + 5)
		T.eq(vim.tbl_filter(function(t)
			return t:find("cozi")
		end, texts(calendar.get_day_entries(DAY))), { "08:00 School run · cozi" })
	end)
end)

T.test("feeds: toggled off per feed, or all of them", function()
	write_feed(dir .. "school.zortex", { "@@School", "@CalendarFeed", "", "**" .. DAY .. ":**", "- Half day" })
	with_feeds({ cozi = false }, function()
		calendar.load()
		T.eq(calendar.feeds(), { "school" })
	end)
	with_feeds(false, function()
		calendar.load()
		T.eq(calendar.feeds(), {})
		T.eq(texts(calendar.get_day_entries(DAY)), { "09:00 Work", "17:00 Gym" })
	end)
	with_feeds(nil, function()
		calendar.load()
		T.eq(calendar.feeds(), { "cozi", "school" })
	end)
end)

T.test("feeds: the planner lists the day's feed events", function()
	with_feeds({}, function()
		calendar.load()
		local planner = require("zortex.services.planner")
		local c = planner.candidates({ today = DAY })
		T.eq(#c.feed_today, 2)
		local lines = require("zortex.ui.planner").render(c, DAY)
		local at
		for i, l in ipairs(lines) do
			if l == "# From your calendar feeds (2)" then
				at = i
			end
		end
		T.ok(at, vim.inspect(lines))
		T.eq(lines[at + 1], "08:00–08:30 School run  · cozi")
	end)
	vim.fn.delete(dir, "rf")
	fs.write_lines(cal_path, cal_original)
	calendar.load()
end)
