-- notifications/types/pomodoro.lua - Pomodoro clock
--
-- With Config.server enabled the clock lives in `zortex serve`: Neovim and
-- the server's home page drive the same clock, it keeps running with Neovim
-- closed, and the server announces phase changes through ntfy. Without a
-- server the same clock runs here.
--
-- A cycle is `long_break_after` work sessions, each followed by a short
-- break except the last (a long break). Events, each with its own ntfy tag
-- and sound (contrib/ntfy/notify.sh plays them):
--
--   work_start   a work session began            tag pomodoro-work-start
--   break_start  a short or long break began     tag pomodoro-break-start
--   restart      a new cycle began               tag pomodoro-restart
--   work_end     work done, break waits for you  tag pomodoro-work-end
--   break_end    break over, work waits for you  tag pomodoro-break-end
--   stop         stopped by hand                 tag pomodoro-stop
--
-- When ntfy is enabled pomodoro alerts go only through ntfy
-- (types.pomodoro.ntfy_only); otherwise through the pomodoro channels, with
-- types.pomodoro.sounds played locally.
local M = {}

local manager = require("zortex.notifications.manager")
local store = require("zortex.stores.notifications")
local server = require("zortex.notifications.server")

local cfg = {}
local providers_cfg = {}

local PHASE = { IDLE = "idle", WORK = "work", SHORT_BREAK = "short_break", LONG_BREAK = "long_break" }
M.PHASE = PHASE

local NAMES = { idle = "Idle", work = "Work", short_break = "Short break", long_break = "Long break" }

local EVENT_TAGS = {
	work_start = { "tomato", "pomodoro", "pomodoro-work-start" },
	break_start = { "coffee", "pomodoro", "pomodoro-break-start" },
	restart = { "arrows_counterclockwise", "pomodoro", "pomodoro-restart" },
	work_end = { "white_check_mark", "pomodoro", "pomodoro-work-end" },
	break_end = { "bell", "pomodoro", "pomodoro-break-end" },
	stop = { "stop_sign", "pomodoro", "pomodoro-stop" },
}

-- Freedesktop sounds used when types.pomodoro.sounds doesn't name one
local DEFAULT_SOUNDS = {
	work_start = "/usr/share/sounds/freedesktop/stereo/bell.oga",
	break_start = "/usr/share/sounds/freedesktop/stereo/complete.oga",
	restart = "/usr/share/sounds/freedesktop/stereo/service-login.oga",
	work_end = "/usr/share/sounds/freedesktop/stereo/message.oga",
	break_end = "/usr/share/sounds/freedesktop/stereo/message.oga",
}

local function settings_from_cfg()
	return {
		work = cfg.work_duration or 25,
		short_break = cfg.short_break or 5,
		long_break = cfg.long_break or 15,
		long_break_after = cfg.long_break_after or 4,
		auto_start_break = cfg.auto_start_break ~= false,
		auto_start_work = cfg.auto_start_work == true,
	}
end

local function remote()
	return server.enabled() and cfg.use_server ~= false
end
M.remote = remote

local function fmt(sec)
	sec = math.max(0, math.floor(sec + 0.5))
	return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end
M.format_time = fmt

local function echo(msg)
	vim.api.nvim_echo({ { "🍅 " .. msg } }, false, {})
end

-- =============================================================================
-- Alerts (local clock, or a server without ntfy)
-- =============================================================================

local function ntfy_enabled()
	local p = providers_cfg.ntfy
	return p and p.enabled and p.topic and p.topic ~= ""
end

local function play(event)
	local sounds = cfg.sounds or {}
	local file = sounds[event]
	if file == false then
		return
	end
	file = file and vim.fn.expand(file) or DEFAULT_SOUNDS[event]
	if not file or vim.fn.filereadable(file) == 0 then
		return
	end
	local player = cfg.sound_command or (vim.fn.has("mac") == 1 and "afplay" or "paplay")
	if vim.fn.executable(player) == 1 then
		vim.fn.jobstart({ player, file }, { detach = true })
	end
end

