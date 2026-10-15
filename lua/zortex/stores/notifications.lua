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

			pomodoro = {}, -- the local pomodoro clock (without a server)
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
-- The local pomodoro clock (without a server)
-- ===========================================================================

function M.get_pomodoro()
	return store:get().pomodoro
end

function M.save_pomodoro(pomodoro_data)
	store:get().pomodoro = pomodoro_data
	return store:save()
end

-- ===========================================================================
-- Calendar manifest: the last set of calendar notifications synced
-- ===========================================================================

function M.get_calendar_manifest()
	return store:get().calendar_manifest
end

function M.save_calendar_manifest(manifest)
	store:get().calendar_manifest = manifest
	return store:save()
end

-- Settings last pushed to the server's pomodoro clock
function M.get_pomodoro_pushed()
	return store:get().pomodoro_pushed
end

function M.save_pomodoro_pushed(settings)
	store:get().pomodoro_pushed = settings
	return store:save()
end

return M
