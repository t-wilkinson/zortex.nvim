-- stores/notifications.lua - Unified persistence for notification system
local M = {}

local State = require("zortex.core.state")

local store = State.open("notifications_state", {
	version = 1,
	default = function()
		return {
			-- Unified notification state
			notification_state = {
				scheduled = {}, -- All scheduled notifications
				sent = {}, -- Deduplication tracking
			},

			-- Legacy/specific module state
			pomodoro = {}, -- Pomodoro session state
			digest = {}, -- Digest-related state
		}
	end,
})


-- ===========================================================================
-- Notification State
-- ===========================================================================

function M.get_notification_state()
	return store:get().notification_state or {
		scheduled = {},
		sent = {},
	}
end

function M.save_notification_state(state_data)
	store:get().notification_state = state_data
	return store:save()
end

-- ===========================================================================
-- Legacy Support - Pomodoro
-- ===========================================================================

function M.get_pomodoro()
	return store:get().pomodoro
end

function M.save_pomodoro(pomodoro_data)
	store:get().pomodoro = pomodoro_data
	return store:save()
end

-- ===========================================================================
-- Legacy Support - Digest
-- ===========================================================================

function M.get_digest_state()
	return store:get().digest or {}
end

function M.update_digest_state(digest_data)
	if not store:get().digest then
		store:get().digest = {}
	end
	for k, v in pairs(digest_data) do
		store:get().digest[k] = v
	end
	return store:save()
end

-- ===========================================================================
-- Backward Compatibility
-- ===========================================================================

-- Old methods that map to new unified state
function M.get_scheduled()
	local state = M.get_notification_state()
	-- Convert to array format for backward compatibility
	local scheduled = {}
	for id, notif in pairs(state.scheduled or {}) do
		table.insert(scheduled, notif)
	end
	return scheduled
end

function M.save_scheduled(scheduled_data)
	local state = M.get_notification_state()
	-- Convert array to map if needed
	if vim.tbl_islist(scheduled_data) then
		state.scheduled = {}
		for _, notif in ipairs(scheduled_data) do
			if notif.id then
				state.scheduled[notif.id] = notif
			end
		end
	else
		state.scheduled = scheduled_data
	end
	return M.save_notification_state(state)
end

function M.get_calendar_sent()
	local state = M.get_notification_state()
	return state.sent or {}
end

function M.save_calendar_sent(calendar_data)
	local state = M.get_notification_state()
	state.sent = calendar_data
	return M.save_notification_state(state)
end

-- Alarm storage (maps to unified notifications)
function M.get_alarms()
	local state = M.get_notification_state()
	local alarms = {}

	-- Extract alarm-type notifications
	for id, notif in pairs(state.scheduled or {}) do
		if notif.type == "alarm" then
			table.insert(alarms, notif)
		end
	end

	return alarms
end

-- ===========================================================================
-- Utility
-- ===========================================================================

function M.reload()
	store:reload()
end

function M.save()
	return store:save()
end

return M
