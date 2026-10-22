-- core/state: synced and device files, unchanged saves, sync conflicts
local T = require("helpers")
local State = require("zortex.core.state")
local fs = require("zortex.utils.filesystem")

local function write_json(path, data)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	vim.fn.writefile({ vim.json.encode(data) }, path)
end

T.test("device files live outside notes_dir, per notes folder", function()
	local dir = State.device_dir()
	T.ok(dir:find(vim.fn.stdpath("state"), 1, true) == 1, dir)
	T.ok(not dir:find(require("zortex.config").notes_dir, 1, true), "not in the notes")
	T.ok(State.device_name():match("^[%w%-]+$"), State.device_name())
end)

T.test("a device file starts from the copy an older version synced", function()
	write_json(State.path("legacy_thing"), { version = 1, n = 7 })
	local s = State.open("legacy_thing", { version = 1, device = true })
	T.eq(s:get().n, 7)
	s:save()
	T.ok(fs.file_exists(State.device_path("legacy_thing")))
end)

T.test("an unchanged save writes nothing", function()
	local s = State.open("quiet_thing", { version = 1 })
	s:get().x = 1
	T.ok(s:save())
	local path = State.path("quiet_thing")
	local before = vim.uv.fs_stat(path).mtime
	os.remove(path)
	T.ok(s:save())
	T.ok(not fs.file_exists(path), "not rewritten")
	s:get().x = 2
	s:save()
	T.ok(fs.file_exists(path), "a change is written")
	T.ok(before)
end)

T.test("xp_state: conflict copies from two devices are merged and removed", function()
	local path = State.path("xp_state")
	write_json(path, {
		version = 3,
		current_season = { name = "Sprint B", start_date = "2026-11-01", start_time = 200 },
		season_history = { { name = "Q3", start_date = "2026-07-01", end_date = "2026-09-30" } },
	})
	local copy = path:gsub("%.json$", ".sync-conflict-20261021-101010-ABCDEFG.json")
	write_json(copy, {
		version = 3,
		current_season = nil,
		season_history = {
			{ name = "Q3", start_date = "2026-07-01", end_date = "2026-09-30" },
			{ name = "Sprint A", start_date = "2026-10-01", end_date = "2026-10-20" },
		},
		seen = { season_tier = 2, area_levels = { ["4.1"] = 3 } },
	})
	local xp = require("zortex.stores.xp")
	State.open("xp_state", {}):reload()
	T.eq(xp.started_season().name, "Sprint B")
	T.eq(
		vim.tbl_map(function(s)
			return s.name
		end, xp.season_history()),
		{ "Q3", "Sprint A" }
	)
	T.ok(not fs.file_exists(copy), "the copy is gone")
	T.ok(fs.file_exists(path))

	-- a season ended on one device is not brought back by the other's copy
	local merged = xp.merge_seasons(
		{ version = 3, current_season = { name = "S", start_date = "2026-11-01", start_time = 1 }, season_history = {} },
		{ version = 3, season_history = { { name = "S", start_date = "2026-11-01", end_date = "2026-11-20" } } }
	)
	T.eq(merged.current_season, nil)
	T.eq(#merged.season_history, 1)
	xp.reset_season()
end)

T.test("announced levels stay on this machine", function()
	local xp = require("zortex.stores.xp")
	xp.update_seen("S|2026-11-01", 1, { ["4.1"] = 2 })
	T.eq(xp.update_seen("S|2026-11-01", 1, { ["4.1"] = 3 }).areas[1].new, 3)
	local synced = vim.json.decode(table.concat(vim.fn.readfile(State.path("xp_state")), "\n"))
	T.eq(synced.seen, nil)
	T.ok(fs.file_exists(State.device_path("xp_seen")))
end)

T.test("XP summary: each device its own file; conflict copies removed", function()
	local publish = require("zortex.services.xp.publish")
	local copy = State.path("xp_summary"):gsub("%.json$", ".sync-conflict-20261021-101010-ABCDEFG.json")
	write_json(copy, { version = 2 })
	publish._reset()
	T.ok(publish.publish())
	T.ok(fs.file_exists(publish.path()))
	T.ok(not fs.file_exists(copy))
end)
