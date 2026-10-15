local T = require("helpers")
local H = require("zortex.services.search_history")
local search = require("zortex.services.search")
local fs = require("zortex.utils.filesystem")
local Document = require("zortex.core.document")

local NOW = 1760000000
local projects = T.fixture("projects.zortex")
local doc = Document.get(projects)
local zortex = doc:node_starting_at(14) -- ## 1.4 - zortex

local function approx(a, b)
	return math.abs(a - b) < 1e-6
end

search.setup()
H.clear()

T.test("recording scores the note, the section and (decayed) its parents", function()
	H.record({ filepath = projects, node = zortex }, NOW)
	T.eq(H.file_score(projects, NOW), 1)
	T.eq(H.section_score(projects, "Projects › 1 Programming › 1.4 - zortex", NOW), 1)
	T.ok(approx(H.section_score(projects, "Projects › 1 Programming", NOW), 0.7))
	T.ok(approx(H.section_score(projects, "Projects", NOW), 0.49))
end)

T.test("scores decay by access_decay_rate / score_decay per day", function()
	local later = NOW + 10 * 86400
	T.ok(approx(H.file_score(projects, later), math.exp(-1)), "0.1/day over 10 days")
	H.record({ filepath = projects, node = zortex }, later)
	T.ok(approx(H.file_score(projects, later), 1 + math.exp(-1)), "decayed value + 1")
end)

T.test("history is persisted in notes_dir/.z", function()
	T.ok(fs.file_exists(T.fixture(".z/search_history.json")))
	H._reload()
	T.ok(H.file_score(projects, NOW + 10 * 86400) > 1, "loaded from disk")
end)

T.test("max_entries keeps the strongest sections", function()
	H.clear()
	search.setup({ history = { max_entries = 2 } })
	H.record({ filepath = projects, node = doc:node_starting_at(26) }, NOW) -- 4 levels deep
	local d = vim.fn.json_decode(table.concat(fs.read_lines(T.fixture(".z/search_history.json")), "\n"))
	T.eq(vim.tbl_count(d.sections), 2)
	search.setup()
end)

T.test("opened places rank higher in search", function()
	H.clear()
	local idx = search.build_index(fs.find_all_notes())
	local function garden_score()
		for _, r in ipairs(search.query_index(idx, "garden")) do
			if r.breadcrumb == "Garden" then
				return r.score
			end
		end
	end
	local before = garden_score()
	local garden = Document.get(T.fixture("z/garden.zortex"))
	H.record({ filepath = garden.filepath, node = garden:article() })
	local after = garden_score()
	T.ok(approx(after - before, 50 * math.log(2) + 30 * math.log(2)), string.format("%s -> %s", before, after))
	H.clear()
end)