local function event_text(event, st)
	local s = st.settings
	local ends = st.running and (" · until " .. os.date("%H:%M", st.ends_at)) or ""
	local session = string.format("session %d/%d", math.max(st.session or 1, 1), s.long_break_after)
	if event == "work_start" then
		return string.format("Work · %d min", s.work), "Focus: " .. session .. ends
	elseif event == "restart" then
		return string.format("New cycle · work %d min", s.work), "Starting " .. session .. ends
	elseif event == "break_start" then
		return string.format("%s · %d min", NAMES[st.phase], math.floor(st.duration / 60)), "Step away" .. ends
	elseif event == "work_end" then
		return "Work session done", string.format("%s (%d min) is ready when you are", NAMES[st.phase], math.floor(st.duration / 60))
	elseif event == "break_end" then
		return "Break over", string.format("Work session %d/%d is ready when you are", st.completed + 1, s.long_break_after)
	elseif event == "stop" then
		return "Pomodoro stopped", string.format("%d session(s) today", st.today or 0)
	end
	return "Pomodoro", event
end

--- Announce an event: only ntfy when it is enabled (ntfy_only), otherwise the
--- pomodoro channels plus a local sound.
local function announce(event, st)
	if event == nil or event == "" then
		return
	end
	local title, message = event_text(event, st)
	local opts = {
		type = "pomodoro",
		priority = event == "stop" and "low" or "high",
		tags = EVENT_TAGS[event],
		pomodoro_event = event,
	}
	if ntfy_enabled() and cfg.ntfy_only ~= false then
		opts.channels = { "ntfy" }
	else
		play(event)
	end
	manager.send_notification(title, message, opts)
end
M._announce = announce

-- =============================================================================
-- Local clock (no server): the same state machine as app/pomodoro
-- =============================================================================

local L = nil -- state: { phase, running, started, ends_at, remaining, duration, session, completed, today, day, settings, version, last_event }
local timer = nil

local function today_key()
	return os.date("%Y-%m-%d")
end

local function duration(phase, s)
	s = s or L.settings
	if phase == PHASE.WORK then
		return s.work * 60
	elseif phase == PHASE.SHORT_BREAK then
		return s.short_break * 60
	elseif phase == PHASE.LONG_BREAK then
		return s.long_break * 60
	end
	return 0
end

local function next_phase(phase)
	if phase ~= PHASE.WORK then
		return PHASE.WORK
	end
	return L.completed >= L.settings.long_break_after and PHASE.LONG_BREAK or PHASE.SHORT_BREAK
end

local function begin(phase, now)
	local event = "break_start"
	if phase == PHASE.WORK then
		event = "work_start"
		if L.completed >= L.settings.long_break_after then
			L.completed = 0
		end
		if L.completed == 0 and (L.session or 0) > 0 then
			event = "restart"
		end
		L.session = L.completed + 1
	end
	L.phase, L.running, L.started = phase, true, true
	L.duration = duration(phase)
	L.remaining = L.duration
	L.ends_at = now + L.duration
	return event
end

local function finish(at)
	local ended = L.phase
	if ended == PHASE.WORK then
		L.completed = L.completed + 1
		local day = os.date("%Y-%m-%d", at)
		if L.day ~= day then
			L.day, L.today = day, 0
		end
		L.today = L.today + 1
	end
	local nxt = next_phase(ended)
	local auto = (ended == PHASE.WORK and L.settings.auto_start_break) or (ended ~= PHASE.WORK and L.settings.auto_start_work)
	if auto then
		return begin(nxt, at)
	end
	L.phase, L.running, L.started, L.ends_at = nxt, false, false, nil
	L.duration = duration(nxt)
	L.remaining = L.duration
	return ended == PHASE.WORK and "work_end" or "break_end"
end

local function save()
	L.version = (L.version or 0) + 1
	store.save_pomodoro(L)
end

local function snapshot()
	local st = vim.deepcopy(L)
	if st.running then
		st.remaining = math.max(0, st.ends_at - os.time())
	end
	if st.day ~= today_key() then
		st.today = 0
	end
	return st
