let s:zortex_root_dir = expand('<sfile>:h:h:h')

function! health#zortex#check() abort
  call health#report_info('Platform: ' . zortex#util#get_platform())
  let l:info = system('nvim --version')
  call health#report_info('Nvim Version: '. split(l:info, '\n')[0])
  let l:zortex_server_script = s:zortex_root_dir . '/app/bin/zortex-' . zortex#util#get_platform()
  if executable(l:zortex_server_script)
    call health#report_info('Pre build: ' . l:zortex_server_script)
    call health#report_info('Pre build version: ' . zortex#util#pre_build_version())
    call health#report_ok('Using pre build')
  elseif executable('node')
    call health#report_info('Node version: ' . system('node --version'))
    let l:zortex_server_script = s:zortex_root_dir . '/app/local.js'
    call health#report_info('Script: ' . l:zortex_server_script)
    call health#report_info('Script exists: ' . filereadable(l:zortex_server_script))
    call health#report_ok('Using node')
  endif
endfunction
