-- Config.syntax: the label rule, and .z/syntax.json for the web app
local T = require("helpers")
local syntax = require("zortex.core.syntax")
local sc = require("zortex.core.syntax_config")
local State = require("zortex.core.state")

local function kind(line)
	return syntax.classify(line).kind
end

T.test("labels: up to label_max_words words, and an is_label function", function()
	local ok, err = pcall(function()
		T.eq(kind("Questions for the doctor:"), "text") -- four words
		sc.setup({ label_max_words = 5 })
		T.eq(kind("Questions for the doctor:"), "label")
		T.eq(kind("One two three four five six:"), "text")
		local data = vim.json.decode(table.concat(vim.fn.readfile(State.path("syntax")), "\n"))
		T.eq(data.label_max_words, 5)
		-- a function decides first; nil keeps the count's answer
		sc.setup({
			is_label = function(text)
				if text:match("^Note to self") then
					return true
				end
				if text == "Ideas" then
					return false
				end
			end,
		})
		T.eq(kind("Note to self about the long weekend:"), "label")
		T.eq(kind("Ideas:"), "text")
		T.eq(kind("Wins:"), "label")
		T.eq(kind("- [ ] Note to self:"), "item", "a task is never a label")
		-- an error in it is the count's answer
		sc.setup({ is_label = function() error("boom") end })
		T.eq(kind("Wins:"), "label")
	end)
	sc.setup({})
	os.remove(State.path("syntax"))
	assert(ok, err)
	T.eq(kind("Questions for the doctor:"), "text")
end)
