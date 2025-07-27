local calendar_store = require("zortex.stores.calendar")

local M = {}

-- =============================================================================
-- Calendar Search
-- =============================================================================

-- Search calendar entries
function M.search(query, opts)
	opts = opts or {}

	local results = {}
	local query_lower = query:lower()

	-- Ensure loaded
	if not calendar_store.data.entries then
		calendar_store.load()
	end

	-- Search all entries
	for date_str, entries in pairs(calendar_store.data.entries) do
		for i, entry in ipairs(entries) do
			local text_lower = (entry.display_text or ""):lower()

			if text_lower:find(query_lower, 1, true) then
				table.insert(results, {
					date = date_str,
					entry = entry,
					index = i,
					score = 1, -- Simple scoring for now
				})
			end
		end
	end

	-- Sort by date (most recent first)
	table.sort(results, function(a, b)
		return a.date > b.date
	end)

	return results
end

return M