end

local function stop_timer()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

local function local_tick()
	if not L or not L.running or L.ends_at > os.time() then
		return
	end
	local event = finish(L.ends_at)
	L.last_event = event
	save()
	announce(event, snapshot())
	if not L.running then
		stop_timer()
	end
end

local function ensure_timer()
	if L.running and not timer then
		timer = vim.uv.new_timer()
		timer:start(1000, 1000, vim.schedule_wrap(local_tick))
	elseif not L.running then
		stop_timer()
	end
end

local function load_local()
	local saved = store.get_pomodoro()
	if type(saved) == "table" and saved.settings and saved.phase and PHASE[saved.phase:upper()] then
		L = saved
	else
		-- older state format (phase/remaining ticking): start fresh
		L = { phase = PHASE.IDLE, running = false, started = false, completed = 0, session = 0, today = 0, day = today_key(), settings = settings_from_cfg() }
	end
	-- config changed since the settings were last taken from it: use it
	local from_cfg = settings_from_cfg()
	if not vim.deep_equal(L.config_settings, from_cfg) then
		L.settings, L.config_settings = from_cfg, from_cfg
	end
	-- phases that ended while Neovim was closed: advance silently
	for _ = 1, 100 do
		if not (L.running and L.ends_at and L.ends_at <= os.time()) then
			break
		end
		finish(L.ends_at)
	end
	ensure_timer()
end

-- Run a local action: fn(now) returns event, err
local function local_act(fn)
	if not L then
		load_local()
	end
	local_tick()
	local event, err = fn(os.time())
	if err then
		return nil, err
	end
	if event then
		L.last_event = event
	end
	save()
	ensure_timer()
	local st = snapshot()
	announce(event, st)
	return st
end

local local_actions = {
	start = function(now)
		if L.phase == PHASE.IDLE then
			L.completed = 0
			return begin(PHASE.WORK, now)
		elseif L.running then
			return nil
		elseif not L.started then
			return begin(L.phase, now)
		end
		L.running, L.ends_at = true, now + L.remaining
		return nil
	end,
	pause = function(now)
		if not L.running then
			return nil, "not running"
		end
		L.remaining = math.max(1, L.ends_at - now)
		L.running, L.ends_at = false, nil
		return nil
	end,
	skip = function(now)
		if L.phase == PHASE.IDLE then
			return nil, "not running"
		end
		if not L.started then
			if L.phase == PHASE.WORK then
				return nil, "work is waiting to be started"
			end
			return begin(PHASE.WORK, now)
		end
		return finish(now)
	end,
	stop = function()
		if L.phase == PHASE.IDLE then
			return nil
		end
		L.phase, L.running, L.started, L.ends_at, L.remaining, L.duration, L.session = PHASE.IDLE, false, false, nil, 0, 0, 0
		return "stop"
	end,
	restart = function(now)
		L.completed = 0
		begin(PHASE.WORK, now)
		return "restart"
	end,
}
local_actions.resume = function(now)
	if L.phase == PHASE.IDLE or L.running or not L.started then
		return nil, "not paused"
	end
	return local_actions.start(now)
end
local_actions.toggle = function(now)
	if L.running then
		return local_actions.pause(now)
	end
	return local_actions.start(now)
end

-- =============================================================================
-- Server clock
-- =============================================================================

local R = { state = nil, fetched = 0, ends_local = nil, poll = nil, failed_at = nil }

local function adopt(st)
	if type(st) ~= "table" or st.enabled == false or not st.phase then
		return
	end
	local prev = R.state
	R.state, R.fetched = st, os.time()
	R.ends_local = st.running and (os.time() + (st.remaining or 0)) or nil
	-- A server without ntfy can't alert anyone: do it here
	if prev and st.ntfy == false and st.version ~= prev.version and st.last_event and st.last_event ~= prev.last_event then
		local view = vim.deepcopy(st)
		view.ends_at = R.ends_local
		announce(st.last_event, view)
	end
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

local function remote_act(action, body)
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

