-- notifications/types/calendar.lua - Calendar sync using unified scheduler
local M = {}

local manager = require("zortex.notifications.manager")
local datetime = require("zortex.utils.datetime")
local calendar_store = require("zortex.stores.calendar")
local store = require("zortex.stores.notifications")
local Logger = require("zortex.core.logger")
local Config = require("zortex.config")

local cfg = {}

-- Minutes before the entry to notify: @notify(10, 60) -> { 10, 60 };
-- @notify(no) -> nil; none -> the configured default (0: at the time).
-- "end" among the values (@n(0, 30, end)) also notifies when a time range
-- ends; without it only the start notifies. Returns minutes, at_end.
local function parse_notify_value(notify_attr)
	if notify_attr == "no" or notify_attr == false then
		return nil
	end
	local out, at_end = {}, false
	local values = type(notify_attr) == "table" and notify_attr or { notify_attr }
	for _, v in ipairs(values) do
		if type(v) == "string" and vim.trim(v):lower() == "end" then
			at_end = true
		elseif tonumber(v) then
			out[#out + 1] = tonumber(v)
		end
	end
	if #out == 0 then
		out[1] = tonumber(cfg.default_advance_minutes) or 0
	end
	return out, at_end
end

-- Create a deduplication key for a calendar notification
local function create_dedup_key(entry, date_str, event_type, advance_minutes)
	-- Include all relevant parts to make it unique
	local text_part = entry.text:sub(1, 20):gsub("%s+", "_"):gsub("[^%w_-]", "")
	return string.format(
		"cal_%s_%s_%s_%d",
		date_str,
		text_part,
		event_type, -- "start" or "end"
		advance_minutes
	)
end

-- Title and message of a calendar notification: the entry's text, and when.
local function format_notification(entry, event_type, minutes_until, at)
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
	return entry.text, message
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
			local trigger_time = at - (advance_minutes * 60)
			if trigger_time > now then
				local title, message = format_notification(entry, event_type, advance_minutes, at)
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
					deduplication_key = create_dedup_key(entry, date_str, event_type, advance_minutes),
				}
			end
		end
	end

	for day_offset = 0, cfg.sync_days or 30 do
		local date_str = datetime.format_datetime(datetime.add_days(today, day_offset), "YYYY-MM-DD")
		for _, entry in ipairs(calendar_store.get_entries_for_date(date_str)) do
			local notify_values, at_end = parse_notify_value(entry.attributes.notify)
			if notify_values then
				local start_time, end_time = entry:get_start_time(), entry:get_end_time()
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

--- Sync calendar notifications to the server (Config.server) or, without
--- one, schedule them locally. Nothing is sent, and nobody is notified, when
--- the notifications are the same as the last successful sync.
---@param opts { force?: boolean, silent?: boolean, on_done?: fun(msg: string) }?
---@return integer count, boolean changed
function M.sync(opts)
	opts = opts or {}
	local notifications = M.collect()
	local server = require("zortex.notifications.server")
	local target = server.enabled() and "server" or "local"

	if not opts.force and not M.changed(notifications, target) then
		Logger.debug("calendar", "sync skipped: unchanged", { count = #notifications })
		if opts.on_done then
			opts.on_done(string.format("Calendar unchanged (%d notifications)", #notifications))
		end
		return #notifications, false
	end

	if target == "server" then
		require("zortex.notifications.providers.homelab").sync(notifications, nil, function(ok, res, err)
			if ok then
				remember(notifications, "server")
				local r = res or {}
				report(opts, string.format("Calendar synced: %d notifications (%d added, %d updated, %d removed)", #notifications, r.added or 0, r.updated or 0, r.removed or 0))
			else
				Logger.error("calendar", "Failed to sync to server: " .. tostring(err))
				M.sync_local(notifications)
				remember(notifications, "local")
				report(opts, "Server unreachable (" .. tostring(err) .. "); scheduled locally")
			end
		end)
	else
		M.sync_local(notifications)
		remember(notifications, "local")
		report(opts, string.format("Calendar: %d notifications scheduled", #notifications))
	end
	return #notifications, true
end

--- Schedule calendar notifications with the local manager, replacing the
--- calendar notifications it already holds (moved or removed entries).
function M.sync_local(notifications)
	local wanted = {}
	for _, n in ipairs(notifications) do
		wanted[n.deduplication_key] = n
	end
	for _, existing in ipairs(manager.list_scheduled({ type = "calendar" })) do
		local key = existing.options and existing.options.deduplication_key
		local n = key and wanted[key]
		if not n or n.trigger_time ~= existing.trigger_time or n.message ~= existing.message then
			manager.cancel_notification(existing.id)
		end
	end

	local scheduled_count = 0
	for _, notification in ipairs(notifications) do
		local id = manager.schedule_notification({
			title = notification.title,
			message = notification.message,
			trigger_time = notification.trigger_time,
			type = "calendar",
			options = {
				priority = notification.priority,
				deduplication_key = notification.deduplication_key,
				entry_text = notification.entry_text,
				tags = notification.tags,
			},
		})
		if id then
			scheduled_count = scheduled_count + 1
		end
	end
	return scheduled_count
end

-- Setup
function M.setup(opts)
	cfg = opts

	-- Initial sync (skipped when nothing changed since the last one)
	vim.defer_fn(function()
		M.sync({ silent = true })
	end, 100)
end

return M
