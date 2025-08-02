let g:zortex_root_dir = expand('<sfile>:p:h:h')

function! s:init_variables()
  function s:def_value(name, value)
      if !exists('g:zortex_' . a:name)
          let g:['zortex_' . a:name] = a:value
      endif
  endfunction

  call s:def_value('auto_start_server', 0)

  " set to 1, the vim will open the preview window once enter the markdown
  " buffer
  call s:def_value('auto_start_preview', 1)

  " set to 1, the vim will auto open preview window when you edit the
  " markdown file

  " set to 1, the vim will auto close current preview window when change
  " from markdown buffer to another buffer
  call s:def_value('auto_close', 1)

  " set to 1, the vim will just refresh markdown when save the buffer or
  " leave from insert mode, default 0 is auto refresh markdown as you edit or
  " move the cursor
  call s:def_value('refresh_slow', 0)

  " set to 1, the ZortexPreview command can be use for all files,
  " by default it just can be use in markdown file
  call s:def_value('command_for_global', 0)

  " set to 1, preview server available to others in your network
  " by default, the server only listens on localhost (127.0.0.1)
  call s:def_value('open_to_the_world', 0)

  " use custom ip to open preview page
  " default empty
  call s:def_value('open_ip', '')

  " set to 1, echo preview page url in command line when open preview page
  " default is 0
  call s:def_value('echo_preview_url', 0)

  " use custom vim function to open preview page
  " this function will receive url as param
  call s:def_value('browserfunc', '')

  " specify browser to open preview page
  " make sure to escape spaces with '\ '
  call s:def_value('browser', '')

  if !exists('g:zortex_preview_options')
      " options for markdown render
      " mkit: markdown-it options for render
      " katex: katex options for math
      " uml: markdown-it-plantuml options
      " maid: mermaid options
      " disable_sync_scroll: if disable sync scroll, default 0
      " sync_scroll_type: 'middle', 'top' or 'relative', default value is 'middle'
      "   middle: mean the cursor position alway show at the middle of the preview page
      "   top: mean the vim top viewport alway show at the top of the preview page
      "   relative: mean the cursor position alway show at the relative positon of the preview page
      " hide_yaml_meta: if hide yaml metadata, default is 1
      " sequence_diagrams: js-sequence-diagrams options
      " content_editable: if enable content editable for preview page, default: v:false
      " disable_filename: if disable filename header for preview page, default: 0
      let g:zortex_preview_options = {
                  \ 'mkit': {},
                  \ 'katex': {},
                  \ 'uml': {},
                  \ 'maid': {},
                  \ 'disable_sync_scroll': 0,
                  \ 'sync_scroll_type': 'middle',
                  \ 'hide_yaml_meta': 1,
                  \ 'sequence_diagrams': {},
                  \ 'flowchart_diagrams': {},
                  \ 'content_editable': v:false,
                  \ 'disable_filename': 0,
                  \ 'toc': {}
                  \ }
  elseif !has_key(g:zortex_preview_options, 'disable_filename')
      let g:zortex_preview_options['disable_filename'] = 0
  endif

  " markdown css file absolute path
  call s:def_value('markdown_css', '')

  " highlight css file absolute path
  call s:def_value('highlight_css', '')

  call s:def_value('port', '8080')

  " preview page title
  " ${name} will be replace with the file name
  call s:def_value('page_title', '「${name}」')

  " recognized filetypes
  call s:def_value('filetypes', ['zortex', 'zx'])

  " where are notes found? given path should end not with '/'
  " TODO: if it ends with '/', remove it
  let g:zortex_notes_dir = get(g:, 'zortex_notes_dir', $HOME . '/.zortex') . '/'
  let g:zortex_bin_dir = expand('<sfile:p:h:h>') . '/'

  " default zortex filetype
  call s:def_value('filetype', 'zortex')

  " zortex file extension
  call s:def_value('extension', '.zortex')

  " temporary buffer created to show zortex structure
  call s:def_value('temporary_buffer_name', 'zortex-structures')

  " directory where resources are downloaded
  " call s:def_value('resources_download', $HOME . '/Downloads/zortex_resources')

  " FZF window settings
  call s:def_value('window_direction', 'down')
  call s:def_value('window_width', '40%')
  call s:def_value('window_command', '')
  call s:def_value('preview_direction', 'right')

  let g:zortex_wrap_preview_text = get(g:, 'zortex_wrap_preview_text', 0) ? 'wrap' : ''
  let g:zortex_show_preview = get(g:, 'zortex_show_preview', 1) ? '' : 'hidden'
  let g:zortex_use_ignore_files = get(g:, 'zortex_use_ignore_files', 1) ? '' : '--no-ignore'
  let g:zortex_include_hidden = get(g:, 'zortex_include_hidden', 0) ? '--hidden' : ''
  let g:zortex_preview_width = exists('g:zortex_preview_width') ? string(float2nr(str2float(g:zortex_preview_width) / 100.0 * &columns)) : ''
endfunction

function! s:init_commands() abort
    " Server management
    " command! ZortexStartServer call zortex#util#try_start_server()
    " command! ZortexStopServer call zortex#rpc#stop_server()
    " command! ZortexRestartServer call zortex#util#restart_server()
    " command! -buffer ZortexPreview call zortex#util#open_preview_page()
    " command! -buffer ZortexPreviewStop call zortex#util#stop_preview()
    " command! -buffer ZortexPreviewToggle call zortex#util#toggle_preview()

    " command! ZortexStartRemoteServer call zortex#remote#start_server()
    " command! ZortexRestartRemoteServer call zortex#remote#restart_server()
    " command! ZortexSyncRemoteServer call zortex#remote#sync()

    command! ZortexFoldsReload call zortex#fold#update_folds()
endfunction

function! s:init_autocommands()
  autocmd Filetype zortex call zortex#fold#init()

  " augroup zortex_auto_reload_folds
  "   autocmd!
  "   autocmd BufWritePost *.zortex call zortex#fold#update_folds()
  " augroup END

  augroup zortex_init
      autocmd!
      autocmd BufEnter * :call s:init_commands()

      " if g:zortex_command_for_global
      " else
      "     autocmd BufEnter,FileType * if index(g:zortex_filetypes, &filetype) !=# -1 | call s:init_command() | endif
      " endif
      " if g:zortex_auto_start_server
      "     call zortex#util#try_start_server()
      " endif
      " if g:zortex_auto_start_preview
      "     execute 'autocmd BufEnter *.{' . join(g:zortex_filetypes, ',') . '} call zortex#autocmd#init()'
      " endif
  augroup END
endfunction

function! zortex#legacy#init()
  " call s:init_variables()
  call s:init_commands()
  call s:init_autocommands()
endfunction

