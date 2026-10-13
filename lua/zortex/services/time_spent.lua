-- services/time_spent.lua - Time spent on tasks, per day
--
-- `zortex serve` counts the time its clocks run against a task (time
-- tracking), adds it to the task's @spent(...) and records it per day in
-- notes_dir/.z/time_spent.json, which syncs here with the notes:
--   { version = 1, days = { ["2026-10-13"] = { { rel, lnum, id?, text, key, minutes } } } }
-- Neovim only reads it (the reviews).
local M = {}

local function path()
	local dir = require("zortex.config").notes_dir or ""
	if dir ~= "" and dir:sub(-1) ~= "/" then
		dir = dir .. "/"
	end
	return dir .. ".z/time_spent.json"
end

--- The file's days table ({} when there is none)
function M.days()
	local f = io.open(path(), "r")
	if not f then
		return {}
	end
	local raw = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
	if not ok or type(data) ~= "table" or type(data.days) ~= "table" then
		return {}
	end
	return data.days
end

--- Time per task over [from, to] ("YYYY-MM-DD"), most first:
--- { minutes = total, tasks = { { text, rel, lnum, file, minutes } } }
function M.between(from, to)
	local by_key, order, total = {}, {}, 0
	for day, list in pairs(M.days()) do
		if day >= from and day <= to then
			for _, t in ipairs(list) do
				local key = t.key or ((t.rel or "") .. "|" .. (t.text or ""))
				local agg = by_key[key]
				if not agg then
					agg = { text = t.text, rel = t.rel, lnum = t.lnum, minutes = 0, last = day }
					by_key[key] = agg
					order[#order + 1] = agg
				end
				agg.minutes = agg.minutes + (tonumber(t.minutes) or 0)
				if day >= agg.last then
					agg.last, agg.lnum, agg.text = day, t.lnum, t.text
				end
				total = total + (tonumber(t.minutes) or 0)
			end
		end
	end
	local dir = require("zortex.config").notes_dir or ""
	if dir ~= "" and dir:sub(-1) ~= "/" then
		dir = dir .. "/"
	end
	for _, t in ipairs(order) do
		t.file = t.rel and (dir .. t.rel) or nil
	end
	table.sort(order, function(a, b)
		if a.minutes ~= b.minutes then
			return a.minutes > b.minutes
		end
		return (a.text or "") < (b.text or "")
	end)
	return { minutes = total, tasks = order }
end

--- 85 -> "1h 25m", 45 -> "45m"
function M.format(minutes)
	minutes = math.floor((minutes or 0) + 0.5)
	local h, m = math.floor(minutes / 60), minutes % 60
	if h == 0 then
		return m .. "m"
	end
	return m == 0 and (h .. "h") or string.format("%dh %dm", h, m)
end

return M
