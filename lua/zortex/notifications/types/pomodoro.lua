-- notifications/types/pomodoro.lua - Pomodoro timer implementation
local M = {}

local manager = require("zortex.notifications.manager")
local store = require("zortex.stores.notifications")

local cfg = {}
local current_session = nil
local timer_handle = nil

local PHASE = {
	WORK = "work",
	SHORT_BREAK = "short_break",
	LONG_BREAK = "long_break",
	STOPPED = "stopped",
	PAUSED = "paused",
}

-- Calculate next phase
local function get_next_phase()
	if not current_session then
		return PHASE.WORK
	end

	if current_session.phase == PHASE.WORK then
		current_session.work_count = (current_session.work_count or 0) + 1
		if current_session.work_count % cfg.long_break_after == 0 then
			return PHASE.LONG_BREAK
		else
			return PHASE.SHORT_BREAK
		end
	else
		return PHASE.WORK
	end
end

-- Get duration for phase
local function get_phase_duration(phase)
	if phase == PHASE.WORK then
		return cfg.work_duration * 60
	elseif phase == PHASE.SHORT_BREAK then
		return cfg.short_break * 60
	elseif phase == PHASE.LONG_BREAK then
		return cfg.long_break * 60
	end
	return 0
end

-- Format time remaining
local function format_time(seconds)
	local mins = math.floor(seconds / 60)
	local secs = seconds % 60
	return string.format("%02d:%02d", mins, secs)
end

-- Get phase display name
local function get_phase_name(phase)
	local names = {
		[PHASE.WORK] = "Work Session",
		[PHASE.SHORT_BREAK] = "Short Break",
		[PHASE.LONG_BREAK] = "Long Break",
		[PHASE.STOPPED] = "Stopped",
		[PHASE.PAUSED] = "Paused",
	}
	return names[phase] or phase
end

-- Timer tick
local function tick()
	if not current_session or current_session.phase == PHASE.STOPPED then
		return
	end

	if current_session.phase == PHASE.PAUSED then
		return
	end

	current_session.remaining = current_session.remaining - 1

	if current_session.remaining <= 0 then
		-- Phase complete
		local completed_phase = current_session.phase
		local phase_name = get_phase_name(completed_phase)

		manager.send_notification("Pomodoro - " .. phase_name .. " Complete", phase_name .. " session completed!", {
			type = "pomodoro",
			sound = cfg.sound,
			priority = "high",
		})

		-- Move to next phase
		local next_phase = get_next_phase()
		local next_name = get_phase_name(next_phase)

		-- Check auto-start settings
		local should_auto_start = (completed_phase == PHASE.WORK and cfg.auto_start_break)
			or (completed_phase ~= PHASE.WORK and cfg.auto_start_work)

		if should_auto_start then
			current_session.phase = next_phase
			current_session.remaining = get_phase_duration(next_phase)
			current_session.started_at = os.time()

			manager.send_notification(
				"Pomodoro - " .. next_name .. " Started",
				next_name .. " session started (" .. format_time(current_session.remaining) .. ")",
				{ type = "pomodoro" }
			)
		else
			current_session.phase = PHASE.STOPPED
			manager.send_notification(
				"Pomodoro - Ready for " .. next_name,
				"Start when you're ready!",
				{ type = "pomodoro" }
			)
		end

		store.save_pomodoro(current_session)
	end
end

-- Start pomodoro
function M.start(phase)
	phase = phase or PHASE.WORK

	-- If resuming from stopped state, preserve work count
	local work_count = 0
	if current_session and current_session.work_count then
		work_count = current_session.work_count
	end

	current_session = {
		phase = phase,
		remaining = get_phase_duration(phase),
		started_at = os.time(),
		work_count = work_count,
	}

	store.save_pomodoro(current_session)

	if not timer_handle then
		timer_handle = vim.loop.new_timer()
		timer_handle:start(0, 1000, vim.schedule_wrap(tick))
	end

	local phase_name = get_phase_name(phase)
	manager.send_notification(
		"Pomodoro Started",
		phase_name .. " session started (" .. format_time(current_session.remaining) .. ")",
		{ type = "pomodoro" }
	)

	return current_session
end

-- Stop pomodoro
function M.stop()
	if current_session then
		current_session.phase = PHASE.STOPPED
		store.save_pomodoro(current_session)
	end

	if timer_handle then
		timer_handle:stop()
		timer_handle:close()
		timer_handle = nil
	end

	manager.send_notification("Pomodoro Stopped", "Pomodoro session stopped", { type = "pomodoro" })
end

-- Pause/Resume
function M.pause()
	if current_session and current_session.phase ~= PHASE.STOPPED and current_session.phase ~= PHASE.PAUSED then
		current_session.previous_phase = current_session.phase
		current_session.phase = PHASE.PAUSED
		current_session.paused_at = os.time()
		store.save_pomodoro(current_session)

		manager.send_notification("Pomodoro Paused", "Session paused", { type = "pomodoro" })
		return true
	end
	return false
end

function M.resume()
	if current_session and current_session.phase == PHASE.PAUSED then
		current_session.phase = current_session.previous_phase or PHASE.WORK
		current_session.paused_at = nil
		current_session.previous_phase = nil
		store.save_pomodoro(current_session)

		manager.send_notification(
			"Pomodoro Resumed",
			"Session resumed (" .. format_time(current_session.remaining) .. " remaining)",
			{ type = "pomodoro" }
		)
		return true
	end
	return false
end

-- Get status
function M.status()
	if not current_session then
		return { phase = PHASE.STOPPED }
	end

	return {
		phase = current_session.phase,
		phase_name = get_phase_name(current_session.phase),
		remaining = current_session.remaining,
		remaining_formatted = format_time(current_session.remaining or 0),
		work_count = current_session.work_count or 0,
		started_at = current_session.started_at,
		is_active = current_session.phase ~= PHASE.STOPPED and current_session.phase ~= PHASE.PAUSED,
	}
end

-- Skip to next phase
function M.skip_to_next()
	if current_session and current_session.phase ~= PHASE.STOPPED and current_session.phase ~= PHASE.PAUSED then
		current_session.remaining = 0
		return true
	end
	return false
end

-- Setup
function M.setup(config)
	cfg = config

	-- Load saved session
	current_session = store.get_pomodoro()

	-- Restart timer if session is active
	if
		current_session
		and current_session.phase ~= PHASE.STOPPED
		and current_session.phase ~= PHASE.PAUSED
		and current_session.remaining
		and current_session.remaining > 0
	then
		timer_handle = vim.loop.new_timer()
		timer_handle:start(0, 1000, vim.schedule_wrap(tick))
	end
end

return M

