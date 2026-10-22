-- stores/notifications.lua - What Neovim remembers about notifications: the
-- calendar notifications last sent to the server, so an unchanged calendar
-- isn't sent again (notifications/calendar).
local M = {}

local State = require("zortex.core.state")

local store = State.open("notifications_state", {
	version = 1,
	default = function()
		return {}
	end,
})

function M.get_calendar_manifest()
	return store:get().calendar_manifest
end

function M.save_calendar_manifest(manifest)
	store:get().calendar_manifest = manifest
	return store:save()
end

return M
