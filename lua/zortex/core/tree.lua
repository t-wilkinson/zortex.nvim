-- core/tree.lua - Structural tree access by file path
--
-- Thin facade over core/document: trees are cached per file (validated by
-- mtime) there, so every consumer shares one parse. Trees are shared and must
-- be treated as read-only; anything that mutates nodes must call M.invalidate.
local M = {}

local Document = require("zortex.core.document")

function M.get_tree(filepath)
	local doc = Document.get(filepath)
	return doc and doc.tree or nil
end

function M.invalidate(filepath)
	Document.invalidate(filepath)
end

-- All nodes (excluding the root) matching `query_fn`, depth-first.
function M.search_nodes(tree, query_fn)
	return tree:filter(query_fn)
end

function M.setup()
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "*.zortex",
		callback = function(args)
			Document.invalidate(args.file)
			require("zortex.core.notes").invalidate()
		end,
	})
end

return M
