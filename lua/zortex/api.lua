-- api.lua - The public Lua API: require("zortex")
--
--   local z = require("zortex")
--   z.setup({ notes_dir = "~/notes/" })
--
--   z.actions.task_toggle()          -- any action from zortex.actions (same as its command/keymap)
--   z.run("review", { args = "14" })  -- by id, with command-style args
--
-- Services, loaded on first use (each is the module's own API):
--
--   z.query      plain data: tree, note, search, resolve, backlinks, projects, areas,
--                objectives, agenda, review, export            (zortex.query)
--   z.notes      note list and header index                      (core/notes)
--   z.document   cached note snapshots: syntax, tree, items       (core/document)
--   z.syntax     the Zortex grammar                               (core/syntax)
--   z.item       list items: tasks, calendar entries, key results (core/item)
--   z.links      resolve / resolve_first / build_link / ...       (core/link)
--   z.link_index links_from / references / backlinks / unresolved (core/link_index)
--   z.workspace  line edits: buffer if loaded, else the file      (core/workspace)
--   z.state      versioned JSON files in notes_dir/.z             (core/state)
--   z.events     domain events                                    (core/event_bus)
--   z.projects   project entities: all, get, at, resolve, query, tasks
--   z.areas      area entities: all, get, resolve, keys_for, top
--   z.okr        objectives({ current }), key_results({ open })
--   z.agenda     day, range, upcoming, review
--   z.calendar   calendar entries: get_entries_for_date, add_entry, ...  (stores/calendar)
--   z.tasks      toggle/complete/uncomplete on the cursor line, find_task_by_id
--   z.search     structural search: search, build_index, query_index     (services/search)
--   z.search_history  record, boost, clear
--   z.digest     digest note and email content
--   z.review     weekly review buffer: open, render                       (ui/review)
--   z.planner    day planning: candidates, template, put                  (services/planner)
--   z.xp         XP views and seasons                                    (services/xp/stats)
--   z.config     the merged configuration
local M = {}

local SERVICES = {
	query = "zortex.query",
	notes = "zortex.core.notes",
	document = "zortex.core.document",
	syntax = "zortex.core.syntax",
	item = "zortex.core.item",
	links = "zortex.core.link",
	link_index = "zortex.core.link_index",
	workspace = "zortex.core.workspace",
	state = "zortex.core.state",
	events = "zortex.core.event_bus",
	projects = "zortex.services.projects",
	areas = "zortex.services.areas",
	okr = "zortex.services.okr",
	agenda = "zortex.services.agenda",
	calendar = "zortex.stores.calendar",
	tasks = "zortex.services.tasks",
	search = "zortex.services.search",
	search_history = "zortex.services.search_history",
	digest = "zortex.services.digest",
	review = "zortex.ui.review",
	planner = "zortex.services.planner",
	xp = "zortex.services.xp.stats",
	config = "zortex.config",
}
M.SERVICES = SERVICES

--- Run an action by id (see zortex.actions).
function M.run(id, args)
	return require("zortex.actions").run(id, args)
end

-- z.actions.<id>(args?) for every action
M.actions = setmetatable({}, {
	__index = function(t, id)
		local action = require("zortex.actions").by_id[id]
		if not action then
			return nil
		end
		local fn = function(args)
			return action.run(args or { args = "", fargs = {} })
		end
		rawset(t, id, fn)
		return fn
	end,
})

return setmetatable(M, {
	__index = function(t, key)
		local path = SERVICES[key]
		if path then
			local mod = require(path)
			rawset(t, key, mod)
			return mod
		end
		return nil
	end,
})
