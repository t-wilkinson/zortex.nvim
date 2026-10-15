-- features/blink.lua - The blink.cmp source: the link and @a(...) completion
-- of features/completion. features/completion.register() adds it as the
-- "zortex" provider and lists it in zortex buffers; to set it up yourself:
--
--   sources = {
--     per_filetype = { zortex = { inherit_defaults = true, "zortex" } },
--     providers = { zortex = { name = "Zortex", module = "zortex.features.blink" } },
--   }
local completion = require("zortex.features.completion")

local Source = {}
Source.__index = Source

function Source.new(opts)
	return setmetatable({ opts = opts or {} }, Source)
end

function Source:enabled()
	return completion.FILETYPES[vim.bo.filetype] == true
end

function Source:get_trigger_characters()
	return completion.TRIGGERS
end

function Source:get_completions(ctx, callback)
	local row, col = ctx.cursor[1], ctx.cursor[2]
	local items = completion.lsp_items(ctx.line:sub(1, col), row - 1, ctx.bufnr) or {}
	callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

return Source
