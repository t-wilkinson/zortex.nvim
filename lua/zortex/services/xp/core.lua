-- services/xp/core.lua - Keep XP current and announce changes
--
-- The ledger (services/xp/ledger) is rebuilt whenever a note changes. This
-- module watches for that (task toggles, saving a note) and, comparing with
-- the last totals, emits:
--
--   xp:awarded / xp:removed   { amount, season_amount, entries }
--   season:leveled_up         { old_level, new_level, tier_info }
--   area:leveled_up           { key, old_level, new_level }
local M = {}

local Events = require("zortex.core.event_bus")
local Logger = require("zortex.core.logger")

local last = nil -- { total, season }
local pending = nil

local function ledger()
	return require("zortex.services.xp.ledger")
end

local function area_levels(l)
	local store = require("zortex.stores.xp")
	local levels = {}
	for _, area in ipairs(require("zortex.services.areas").all({ include_roots = false })) do
		local total = area:total_xp(l)
		if total > 0 then
			levels[area.key] = store.calculate_area_level(total)
		end
	end
	return levels
end

--- Rebuild (if anything changed) and announce the difference.
function M.refresh()
	local stop = Logger.start_timer("xp.refresh")
	local store = require("zortex.stores.xp")
	local L = ledger()
	local ok, l = pcall(L.get)
	if not ok then
		Logger.error("xp", "ledger failed", { error = l })
		stop()
		return
	end
	local season = store.current_season()
	local season_xp = L.season_xp(season, l)
	local now = { total = l.total, season = season_xp }

	if last and math.abs(now.total - last.total) >= 0.5 then
		local diff = now.total - last.total
		local function round(x)
			return x < 0 and -math.floor(-x + 0.5) or math.floor(x + 0.5)
		end
		Events.emit(diff > 0 and "xp:awarded" or "xp:removed", {
			amount = round(diff),
			season_amount = round(now.season - last.season),
			total = now.total,
		})
	end
	last = now

	local season_level = season and store.calculate_season_level(season_xp) or nil
	local ok_levels, levels = pcall(area_levels, l)
	local ups = store.update_seen(season_level, ok_levels and levels or {})
	if ups.season then
		Events.emit("season:leveled_up", {
			old_level = ups.season.old,
			new_level = ups.season.new,
			tier_info = store.get_season_tier(ups.season.new),
		})
	end
	for _, up in ipairs(ups.areas) do
		Events.emit("area:leveled_up", { key = up.key, old_level = up.old, new_level = up.new })
	end
	stop()
end

--- Refresh soon (coalesces bursts of edits).
function M.schedule_refresh(delay)
	if pending then
		pending:stop()
		pending:close()
	end
	pending = (vim.uv or vim.loop).new_timer()
	pending:start(
		delay or 300,
		0,
		vim.schedule_wrap(function()
			if pending then
				pending:close()
				pending = nil
			end
			M.refresh()
		end)
	)
end

-- =============================================================================
-- @done on save
-- =============================================================================

-- Tasks checked by hand ("[ ]" -> "[x]" typed, not toggled) get @done(today)
-- when the note is saved, so their XP lands on the right day. Only tasks
-- that are newly checked in this edit are stamped: a checked line identical
-- to the file on disk is old and left alone.
function M.stamp_done(bufnr)
	local Item = require("zortex.core.item")
	local attributes = require("zortex.utils.attributes")
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return 0
	end
	local disk = {}
	for _, line in ipairs(require("zortex.utils.filesystem").read_lines(path) or {}) do
		disk[line] = true
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local today = os.date("%Y-%m-%d")
	local stamped = 0
	for i, line in ipairs(lines) do
		if not disk[line] and line:find("[xX]%]") then
			local task = Item.task(line)
			if task and task.completed and not task.attributes.done then
				local new = attributes.update_attribute(line, "done", today)
				if new ~= line then
					vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new })
					stamped = stamped + 1
				end
			end
		end
	end
	return stamped
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.init(opts)
	opts = opts or {}
	Events.on("task:completed", function()
		M.schedule_refresh()
	end, { name = "xp.task_completed" })
	Events.on("task:uncompleted", function()
		M.schedule_refresh()
	end, { name = "xp.task_uncompleted" })
	Events.on("season:started", function()
		M.schedule_refresh(0)
	end, { name = "xp.season_started" })

	local group = vim.api.nvim_create_augroup("ZortexXP", { clear = true })
	local ext = require("zortex.config").extension or ".zortex"
	if opts.stamp_done_on_save ~= false then
		vim.api.nvim_create_autocmd("BufWritePre", {
			group = group,
			pattern = "*" .. ext,
			callback = function(ev)
				pcall(M.stamp_done, ev.buf)
			end,
			desc = "Zortex: add @done(today) to tasks checked by hand",
		})
	end
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*" .. ext,
		callback = function()
			M.schedule_refresh(500)
		end,
		desc = "Zortex: update XP",
	})
	-- learn the current totals without announcing them
	vim.defer_fn(function()
		pcall(M.refresh)
	end, 1500)
end

--- Forget the last totals (tests).
function M._reset()
	last = nil
end

return M
