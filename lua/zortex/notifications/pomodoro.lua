-- notifications/pomodoro.lua - The pomodoro, driven from Neovim
--
-- The clock lives in `zortex serve` (Config.server): Neovim and the web
-- app's home page drive the same clock, it keeps running with Neovim
-- closed, and the server announces each phase change through ntfy (and to
-- Neovim, which shows it: notifications/init.lua).
--
-- A cycle is `long_break_after` work sessions, each followed by a short
-- break except the last (a long break). Settings live on the server:
-- :ZortexPomodoro settings work=50 short=10, or the home page.
--
--   local p = require("zortex.notifications.pomodoro")
--   p.toggle(); p.skip(); p.restart(); p.stop()
--   p.status()      -- { phase, running, remaining, session, today, settings, ... }
--   p.statusline()  -- "🍅 12:34" while active, "" otherwise
local M = {}

local server = require("zortex.notifications.server")

local PHASE = { IDLE = "idle", WORK = "work", SHORT_BREAK = "short_break", LONG_BREAK = "long_break" }
M.PHASE = PHASE

local NAMES = { idle = "Idle", work = "Work", short_break = "Short break", long_break = "Long break" }

local function fmt(sec)
	sec = math.max(0, math.floor(sec + 0.5))
	return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end
M.format_time = fmt

local function echo(msg)
	vim.api.nvim_echo({ { "🍅 " .. msg } }, false, {})
end

local NO_SERVER = "The pomodoro needs `zortex serve` (Config.server)"

-- =============================================================================
-- The server's clock
-- =============================================================================

local R = { state = nil, fetched = 0, ends_local = nil, poll = nil, failed_at = nil }

local function adopt(st)
	if type(st) ~= "table" or st.enabled == false or not st.phase then
		return
	end
	R.state, R.fetched = st, os.time()
	R.ends_local = st.running and (os.time() + (st.remaining or 0)) or nil
end

local function fetch(cb)
	server.request("GET", "/api/pomodoro", nil, function(ok, body, err)
		if ok then
			adopt(body)
		end
		if cb then
			cb(ok, body, err)
		end
	end, { timeout = 5 })
end
M.refresh = fetch

local function ensure_poll()
	if R.poll then
		return
	end
	R.poll = vim.uv.new_timer()
	R.poll:start(
		1000,
		1000,
		vim.schedule_wrap(function()
			local st = R.state
			if not st then
				return
			end
			-- refresh when the phase should have ended, and every 30s while active
			local due = st.running and R.ends_local and os.time() >= R.ends_local + 1
			if due or (st.phase ~= PHASE.IDLE and os.time() - R.fetched >= 30) then
				R.fetched = os.time() -- don't pile up requests
				fetch()
			end
		end)
	)
end

local function act(action, body)
	if not server.enabled() then
		vim.notify(NO_SERVER, vim.log.levels.WARN, { title = "Zortex" })
		return nil
	end
	server.request("POST", "/api/pomodoro/" .. action, body or vim.empty_dict(), function(ok, res, err)
		if res then
			adopt(res.state or res)
		end
		if not ok then
			vim.notify("Pomodoro: " .. tostring(err), vim.log.levels.WARN)
			return
		end
		ensure_poll()
		echo(M.describe(M.status()))
	end, { timeout = 8 })
	return true
end

-- =============================================================================
-- Public API
-- =============================================================================

function M.start()
	return act("start")
end
function M.toggle()
	return act("toggle")
end
function M.stop()
	return act("stop")
end
function M.skip()
	return act("skip")
end
function M.restart()
	return act("restart")
end

local SETTING_KEYS = {
	work = "work",
	short = "short_break",
	short_break = "short_break",
	long = "long_break",
	long_break = "long_break",
	every = "long_break_after",
	long_break_after = "long_break_after",
	auto_break = "auto_start_break",
	auto_start_break = "auto_start_break",
	auto_work = "auto_start_work",
	auto_start_work = "auto_start_work",
}

