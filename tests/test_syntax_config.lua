-- Config.syntax: the label rule, and .z/syntax.json for the web app
local T = require("helpers")
local syntax = require("zortex.core.syntax")
local sc = require("zortex.core.syntax_config")
local State = require("zortex.core.state")

local function kind(line)
	return syntax.classify(line).kind
end

-- the label key of a "Key: text" line, or of an item ("- Key: text"), or nil
local function key(line)
	local d = syntax.classify(line)
	if d.item then
		return d.item.label and d.item.key or nil
	end
	return d.key
end

T.test("labels are written Label:: and Title:::, whatever their length", function()
	T.eq(kind("Questions for the doctor before the visit::"), "label")
	T.eq(kind("Questions for the doctor before the visit:::"), "bold_heading")
	T.eq(kind("Questions for the doctor:"), "text", "one colon is never structure")
	T.eq(key("Questions for the doctor before the visit:: and more"), "Questions for the doctor before the visit")
	T.eq(key("- Questions for the doctor before the visit::"), "Questions for the doctor before the visit")
end)

T.test("Key: lines: label_max_words words, or label_pattern", function()
	local ok, err = pcall(function()
		T.eq(key("Questions for the doctor: none"), nil) -- four words
		T.eq(key("Wins: shipped"), "Wins")
		sc.setup({ label_max_words = 5 })
		T.eq(key("Questions for the doctor: none"), "Questions for the doctor")
		T.eq(key("- Questions for the doctor:"), "Questions for the doctor")
		T.eq(key("One two three four five six: x"), nil)
		T.eq(kind("Questions for the doctor:"), "text", "still not a section")
		local data = vim.json.decode(table.concat(vim.fn.readfile(State.path("syntax")), "\n"))
		T.eq(data.label_max_words, 5)
		T.eq(data.label_pattern, nil)

		-- a pattern says yes too; 0 words turns the count off
		sc.setup({ label_max_words = 0, label_pattern = "^Note to self" })
		T.eq(key("Note to self about the long weekend: rest"), "Note to self about the long weekend")
		T.eq(key("Wins: shipped"), nil)
		T.eq(key("Wins:: shipped"), "Wins", "two colons are always a label")
		T.eq(syntax.classify("- KR1: [ ] Ship").item.key, "KR1", "key results keep their key")
		T.eq(syntax.classify("- [ ] Note to self: call").item.key, nil, "a task has no key")
		data = vim.json.decode(table.concat(vim.fn.readfile(State.path("syntax")), "\n"))
		T.eq(data.label_max_words, 0)
		T.eq(data.label_pattern, "^Note to self")

		-- both: either one says yes
		sc.setup({ label_max_words = 1, label_pattern = "^%u%u+$" })
		T.eq(key("TODO: x"), "TODO")
		T.eq(key("Wins: x"), "Wins")
		T.eq(key("Two words: x"), nil)

		-- a pattern Lua can't read is off (and warned about)
		sc.setup({ label_pattern = "[" })
		T.eq(syntax.LABEL_PATTERN, nil)
		T.eq(key("Wins: x"), "Wins")
	end)
	sc.setup({})
	os.remove(State.path("syntax"))
	assert(ok, err)
	T.eq(key("Questions for the doctor: none"), nil)
	T.eq(syntax.LABEL_PATTERN, nil)
end)
