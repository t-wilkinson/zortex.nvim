let s:zortex_root_dir = expand('<sfile>:h:h:h')
let s:zortex_opts = {}
let s:is_vim = !has('nvim')
let s:zortex_channel_id = s:is_vim ? v:null : -1

function! s:on_stdout(chan_id, msgs, ...) abort
  call zortex#util#echo_messages('Error', a:msgs)
endfunction
function! s:on_stderr(chan_id, msgs, ...) abort
  call zortex#util#echo_messages('Error', a:msgs)
endfunction
function! s:on_exit(chan_id, code, ...) abort
  let s:zortex_channel_id = s:is_vim ? v:null : -1
endfunction

function! s:start_vim_server(cmd) abort
  let options = {
        \ 'in_mode': 'json',
        \ 'out_mode': 'json',
        \ 'err_mode': 'nl',
        \ 'out_cb': function('s:on_stdout'),
        \ 'err_cb': function('s:on_stderr'),
        \ 'exit_cb': function('s:on_exit'),
        \ 'env': {
        \   'VIM_NODE_RPC': 1,
        \ }
        \}
  if has("patch-8.1.350")
    let options['noblock'] = 1
  endif
  let l:job = job_start(a:cmd, options)
  let l:status = job_status(l:job)
  if l:status !=# 'run'
    echohl Error | echon 'Failed to start vim-node-rpc service' | echohl None
    return
  endif
  let s:zortex_channel_id = l:job
endfunction

function! zortex#rpc#start_server() abort
  let l:zortex_server_script = s:zortex_root_dir . '/app/bin/load-' . zortex#util#get_platform()
  if executable('node')
    let l:zortex_server_script = s:zortex_root_dir . '/app/lib/bin/load.js'
    let l:cmd = ['node', l:zortex_server_script, '--path', s:zortex_root_dir . '/app/lib/bin/local.js']
  elseif executable(l:zortex_server_script)
    let l:cmd = [l:zortex_server_script, '--path', s:zortex_root_dir . '/app/lib/bin/local.js']
  endif

  if exists('l:cmd')
    if s:is_vim
      call s:start_vim_server(l:cmd)
    else
      let l:nvim_optons = {
            \ 'rpc': v:true,
            \ 'on_stdout': function('s:on_stdout'),
            \ 'on_stderr': function('s:on_stderr'),
            \ 'on_exit': function('s:on_exit')
            \ }
      let s:zortex_channel_id = jobstart(l:cmd, l:nvim_optons)
    endif
  else
    call zortex#util#echo_messages('Error', 'Pre build and node is not found')
  endif
endfunction

function! zortex#rpc#stop_server() abort
  if s:is_vim
    if s:zortex_channel_id !=# v:null
      let l:status = job_status(s:zortex_channel_id)
      if l:status ==# 'run'
        call zortex#rpc#request(s:zortex_channel_id, 'close_all_pages')
        try
          call job_stop(s:zortex_channel_id)
        catch /.*/
        endtry
      endif
    endif
    let s:zortex_channel_id = v:null
  else
    if s:zortex_channel_id !=# -1
      call rpcrequest(s:zortex_channel_id, 'close_all_pages')
      try
        call jobstop(s:zortex_channel_id)
      catch /.*/
      endtry
    endif
    let s:zortex_channel_id = -1
  endif
  let b:ZortexPreviewToggleBool = 0
endfunction

function! zortex#rpc#close_pages() abort
  if s:is_vim
    if s:zortex_channel_id !=# v:null
      let l:status = job_status(s:zortex_channel_id)
      if l:status ==# 'run'
        call zortex#rpc#request(s:zortex_channel_id, 'close_all_pages')
      endif
    endif
    let s:zortex_channel_id = v:null
  else
    if s:zortex_channel_id !=# -1
      call rpcrequest(s:zortex_channel_id, 'close_all_pages')
    endif
    let s:zortex_channel_id = -1
  endif
  let b:ZortexPreviewToggleBool = 0
endfunction

" returns 1 if server is running and -1 otherwise
function! zortex#rpc#get_server_status() abort
  if s:is_vim && s:zortex_channel_id ==# v:null
    return -1
  elseif !s:is_vim && s:zortex_channel_id ==# -1
    return -1
  endif
  if system('fuser '.g:zortex_port.'/tcp') != ''
      return 1
  endif
  return 1
endfunction

function! zortex#rpc#preview_refresh() abort
  if s:is_vim
    if s:zortex_channel_id !=# v:null
      call zortex#rpc#notify(s:zortex_channel_id, 'refresh_content', { 'bufnr': bufnr('%') })
    endif
  else
    if s:zortex_channel_id !=# -1
      call rpcnotify(s:zortex_channel_id, 'refresh_content', { 'bufnr': bufnr('%') })
    endif
  endif
endfunction

function! zortex#rpc#preview_close() abort
  if s:is_vim
    if s:zortex_channel_id !=# v:null
      call zortex#rpc#notify(s:zortex_channel_id, 'close_page', { 'bufnr': bufnr('%') })
    endif
  else
    if s:zortex_channel_id !=# -1
      call rpcnotify(s:zortex_channel_id, 'close_page', { 'bufnr': bufnr('%') })
    endif
  endif
  let b:ZortexPreviewToggleBool = 0
  call zortex#autocmd#clear_buf()
endfunction

function! zortex#rpc#open_browser() abort
  if s:is_vim
    if s:zortex_channel_id !=# v:null
      call zortex#rpc#notify(s:zortex_channel_id, 'open_browser', { 'bufnr': bufnr('%') })
    endif
  else
    if s:zortex_channel_id !=# -1
      call rpcnotify(s:zortex_channel_id, 'open_browser', { 'bufnr': bufnr('%') })
    endif
  endif
endfunction

function! zortex#rpc#request(clientId, method, ...) abort
  let args = get(a:, 1, [])
  let res = ch_evalexpr(a:clientId, [a:method, args], {'timeout': 5000})
  if type(res) == 1 && res ==# '' | return '' | endif
  let [l:errmsg, res] =  res
  if l:errmsg
    echohl Error | echon '[rpc.vim] client error: '.l:errmsg | echohl None
  else
    return res
  endif
endfunction

function! zortex#rpc#notify(clientId, method, ...) abort
  let args = get(a:000, 0, [])
  " use 0 as vim request id
  let data = json_encode([0, [a:method, args]])
  call ch_sendraw(s:zortex_channel_id, data."\n")
endfunction
