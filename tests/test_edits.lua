local T = require("helpers")
local tasks = require("zortex.services.tasks")

T.test("edits.json matches tasks.edit_line (regenerate with tests/gen_edits.lua)", function()
	local fixture = vim.json.decode(table.concat(vim.fn.readfile(T.root .. "/tests/fixtures/edits.json"), "\n"))
	local cases = require("edit_cases")
	T.eq(#fixture.cases, #cases.lines * #cases.ops, "case count")
	for _, c in ipairs(fixture.cases) do
		local result, err = tasks.edit_line(c.line, c.op, { today = fixture.today, id = fixture.id })
		T.eq({ result = result, error = err and true or nil }, { result = c.result, error = c.error }, c.op .. " " .. c.line)
	end
end)

T.test("edit_line: ids are added once, done dates follow the toggle", function()
	local line = tasks.edit_line("- [ ] Clean short blocks @xl", "toggle", { today = "2026-10-12" })
	T.ok(line:match("^%- %[x%] Clean short blocks @xl @id%(%w+%) @done%(2026%-10%-12%)$"), line)
	local back = tasks.edit_line(line, "toggle")
	T.ok(back:match("^%- %[ %] Clean short blocks @xl @id%(%w+%)$"), back)
	T.eq(back:match("@id%((%w+)%)"), line:match("@id%((%w+)%)"))
end)
