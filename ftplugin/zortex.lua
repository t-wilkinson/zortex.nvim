-- ftplugin/zortex.lua - Filetype-specific settings for Zortex
local zortex = require("zortex")

-- Initialize folding for this buffer
-- require('zortex.core.fold').init()

-- Apply syntax highlighting
require("zortex.features.highlights").highlight_buffer()

-- Buffer-local options
vim.bo.iskeyword = vim.bo.iskeyword .. ",-" -- Add dash to word characters
vim.wo.foldlevel = 1 -- Start with folds open to level 1
vim.bo.tabstop = 4 -- Tab width
vim.bo.softtabstop = 4 -- Soft tab width
vim.bo.shiftwidth = 4 -- Indent width
vim.wo.wrap = true -- Enable line wrapping
vim.wo.breakindent = true -- Indent wrapped lines

vim.bo.comments = ""

-- Additional useful settings for note-taking
vim.bo.expandtab = true -- Use spaces instead of tabs
vim.bo.textwidth = 0 -- No automatic line breaking
vim.wo.linebreak = true -- Break at word boundaries
vim.wo.list = false -- Don't show listchars in zortex files