local function act(action, body)
	if remote() then
		return remote_act(action, body)
	end
	local st, err = local_act(local_actions[action])
	if not st then
		vim.notify("Pomodoro: " .. err, vim.log.levels.WARN)
		return nil, err
	end
	echo(M.describe(M.status()))
	return st
end

function M.start()
	return act("start")
end
function M.pause()
	return act("pause")
end
function M.resume()
	return act("resume")
end
function M.toggle()
	return act("toggle")
end
function M.stop()
	return act("stop")
end
function M.skip_to_next()
	return act("skip")
end
M.skip = M.skip_to_next
function M.restart()
	return act("restart")
end

--- Change settings: { work, short_break, long_break, long_break_after, auto_start_break, auto_start_work }
function M.update_settings(changes)
	if remote() then
		return remote_act("settings", changes)
	end
	if not L then
		load_local()
	end
	local s = vim.tbl_extend("force", L.settings, changes)
	for _, k in ipairs({ "work", "short_break", "long_break", "long_break_after" }) do
		if type(s[k]) ~= "number" or s[k] < 1 then
			vim.notify("Pomodoro: " .. k .. " must be a positive number", vim.log.levels.WARN)
			return nil
		end
	end
	L.settings = s
	if L.phase ~= PHASE.IDLE and not L.started then
		L.duration = duration(L.phase)
		L.remaining = L.duration
	end
	save()
	echo(M.describe(M.status()))
	return snapshot()
end

--- Current state: { phase, phase_name, running, started, remaining,
--- remaining_formatted, duration, session, completed, today, settings,
--- ends_at (epoch), is_active, remote }. With a server this is the last
--- state fetched (refreshed in the background); call M.refresh(cb) to wait.
function M.status()
	local st
	if remote() then
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
			return { phase = PHASE.IDLE, phase_name = "Unreachable", remaining = 0, remaining_formatted = "--:--", remote = true, error = true }
		end
		st = vim.deepcopy(R.state)
		st.ends_at = R.ends_local
		if st.running and R.ends_local then
			st.remaining = math.max(0, R.ends_local - os.time())
		end
		st.remote = true
	else
		if not L then
			load_local()
		end
		st = snapshot()
	end
	st.phase_name = NAMES[st.phase] or st.phase
	st.remaining_formatted = fmt(st.remaining or 0)
	st.is_active = st.running == true
	-- backwards compatible: "stopped" when idle
	if st.phase == PHASE.IDLE then
		st.phase = "stopped"
	end
	return st
end

--- One line: "Work 1/4 · 12:34 left · until 11:20"
function M.describe(st)
	st = st or M.status()
	if st.error then
		return "Pomodoro server unreachable"
	end
	if st.phase == "stopped" then
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

--- For statuslines: "🍅 12:34" while active, "" when idle.
function M.statusline()
	local ok, st = pcall(M.status)
	if not ok or st.error or st.phase == "stopped" then
		return ""
	end
	local icon = st.phase == PHASE.WORK and "🍅" or "☕"
	if not st.started then
		return icon .. " ready"
	end
	return icon .. " " .. st.remaining_formatted .. (st.running and "" or " ⏸")
end

function M.setup(config, all_providers)
	cfg = config or {}
	providers_cfg = all_providers or {}
	if remote() then
		-- learn the server's state in the background; push the configured
		-- settings when they changed since the last push (settings changed on
		-- the website stick otherwise)
		vim.defer_fn(function()
			local from_cfg = settings_from_cfg()
			local pushed = store.get_pomodoro_pushed()
			if not vim.deep_equal(pushed, from_cfg) then
				server.request("POST", "/api/pomodoro/settings", from_cfg, function(ok, body)
					if ok then
						store.save_pomodoro_pushed(from_cfg)
						adopt(body)
					end
				end, { timeout = 5 })
			end
			fetch(function(ok)
				if ok then
					ensure_poll()
				end
			end)
		end, 200)
	else
		load_local()
	end
end

function M.cleanup()
	stop_timer()
	if R.poll then
		R.poll:stop()
		R.poll:close()
		R.poll = nil
	end
end

return M
