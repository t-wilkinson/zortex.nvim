-- stores/notifications.lua - Manages persistence for all notification state

local M = {}

local BaseStore = require("zortex.stores.base")
local constants = require("zortex.constants")

-- Single store for all notification state except the log, which can grow large
local store = BaseStore:new(constants.FILES.NOTIFICATIONS_STATE)
local log_store = BaseStore:new(constants.FILES.NOTIFICATIONS_LOG)

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

-- Override init_empty for the log store
function log_store:init_empty()
	self.data = {
		entries = {},
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

-- Notification Log
function M.log_notification(notification)
	log_store:ensure_loaded()
	local log = log_store.data

	if not log.entries then
		log.entries = {}
	end

	table.insert(log.entries, notification)

	-- Keep only last 1000 entries
	if #log.entries > 1000 then
		log.entries = vim.list_slice(log.entries, #log.entries - 999, #log.entries)
	end

	return log_store:save()
end

function M.get_log(limit)
	log_store:ensure_loaded()
	local log = log_store.data

	if log and log.entries then
		if limit and limit < #log.entries then
			return vim.list_slice(log.entries, #log.entries - limit + 1, #log.entries)
		end
		return log.entries
	end

	return {}
end

-- Force operations
function M.reload()
	store.loaded = false
	log_store.loaded = false
	store:load()
	log_store:load()
end

function M.save()
	store:save()
	log_store:save()
end

return M
