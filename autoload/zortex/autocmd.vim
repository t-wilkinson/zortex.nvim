" init preview key action
function! zortex#autocmd#init() abort
  execute 'augroup ZORTEX_REFRESH_INIT' . bufnr('%')
    autocmd!
    " refresh autocmd
    if g:zortex_refresh_slow
      autocmd CursorHold,BufWrite,InsertLeave <buffer> call zortex#rpc#preview_refresh()
    else
      autocmd CursorHold,CursorHoldI,CursorMoved,CursorMovedI <buffer> call zortex#rpc#preview_refresh()
    endif
    " autoclose autocmd
    if g:zortex_auto_close
      autocmd BufHidden <buffer> call zortex#rpc#preview_close()
    endif
    " server close autocmd
    autocmd VimLeave * call zortex#rpc#stop_server()
  augroup END
endfunction

function! zortex#autocmd#clear_buf() abort
  execute 'autocmd! ' . 'ZORTEX_REFRESH_INIT' . bufnr('%')
endfunction
