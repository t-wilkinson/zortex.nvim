-- ui/picker/snacks.lua - The picker interface (ui/picker) on snacks.picker
--
-- snacks' own keys open: <CR>, <C-s> split, <C-v> vsplit, <C-t> tab; <Tab>
-- selects several; <C-q> sends the selection (or every row) to the quickfix
-- list. Live lists run on what you type and keep their own order.
local Picker = require("zortex.ui.picker")

local M = {}

local CMD = { split = "split", vsplit = "vsplit", tab = "tabedit", drop = "edit", tabdrop = "tabedit" }

local function to_items(spec, list)
	local out = {}
	for i, item in ipairs(list) do
		local loc = spec.location(item)
		out[i] = {
			idx = i,
			text = spec.query and "" or Picker.text(spec, item),
			file = loc.file,
			pos = { loc.lnum or 1, math.max((loc.col or 1) - 1, 0) },
			zortex = item,
		}
	end
	return out
end

local function values(items)
	return vim.tbl_map(function(i)
		return i.zortex
	end, items)
end

function M.pick(spec)
	local Snacks = require("snacks")
	local actions = {
		confirm = function(picker, _, action)
			local items = values(picker:selected({ fallback = true }))
			picker:close()
			Picker.confirm(spec, items, CMD[action and action.cmd or ""] or "edit")
		end,
		qflist = function(picker)
			local sel = picker:selected()
			local items = values(#sel > 0 and sel or picker:items())
			picker:close()
			if #items > 0 then
				Picker.quickfix(spec, items)
			end
		end,
	}
	local keys = {}
	for i, k in ipairs(Picker.keys(spec)) do
		local name = "zortex_" .. i
		actions[name] = {
			desc = k.key.desc,
			action = function(picker, item)
				local c = {
					prompt = picker.input:get(),
					refresh = function()
						picker.title = Picker.title(spec, "snacks")
						picker:refresh()
						picker:update_titles()
					end,
				}
				if k.key.close then
					picker:close()
					c.refresh = nil
				end
				Picker.run_key(k.key, item and item.zortex, c)
			end,
		}
		keys[k.lhs] = { name, mode = { "i", "n" }, desc = k.key.desc }
	end

	return Snacks.picker.pick({
		source = "zortex",
		title = Picker.title(spec, "snacks"),
		search = spec.query and spec.prompt or nil,
		pattern = not spec.query and spec.prompt or nil,
		live = spec.query ~= nil,
		finder = function(_, ctx)
			if spec.query then
				return to_items(spec, spec.query(ctx.filter.search or ""))
			end
			return to_items(spec, spec.items())
		end,
		format = function(item)
			local out = {}
			for _, seg in ipairs(spec.format(item.zortex)) do
				if seg[1] and seg[1] ~= "" then
					out[#out + 1] = { seg[1], seg[2] }
				end
			end
			return out
		end,
		preview = spec.preview and function(ctx)
			ctx.preview:reset()
			local p = Picker.fill_preview(spec, ctx.item.zortex, ctx.buf, ctx.win)
			ctx.preview:set_title(p and p.title or "")
		end or "none",
		matcher = { sort_empty = false },
		sort = { fields = { "score:desc", "idx" } },
		actions = actions,
		confirm = actions.confirm,
		win = { input = { keys = keys }, list = { keys = keys } },
	})
end

return M