--- :ZortexPomodoro settings [work=50 short=10 long=20 every=4 auto_break=yes auto_work=no]:
--- change them, or show them without arguments.
function M.settings(fargs)
	local changes = {}
	for _, arg in ipairs(fargs or {}) do
		local k, v = arg:match("^([%w_]+)=(%S+)$")
		local key = k and SETTING_KEYS[k]
		if not key then
			vim.notify("Unknown setting: " .. arg, vim.log.levels.ERROR)
			return
		end
		if key:match("^auto") then
			changes[key] = v == "yes" or v == "true" or v == "1" or v == "on"
		else
			changes[key] = tonumber(v)
		end
	end
	if vim.tbl_isempty(changes) then
		local st = M.status()
		vim.notify(vim.inspect(st.settings or {}), vim.log.levels.INFO, { title = "Pomodoro settings" })
		return
	end
	return act("settings", changes)
end

--- The last state fetched from the server (refreshed in the background;
--- M.refresh(cb) waits for a fresh one): { phase, phase_name, running,
--- started, remaining, remaining_formatted, duration, session, completed,
--- today, settings, ends_at (epoch), is_active } or { error = true }.
function M.status()
	if not server.enabled() then
		return { phase = PHASE.IDLE, phase_name = "No server", remaining = 0, remaining_formatted = "--:--", error = true }
	end
	if not R.state and (not R.failed_at or os.time() - R.failed_at > 30) then
		-- first call: fetch synchronously (short timeout) so commands have an
		-- answer; after a failure, don't block again for 30 s (statuslines)
		local ok, body = server.request_sync("GET", "/api/pomodoro", nil, 2)
		if ok then
			adopt(body)
			ensure_poll()
			R.failed_at = nil
		else
			R.failed_at = os.time()
		end
	end
	if not R.state then
		return { phase = PHASE.IDLE, phase_name = "Unreachable", remaining = 0, remaining_formatted = "--:--", error = true }
	end
	local st = vim.deepcopy(R.state)
	st.ends_at = R.ends_local
	if st.running and R.ends_local then
		st.remaining = math.max(0, R.ends_local - os.time())
	end
	st.phase_name = NAMES[st.phase] or st.phase
	st.remaining_formatted = fmt(st.remaining or 0)
	st.is_active = st.running == true
	return st
end

--- One line: "Work 1/4 · 12:34 left · until 11:20"
function M.describe(st)
	st = st or M.status()
	if st.error then
		return server.enabled() and "Pomodoro server unreachable" or NO_SERVER
	end
	if st.phase == PHASE.IDLE then
		return string.format("Pomodoro idle · %d session(s) today", st.today or 0)
	end
	local n = st.settings and st.settings.long_break_after or 4
	local name = st.phase_name
	if st.phase == PHASE.WORK then
		name = string.format("Work %d/%d", st.session or 1, n)
	end
	if not st.started then
		return string.format("%s ready (%s) · start when you are", name, fmt(st.duration or 0))
	end
	if not st.running then
		return string.format("%s paused · %s left", name, st.remaining_formatted)
	end
	return string.format("%s · %s left · until %s", name, st.remaining_formatted, os.date("%H:%M", st.ends_at))
end

--- :ZortexPomodoro status: a fresh state, in a message.
function M.show_status()
	if not server.enabled() then
		return vim.notify(NO_SERVER, vim.log.levels.WARN, { title = "Zortex" })
	end
	fetch(function()
		vim.notify(M.describe(), vim.log.levels.INFO, { title = "Pomodoro" })
	end)
end

--- For statuslines: "🍅 12:34" while active, "" when idle.
function M.statusline()
	local ok, st = pcall(M.status)
	if not ok or st.error or st.phase == PHASE.IDLE then
		return ""
	end
	local icon = st.phase == PHASE.WORK and "🍅" or "☕"
	if not st.started then
		return icon .. " ready"
	end
	return icon .. " " .. st.remaining_formatted .. (st.running and "" or " ⏸")
end

function M.setup()
	if not server.enabled() then
		return
	end
	-- learn the server's state in the background
	vim.defer_fn(function()
		fetch(function(ok)
			if ok then
				ensure_poll()
			end
		end)
	end, 200)
end

function M.cleanup()
	if R.poll then
		R.poll:stop()
		R.poll:close()
		R.poll = nil
	end
	R.state = nil
end

return M
