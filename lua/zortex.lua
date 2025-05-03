-- GOAL: press enter on [Article] and [Article/Subheading] to link to text

local M = {}

-- Function to extract the link title from the current line
local function get_link_title()
  local line = vim.api.nvim_get_current_line()
  local title = line:match("%[(.-)%]")
  return title
end

-- Function to search for files in a directory
local function search_files(directory, pattern)
  local files = {}
  local handle = io.popen('find "' .. directory .. '" -type f -name "' .. pattern .. '*"')
  if handle then
    for file in handle:lines() do
      table.insert(files, file)
    end
    handle:close()
  end
  return files
end

-- Function to display search results in a floating window
local function show_results(results)
  if #results == 0 then
    print("No matching files found.")
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = 60
  local height = #results > 10 and 10 or #results
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = 'minimal',
    border = 'rounded'
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, results)
  # vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  -- Set up keymaps for the floating window
  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set('n', '<CR>', function()
    local file = vim.api.nvim_get_current_line()
    vim.api.nvim_win_close(win, true)
    vim.cmd('edit ' .. file)
  end, opts)
  vim.keymap.set('n', 'q', function()
    vim.api.nvim_win_close(win, true)
  end, opts)
end

-- Main function to handle the Enter key press
function M.search_markdown_link()
  local title = get_link_title()
  if not title then
    print("No Markdown link found on the current line.")
    return
  end

  local directory = vim.fn.expand("%:p:h") -- Current file's directory
  local results = search_files("~/zortex", title)
  show_results(results)
end

-- Set up the keymap
vim.api.nvim_set_keymap('n', '<CR>', [[<cmd>lua require('markdown_link_search').search_markdown_link()<CR>]], { noremap = true, silent = true })

return M
