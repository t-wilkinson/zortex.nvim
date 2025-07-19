-- notifications/state.lua - State persistence for notifications
local M = {}

local fs = require("zortex.core.filesystem")
local constants = require("zortex.constants")

-- Load scheduled notifications
function M.load_scheduled()
	local path = fs.get_file_path(constants.FILES.NOTIFICATIONS_STATE)
	if path then
		local data = fs.read_json(path)
		if data and data.scheduled then
			return data.scheduled
		end
	end
	return {}
end

-- Save scheduled notifications
function M.save_scheduled(scheduled)
	local path = fs.get_file_path(constants.FILES.NOTIFICATIONS_STATE)
	if path then
		local data = fs.read_json(path) or {}
		data.scheduled = scheduled
		data.last_updated = os.time()
		return fs.write_json(path, data)
	end
	return false
end

-- Log a notification
function M.log_notification(notification)
	local path = fs.get_file_path(constants.FILES.NOTIFICATIONS_LOG)
	if path then
		local log = fs.read_json(path) or { entries = {} }

		-- Add to log
		table.insert(log.entries, notification)

		-- Keep only last 1000 entries
		if #log.entries > 1000 then
			log.entries = vim.list_slice(log.entries, #log.entries - 999, #log.entries)
		end

		return fs.write_json(path, log)
	end
	return false
end

-- Get notification log
function M.get_log(limit)
	local path = fs.get_file_path(constants.FILES.NOTIFICATIONS_LOG)
	if path then
		local log = fs.read_json(path)
		if log and log.entries then
			if limit and limit < #log.entries then
				return vim.list_slice(log.entries, #log.entries - limit + 1, #log.entries)
			end
			return log.entries
		end
	end
	return {}
end

-- Pomodoro state
function M.load_pomodoro()
	local path = fs.get_file_path(constants.FILES.POMODORO)
	if path then
		return fs.read_json(path)
	end
	return nil
end

function M.save_pomodoro(state)
	local path = fs.get_file_path(constants.FILES.POMODORO)
	if path then
		return fs.write_json(path, state)
	end
	return false
end

-- Clean old data
function M.clean_old_data(days)
	days = days or 30
	local cutoff = os.time() - (days * 24 * 60 * 60)

	-- Clean log entries
	local log_path = fs.get_file_path(constants.FILES.NOTIFICATIONS_LOG)
	if log_path then
		local log = fs.read_json(log_path)
		if log and log.entries then
			local cleaned_entries = {}
			for _, entry in ipairs(log.entries) do
				if entry.timestamp and entry.timestamp > cutoff then
					table.insert(cleaned_entries, entry)
				end
			end
			log.entries = cleaned_entries
			fs.write_json(log_path, log)
		end
	end

	-- Clean old scheduled notifications
	local state_path = fs.get_file_path(constants.FILES.NOTIFICATIONS_STATE)
	if state_path then
		local data = fs.read_json(state_path)
		if data and data.scheduled then
			local cleaned_scheduled = {}
			for id, notif in pairs(data.scheduled) do
				if notif.scheduled_time > cutoff then
					cleaned_scheduled[id] = notif
				end
			end
			data.scheduled = cleaned_scheduled
			fs.write_json(state_path, data)
		end
	end
end

return M

