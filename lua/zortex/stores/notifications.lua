-- stores/notifications.lua - Manages persistence for all notification state

local M = {}

local BaseStore = require("zortex.stores.base")
local constants = require("zortex.constants")

local store = BaseStore:new(constants.FILES.NOTIFICATIONS_STATE)

-- Override init_empty for the main store to define the data structure
function store:init_empty()
	self.data = {
		scheduled = {}, -- Scheduled notifications
		pomodoro = {}, -- Pomodoro session state
		digest = {}, -- Digest-related state (e.g., last_sent)
		calendar_sent = {}, -- IDs of sent calendar notifications
	}
	self.loaded = true
end

-- Scheduled notifications
function M.get_scheduled()
	store:ensure_loaded()
	return store.data.scheduled or {}
end

function M.save_scheduled(scheduled_data)
	store:ensure_loaded()
	store.data.scheduled = scheduled_data
	return store:save()
end

-- Pomodoro state
function M.get_pomodoro()
	store:ensure_loaded()
	return store.data.pomodoro
end

function M.save_pomodoro(pomodoro_data)
	store:ensure_loaded()
	store.data.pomodoro = pomodoro_data
	return store:save()
end

-- Digest state
function M.get_digest_state()
	store:ensure_loaded()
	return store.data.digest or {}
end

function M.update_digest_state(digest_data)
	store:ensure_loaded()
	-- Ensure the digest table exists
	if not store.data.digest then
		store.data.digest = {}
	end
	-- Merge new data into existing digest state
	for k, v in pairs(digest_data) do
		store.data.digest[k] = v
	end
	return store:save()
end

-- Calendar sent notifications
function M.get_calendar_sent()
	store:ensure_loaded()
	return store.data.calendar_sent or {}
end

function M.save_calendar_sent(calendar_data)
	store:ensure_loaded()
	store.data.calendar_sent = calendar_data
	return store:save()
end

-- Force operations
function M.reload()
	store.loaded = false
	store:load()
end

function M.save()
	store:save()
end

return M
