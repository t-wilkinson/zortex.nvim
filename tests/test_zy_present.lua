local T = require("helpers")
local present = require("zortex.features.present")
local Config = require("zortex.config")

T.test("present: the deck URL of a note, at the cursor's line", function()
	local saved = Config.server
	Config.server = vim.tbl_extend("force", saved or {}, { api_endpoint = "http://127.0.0.1:8090/", web_url = nil })
	T.eq(present.url(Config.notes_dir .. "projects.zortex", 12), "http://127.0.0.1:8090/n/projects.zortex?view=slides#L12")
	Config.server.web_url = "https://notes.example.com/z"
	T.eq(present.url(Config.notes_dir .. "z/my talk.zortex", 0), "https://notes.example.com/z/n/z/my%20talk.zortex?view=slides")
	local url, err = present.url("/elsewhere/x.zortex", 1)
	T.eq(url, nil)
	T.ok(err and err:find("notes_dir", 1, true), tostring(err))
	Config.server = saved
end)
