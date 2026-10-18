-- features/rename.lua - :ZortexRename (<leader>zR): rename the heading,
-- bold heading or label under the cursor and rewrite every link through it.
--
-- The links come from the link index (link_index.references over the whole
-- section, so [P/#1.4 - zortex/-Improve website] counts too). In each, the
-- component that finds the section is the one rewritten, and only when it
-- stops matching: "#1.4" still finds "1.4 - zortex.nvim", so it stays; a
-- renumbering ("1.4" -> "2.3") rewrites it to the new text.
local M = {}

local workspace = require("zortex.core.workspace")
local link_mod = require("zortex.core.link")

local SIGIL = { heading = "#", label = ":", bold_heading = "*" }

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Zortex" })
end

local function same_file(a, b)
	return vim.fn.fnamemodify(a, ":p") == vim.fn.fnamemodify(b, ":p")
end

--- The section starting on `lnum` that can be renamed, or nil and why.
function M.section(doc, lnum)
	local node = doc and doc:node_starting_at(lnum)
	if not node or not SIGIL[node.type] then
		return nil, "not on a heading, bold heading or label"
	end
	return node
end

--- `line` (the section's own line) with its title `old` replaced by `new`;
--- the markers around it and its @attributes stay.
function M.retitle(line, old, new)
	local s, e = line:find(old, 1, true)
	if not s then
		return nil
	end
	return line:sub(1, s - 1) .. new .. line:sub(e + 1)
end

-- Index of the component of `def` that finds the section (file, lnum), or nil
local function component_at(def, from_file, from_lnum, file, lnum)
	local comps, scope = link_mod.split(def)
	local opts = { doc = workspace.document(from_file), lnum = from_lnum }
	for i = 1, #comps do
		local prefix = (scope == "local" and "/" or "") .. table.concat(comps, "/", 1, i)
		local ok, results = pcall(link_mod.resolve, "[" .. prefix .. "]", opts)
		local r = ok and results and results[1]
		if r and r.lnum == lnum and same_file(r.file, file) then
			return i, comps, scope
		end
	end
end

--- The edits renaming the section at `lnum` of `file` to `new`:
--- { title = { file, lnum, line }, links = { { file, lnum, line } ... }, count }
--- Nothing is written.
function M.plan(file, lnum, new)
	local doc = workspace.document(file)
	local node, err = M.section(doc, lnum)
	if not node then
		return nil, err
	end
	new = vim.trim(new or "")
	if new == "" then
		return nil, "empty title"
	end
	local title = M.retitle(doc.lines[lnum], node.text, new)
	if not title then
		return nil, "can't find the title in its line"
	end
	local text = link_mod.component_text(new)
	local sigil = SIGIL[node.type]

	-- Old link text -> new, line by line (several links can share a line)
	local by_line, order = {}, {}
	for _, ref in ipairs(require("zortex.core.link_index").references(file, node.start_line, node.end_line)) do
		local i, comps, scope = component_at(ref.definition, ref.file, ref.lnum, file, lnum)
		if i then
			local old = comps[i]
			local kept = old:sub(2):gsub("^ ", ""):lower()
			-- a component of another kind (a %query landing on the line) is left
			-- alone; one that is still a prefix of the new title still finds it
			if old:sub(1, 1) == sigil and (kept == "" or text:lower():sub(1, #kept) ~= kept) then
				comps[i] = sigil .. text
				local def = (scope == "local" and "/" or "") .. table.concat(comps, "/")
				local key = ref.file .. ":" .. ref.lnum
				if not by_line[key] then
					by_line[key] = { file = ref.file, lnum = ref.lnum, subs = {} }
					order[#order + 1] = key
				end
				table.insert(by_line[key].subs, { col = ref.col, old = ref.definition, new = def })
			end
		end
	end

	local links, count = {}, 0
	for _, key in ipairs(order) do
		local l = by_line[key]
		local line = workspace.get_lines(l.file)[l.lnum]
		if same_file(l.file, file) and l.lnum == lnum then
			line = title
		end
		table.sort(l.subs, function(a, b)
			return a.col > b.col
		end)
		for _, sub in ipairs(l.subs) do
			-- the definition starts after "[" (or "![")
			local at = line:find(sub.old, sub.col, true)
			if at then
				line = line:sub(1, at - 1) .. sub.new .. line:sub(at + #sub.old)
				count = count + 1
			end
		end
		links[#links + 1] = { file = l.file, lnum = l.lnum, line = line }
	end
	return { title = { file = file, lnum = lnum, line = title }, links = links, count = count, node = node, new = new }
end

-- The notes a plan changes, the title's first
local function plan_files(plan)
	local files, seen = {}, {}
	for _, e in ipairs({ plan.title, unpack(plan.links) }) do
		local p = vim.fn.fnamemodify(e.file, ":p")
		if not seen[p] then
			seen[p] = true
			files[#files + 1] = p
		end
	end
	return files
end

--- Apply a plan: the title, then the links, as one batch (core/workspace):
--- notes that aren't open are loaded, edited and saved, and :ZortexUndo
--- takes the whole rename back. Returns how many notes changed, or nil and
--- an error (a note changed since the plan was made: nothing more written).
function M.apply(plan)
	local files = plan_files(plan)
	local ok, err = workspace.batch("rename to " .. vim.trim(plan.new or ""), files, function()
		local ok1, err1 = workspace.set_line(plan.title.file, plan.title.lnum, plan.title.line)
		if not ok1 then
			return false, err1
		end
		for _, e in ipairs(plan.links) do
			local ok2, err2 = workspace.set_line(e.file, e.lnum, e.line)
			if not ok2 then
				return false, err2
			end
		end
		return true
	end)
	if not ok then
		return nil, err
	end
	return #files
end

--- Ask before a rename that changes other notes: what changes, where (and
--- which of those notes aren't open), with Rename / List / Cancel. List puts
--- the changed lines in the quickfix list and asks again. Returns true to go
--- ahead. Tests replace it.
function M.ask(plan, old)
	local files = plan_files(plan)
	local here = vim.fn.fnamemodify(plan.title.file, ":p")
	if #files == 1 and files[1] == here then
		return true -- only this note: plain undo covers it
	end
	local closed = 0
	for _, f in ipairs(files) do
		local b = vim.fn.bufnr(f)
		if b <= 0 or not vim.api.nvim_buf_is_loaded(b) then
			closed = closed + 1
		end
	end
	local lines = {
		string.format(
			"Rename %q to %q: %d link%s in %d note%s%s.",
			old,
			vim.trim(plan.new or ""),
			plan.count,
			plan.count == 1 and "" or "s",
			#files,
			#files == 1 and "" or "s",
			closed > 0 and string.format(" (%d not open: loaded, changed and saved)", closed) or ""
		),
		"",
	}
	for i, e in ipairs(plan.links) do
		if i > 8 then
			lines[#lines + 1] = string.format("… and %d more", #plan.links - 8)
			break
		end
		lines[#lines + 1] = string.format("%s:%d  %s", vim.fn.fnamemodify(e.file, ":t"), e.lnum, vim.trim(e.line))
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = ":ZortexUndo takes it back afterwards."
	while true do
		local choice = vim.fn.confirm(table.concat(lines, "\n"), "&Rename\n&List\n&Cancel", 1)
		if choice == 1 then
			return true
		elseif choice == 2 then
			local items = { { filename = plan.title.file, lnum = plan.title.lnum, text = "title → " .. vim.trim(plan.title.line) } }
			for _, e in ipairs(plan.links) do
				items[#items + 1] = { filename = e.file, lnum = e.lnum, text = vim.trim(e.line) }
			end
			vim.fn.setqflist({}, "r", { title = "Rename: the lines as they will read", items = items })
			vim.cmd("copen")
			vim.cmd("redraw")
		else
			return false
		end
	end
end

--- :ZortexRename [new title]: rename the section under the cursor.
function M.rename_current(args)
	local doc = require("zortex.core.document").from_buffer(0)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local node = doc and (doc:node_starting_at(lnum) or doc:node_at(lnum))
	if not node or not SIGIL[node.type] then
		return notify("Put the cursor on a heading, bold heading or label", vim.log.levels.WARN)
	end
	local file = vim.api.nvim_buf_get_name(0)
	local function run(new)
		if not new or vim.trim(new) == "" or vim.trim(new) == node.text then
			return
		end
		local plan, err = M.plan(file, node.start_line, new)
		if not plan then
			return notify("Rename: " .. err, vim.log.levels.ERROR)
		end
		if not M.ask(plan, node.text) then
			return notify("Rename cancelled")
		end
		local files, aerr = M.apply(plan)
		if not files then
			return notify("Rename: " .. aerr .. " (:ZortexUndo takes back what was written)", vim.log.levels.ERROR)
		end
		notify(
			string.format(
				"Renamed to %s; %d link%s rewritten in %d note%s%s",
				vim.trim(new),
				plan.count,
				plan.count == 1 and "" or "s",
				files,
				files == 1 and "" or "s",
				files > 1 and " · :ZortexUndo takes it back" or ""
			)
		)
	end
	local given = args and args.args
	if given and given ~= "" then
		return run(given)
	end
	vim.ui.input({ prompt = "Rename to: ", default = node.text }, run)
end

return M
