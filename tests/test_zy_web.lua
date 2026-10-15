local T = require("helpers")
local web = require("zortex.features.web")
local tag_index = require("zortex.core.tag_index")
local Document = require("zortex.core.document")
local Config = require("zortex.config")

local HUB = {
	"@@Topics hub",
	"",
	"Topics:",
	"- AI @[R/rl, ai-model]",
	"  - Reinforcement learning @[R/rl]",
	"  - Models @[R/rl ai-model]",
	"- Embedded",
	"  - Rust **embedded** @[R/rust embedded]",
	"  - @[R/async]",
	"- Labelled:",
	"  - Spinning @[R/rl]",
	"",
	"Reading:",
	"@[R/rust]",
	"",
	"Not an index:",
	"- plain item",
	"- @[R/rust]",
}

T.test("tag index: a label whose lines are tag searches or groups of them", function()
	local doc = Document.from_lines(HUB, Config.notes_dir .. "z/hub.zortex")
	local ix = tag_index.at_label(doc, 3)
	T.eq({ ix.name, ix.last, #ix.nodes }, { "Topics", 11, 3 })
	local ai, embedded, labelled = ix.nodes[1], ix.nodes[2], ix.nodes[3]
	T.eq({ ai.name, ai.query, #ai.children }, { "AI", "R/rl, ai-model", 2 })
	T.eq({ embedded.name, embedded.query, tag_index.group_query(embedded) }, { "Embedded", nil, "R/rust embedded, async" })
	T.eq({ embedded.children[1].name, embedded.children[2].name }, { "Rust embedded", "" })
	T.eq({ labelled.name, tag_index.group_query(labelled) }, { "Labelled", "R/rl" })
	T.ok(tag_index.at_label(doc, 13), "a label with bare @[...] lines")
	T.eq(tag_index.at_label(doc, 16), nil) -- a plain item: an ordinary list
	-- a line of the index: the index and that line's chip
	local at, q = tag_index.at(doc, 7)
	T.eq({ at.lnum, q }, { 3, "R/rust embedded, async" })
	T.eq({ (tag_index.at(doc, 3)).lnum, select(2, tag_index.at(doc, 3)) }, { 3, nil })
	T.eq(tag_index.at(doc, 17), nil)
	-- searches in different places can't be one chip
	T.eq(tag_index.union({ "R/rl", "*/ml" }), nil)
	T.eq(tag_index.union({ "rl, ml", "ml" }), "rl, ml")
end)

T.test("web: where each kind of link goes in the web app", function()
	local file = Config.notes_dir .. "z/resources.zortex"
	local lines = { "09:00 [P/#1.4 - zortex]", "  - [./-Improve website]" }
	local ctx = { file = file, lnum = 2, lines = lines }
	T.eq(web.target({ type = "link", definition = "R/#Rust" }, ctx), { path = "/link?to=%5BR%2F%23Rust%5D&from=z%2Fresources.zortex" })
	T.eq(web.target({ type = "link", definition = "./-Improve website" }, ctx), {
		path = "/link?to=%5BP%2F%231.4+-+zortex%2F-Improve+website%5D&from=z%2Fresources.zortex",
	})
	T.eq(web.target({ type = "tag_search", display_text = "rust, rl" }, ctx), { path = "/link?to=%40%5Brust%2C+rl%5D&from=z%2Fresources.zortex" })
	T.eq(web.target({ type = "link", definition = "./docs/manual.pdf" }, ctx), { path = "/f/z/docs/manual.pdf" })
	T.eq(web.target({ type = "filepath", path = "./pinout.png," }, ctx), { path = "/f/z/pinout.png" })
	T.eq(web.target({ type = "markdown", url = "https://doc.rust-lang.org/book" }, ctx), { url = "https://doc.rust-lang.org/book" })
	T.eq(web.target({ type = "website", url = "https://example.com" }, ctx), { url = "https://example.com" })
	T.eq(web.target({ type = "footnote", ref_id = "1" }, { file = file, lines = { "a [^1]", "[^1]: note" } }), { path = "/n/z/resources.zortex#L2" })
	local t, err = web.target({ type = "link", definition = "../../outside.pdf" }, ctx)
	T.eq(t, nil)
	T.ok(err and err:find("outside", 1, true), tostring(err))
	T.eq(web.note_path(Config.notes_dir .. "z/my talk.zortex", 4), "/n/z/my%20talk.zortex#L4")

	local doc = Document.from_lines(HUB, Config.notes_dir .. "z/hub.zortex")
	T.eq(web.index_target(doc, doc.filepath or Config.notes_dir .. "z/hub.zortex", 3), { path = "/n/z/hub.zortex#L3" })
	T.eq(web.index_target(doc, Config.notes_dir .. "z/hub.zortex", 7), { path = "/n/z/hub.zortex#tags=R/rust+embedded,+async" })
	T.eq(web.index_target(doc, Config.notes_dir .. "z/hub.zortex", 17), nil)
end)

T.test("web: an open tab on this device, else a new tab", function()
	local saved_server, saved_features = Config.server, Config.features
	local server = require("zortex.notifications.server")
	local saved_request, saved_open = server.request, vim.ui.open
	local opened, posted = {}, {}
	vim.ui.open = function(url)
		opened[#opened + 1] = url
		return {}, nil
	end
	local answer
	server.request = function(method, path, body, cb)
		posted[#posted + 1] = method .. " " .. path .. " " .. body.path
		cb(answer ~= nil, answer)
	end
	Config.server = vim.tbl_extend("force", saved_server or {}, { enabled = true, api_endpoint = "http://127.0.0.1:8090", web_url = "https://n.example.com/z/" })

	answer = { opened = true }
	web.open({ path = "/n/projects.zortex#L3" })
	T.eq({ posted, opened }, { { "POST /api/open /n/projects.zortex#L3" }, {} })

	answer = { opened = false }
	web.open({ path = "/n/projects.zortex" })
	T.eq(opened, { "https://n.example.com/z/n/projects.zortex" })

	answer = nil -- the server isn't there
	web.open({ path = "/f/z/a.pdf" })
	T.eq(opened[2], "https://n.example.com/z/f/z/a.pdf")

	-- other sites go straight to the browser; reuse_tab = false always opens one
	web.open({ url = "https://example.com" })
	Config.features = vim.tbl_deep_extend("force", saved_features or {}, { web = { reuse_tab = false } })
	web.open({ path = "/n/okr.zortex" })
	T.eq({ #posted, opened[3], opened[4] }, { 3, "https://example.com", "https://n.example.com/z/n/okr.zortex" })

	server.request, vim.ui.open = saved_request, saved_open
	Config.server, Config.features = saved_server, saved_features
end)
