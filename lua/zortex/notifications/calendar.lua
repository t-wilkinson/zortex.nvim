-- notifications/calendar.lua - The calendar's notifications, sent to the server
--
-- Every timed line of the calendar notifies at its time (@notify(15) adds
-- one 15 minutes before; @notify(no) turns it off). All-day lines (a date
-- range, or an untimed line with @notify) notify on their first day at
-- notifications.all_day_time (09:00); @notify(07:30) notifies at that time
-- of the entry's day instead. collect() lists them
-- for the next `days`, and sync() hands them to `zortex serve`, which sends
-- them through ntfy when they are due (and Neovim shows them as they fire:
-- notifications/init.lua). Nothing is sent when the set is the one the
-- server already has.
local M = {}

local datetime = require("zortex.utils.datetime")
local calendar_store = require("zortex.stores.calendar")
local store = require("zortex.stores.notifications")
local Logger = require("zortex.core.logger")
local Config = require("zortex.config")

local cfg = {}

-- When to notify, from @notify(…): minutes before the entry
-- (@notify(10, 1h) -> { 10, 60 }), clock times on its day (@notify(07:30)),
-- and "end" (@notify(0, 30, end): also when a time range ends; without it
-- only the start notifies). @notify(no) -> nil. Returns minutes (only the
-- ones written), at_end, clocks.
local function parse_notify_value(notify_attr)
	if notify_attr == nil or notify_attr == "no" or notify_attr == false then
		return nil
	end
	local out, at_end, clocks = {}, false, {}
	local values = type(notify_attr) == "table" and notify_attr or { notify_attr }
	for _, v in ipairs(values) do
		local text = type(v) == "string" and vim.trim(v):lower() or nil
		local h, m = (text or ""):match("^(%d%d?):(%d%d)$")
		if text == "end" then
			at_end = true
		elseif h and tonumber(h) < 24 and tonumber(m) < 60 then
			clocks[#clocks + 1] = { hour = tonumber(h), min = tonumber(m) }
		elseif tonumber(v) then
			out[#out + 1] = tonumber(v)
		end
	end
	return out, at_end, clocks
end

-- "09:00" (notifications.all_day_time) -> { hour, min }, or nil (false: all-day
-- entries don't notify)
local function all_day_clock()
	local v = cfg.all_day_time
	if v == nil then
		v = "09:00"
	end
	local h, m = tostring(v):match("^(%d%d?):(%d%d)$")
	if v == false or not h then
		return nil
	end
	return { hour = tonumber(h), min = tonumber(m) }
end

-- Create a deduplication key for a calendar notification
local function create_dedup_key(entry, date_str, event_type, advance_minutes)
	-- Include all relevant parts to make it unique
	local text_part = entry.text:sub(1, 20):gsub("%s+", "_"):gsub("[^%w_-]", "")
	return string.format(
		"cal_%s_%s_%s_%d",
		date_str,
		text_part,
		event_type, -- "start", "end", "allday" or "at" (a clock time)
		advance_minutes
	)
end

-- Title and message of a calendar notification: the entry's text as it
-- reads, and when.
local function format_notification(entry, event_type, minutes_until, at, day)
	-- an all-day entry, or a clock time from @notify(07:30): the day it is on
	if event_type == "allday" or event_type == "at" then
		local today = os.date("%Y-%m-%d", at)
		local message
		if day == today then
			message = "today"
		elseif day == os.date("%Y-%m-%d", at + 86400) then
			message = "tomorrow"
		else
			local y, mo, d = day:match("^(%d+)%-(%d+)%-(%d+)$")
			message = os.date("%a %b %d", os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 }))
		end
		local start = event_type == "at" and entry:get_start_time()
		if start and start.hour then
			message = message .. string.format(" %02d:%02d", start.hour, start.min)
		end
		return require("zortex.core.link").readable(entry.text), message
	end
	local when
	if minutes_until <= 0 then
		when = "now"
	elseif minutes_until < 60 then
		when = string.format("in %d min", minutes_until)
	elseif minutes_until % 60 == 0 then
		when = string.format("in %d h", minutes_until / 60)
	else
		when = string.format("in %d h %d min", math.floor(minutes_until / 60), minutes_until % 60)
	end
	local clock = os.date("%H:%M", at)
	local message
	if event_type == "end" then
		message = string.format("ends %s (%s)", clock, when)
	else
		local end_time = entry:get_end_time()
		local range = end_time and (clock .. "–" .. os.date("%H:%M", os.time(end_time))) or clock
		message = minutes_until <= 0 and range or string.format("%s (%s)", range, when)
	end
	-- links read as their text: "[1.4 - zortex](P/#…)" or "[P/#1.4 - zortex]" -> "1.4 - zortex"
	return require("zortex.core.link").readable(entry.text), message
end

-- ===========================================================================
-- Manifest: what was last synced, so unchanged calendars aren't re-sent
-- ===========================================================================

local function signature(n)
	local tags = vim.deepcopy(n.tags or {})
	table.sort(tags)
	return table.concat({
		n.deduplication_key or "",
		n.title or "",
		n.message or "",
		tostring(n.trigger_time),
		n.priority or "",
		table.concat(tags, ","),
	}, "\31")
end

--- The notifications to schedule from the calendar (future ones only).
function M.collect(now)
	calendar_store.load()
	now = now or os.time()
	local today = datetime.get_current_date()
	local out = {}

	local function add(entry, notify_values, date_str, at_table, event_type)
		local at = os.time(at_table)
		for _, advance_minutes in ipairs(notify_values) do
			-- whole days before keep the clock time (@notify(1d) at 08:15 is
			-- 08:15 the day before, across a daylight saving change too);
			-- the minutes left over are minutes
			local days = math.floor(advance_minutes / 1440)
			local t = vim.deepcopy(at_table)
			t.day, t.isdst = t.day - days, nil
			local trigger_time = os.time(t) - (advance_minutes - days * 1440) * 60
			if trigger_time > now then
				local title, message = format_notification(entry, event_type, advance_minutes, trigger_time, date_str)
				if event_type ~= "allday" and event_type ~= "at" then
					title, message = format_notification(entry, event_type, advance_minutes, at)
				end
				out[#out + 1] = {
					title = title,
					message = message,
					trigger_time = trigger_time,
					scheduled_time = trigger_time,
					type = "calendar",
					priority = entry.attributes.p and ("p" .. entry.attributes.p) or "default",
					tags = { "calendar", event_type },
					entry_id = entry.text,
					entry_text = entry.text,
					deduplication_key = create_dedup_key(entry, date_str, event_type == "at" and ("at" .. os.date("%H%M", at)) or event_type, advance_minutes),
				}
			end
		end
	end

	for day_offset = 0, cfg.days or 30 do
		local date_str = datetime.format_datetime(datetime.add_days(today, day_offset), "YYYY-MM-DD")
		local y, m, d = date_str:match("^(%d+)%-(%d+)%-(%d+)$")
		local function on_day(clock)
			return { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = clock.hour, min = clock.min }
		end
		-- a break hands its block back: "Back to Study" when it ends (instead
		-- of the break's own end)
		local resumed = {}
		for _, r in ipairs(calendar_store.resumes(date_str)) do
			local block_notify = parse_notify_value(r.block.attributes.notify)
			if block_notify then
				resumed[r.after] = true
				local h, mi = r.from:match("^(%d+):(%d+)$")
				local at = on_day({ hour = tonumber(h), min = tonumber(mi) })
				local trigger = os.time(at)
				if trigger > now then
					local text = require("zortex.core.link").readable(r.block.text)
					out[#out + 1] = {
						title = "Back to " .. text,
						message = r.to and (r.from .. "–" .. r.to) or r.from,
						trigger_time = trigger,
						scheduled_time = trigger,
						type = "calendar",
						priority = r.block.attributes.p and ("p" .. r.block.attributes.p) or "default",
						tags = { "calendar", "resume" },
						entry_id = r.block.text,
						entry_text = r.block.text,
						deduplication_key = create_dedup_key(r.block, date_str, "resume" .. r.from:gsub(":", ""), 0),
					}
				end
			end
		end
		for _, entry in ipairs(calendar_store.get_entries_for_date(date_str)) do
			local notify_values, at_end, clocks = parse_notify_value(entry.attributes.notify)
			if resumed[entry] then
				at_end = false
			end
			-- a task done (or carried to another day, [>]) has nothing to remind you of
			if entry.completed or entry.mark == ">" then
				notify_values = nil
			end
			local start_time = entry:get_start_time()
			local timed = start_time and start_time.hour ~= nil
			-- clock times from @notify(07:30): on the entry's day (a range's
			-- first day)
			local first_day = (start_time and not timed) and datetime.format_datetime(start_time, "YYYY-MM-DD") or date_str
			if notify_values and first_day == date_str then
				for _, clock in ipairs(clocks or {}) do
					add(entry, { 0 }, date_str, on_day(clock), "at")
				end
			end
			if notify_values and not timed then
				-- all day (a date range, or an untimed line with @notify): at
				-- notifications.all_day_time on its first day (the minutes of
				-- @notify(1d) before that), unless @notify gave clock times
				local clock = all_day_clock()
				if clock and #clocks == 0 and first_day == date_str then
					add(entry, #notify_values > 0 and notify_values or { 0 }, date_str, on_day(clock), "allday")
				end
				notify_values = nil
			elseif notify_values and #notify_values == 0 then
				-- a timed line: at its time, or advance_minutes before, unless
				-- @notify gave only clock times
				notify_values = #clocks == 0 and { tonumber(cfg.advance_minutes) or 0 } or nil
			end
			if notify_values then
				local end_time = entry:get_end_time()
				if start_time then
					add(entry, notify_values, date_str, start_time, "start")
				end
				-- the end: when asked for (@n(…, end)), at the time it ends;
				-- an entry with only an end time notifies there as usual
				if end_time and not start_time then
					add(entry, notify_values, date_str, end_time, "end")
				elseif end_time and at_end and os.time(end_time) ~= os.time(start_time) then
					add(entry, { 0 }, date_str, end_time, "end")
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if a.trigger_time ~= b.trigger_time then
			return a.trigger_time < b.trigger_time
		end
		return a.deduplication_key < b.deduplication_key
	end)
	return out
end

--- Has anything changed since the last successful sync to `target`?
--- Compares the new set with the last one minus what has fired since.
function M.changed(notifications, target, now)
	now = now or os.time()
	local last = store.get_calendar_manifest()
	if not last or last.target ~= target then
		return true
	end
	local before = {}
	for _, item in ipairs(last.items or {}) do
		if item.t > now then
			before[item.s] = true
		end
	end
	local count = 0
	for _, n in ipairs(notifications) do
		if not before[signature(n)] then
			return true
		end
		count = count + 1
	end
	return count ~= vim.tbl_count(before)
end

local function remember(notifications, target)
	local items = {}
	for _, n in ipairs(notifications) do
		items[#items + 1] = { t = n.trigger_time, s = signature(n) }
	end
	store.save_calendar_manifest({ target = target, items = items, synced_at = os.time() })
end

local function report(opts, msg)
	if opts.on_done then
		opts.on_done(msg)
	elseif not opts.silent then
		vim.notify(msg, vim.log.levels.INFO, { title = "Zortex calendar" })
	end
end

--- Send the calendar's notifications to the server (Config.server).
--- Nothing is sent, and nobody is notified, when they are the same as the
--- last successful sync.
---@param opts { force?: boolean, silent?: boolean, on_done?: fun(msg: string) }?
---@return integer count, boolean changed
function M.sync(opts)
	opts = opts or {}
	local server = require("zortex.notifications.server")
	if not server.enabled() then
		report(opts, "Calendar notifications need `zortex serve` (Config.server)")
		return 0, false
	end
	local notifications = M.collect()
	if not opts.force and not M.changed(notifications, "server") then
		Logger.debug("calendar", "sync skipped: unchanged", { count = #notifications })
		report(opts, string.format("Calendar unchanged (%d notifications)", #notifications))
		return #notifications, false
	end
	server.send_calendar(notifications, function(ok, res, err)
		if ok then
			remember(notifications, "server")
			local r = res or {}
			report(opts, string.format("Calendar synced: %d notifications (%d added, %d updated, %d removed)", #notifications, r.added or 0, r.updated or 0, r.removed or 0))
		else
			Logger.error("calendar", "Failed to sync to server: " .. tostring(err))
			report(opts, "Server unreachable: " .. tostring(err))
		end
	end)
	return #notifications, true
end

-- The options setup() was given (for tests)
function M._cfg()
	return cfg
end

function M.setup(opts)
	cfg = opts or {}
	if not require("zortex.notifications.server").enabled() then
		return
	end

	-- Initial sync (skipped when nothing changed since the last one)
	vim.defer_fn(function()
		M.sync({ silent = true })
	end, 100)
end

return M
