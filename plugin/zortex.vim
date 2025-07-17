if exists('g:zortex_loaded') | finish | endif

lua require('zortex')

let g:zortex_loaded = 1

call zortex#legacy#init()
