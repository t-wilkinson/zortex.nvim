"============================= Dependencies ================================


if !executable('fd') " faster and simpler find
    echoerr '`fd` is not installed. See https://github.com/sharkdp/fd for installation instructions.'
    finish
endif

if !executable('bat') " cat but with syntax highlighting
    echoerr '`bat` is not installed. See https://github.com/sharkdp/bat for installation instructions.'
    finish
endif

"============================== Settings ==============================

let s:bin_dir = expand('<sfile>:p:h').'/bin/'
let s:bin = { 'preview': s:bin_dir.'preview.sh',
            \ 'source': s:bin_dir.'source.py',
            \ 'source_files': join([s:bin_dir.'source.py', shellescape(g:zortex_notes_dir), g:zortex_extension]),
            \ }

"============================== Helpers ===========================

function! s:is_empty(string)
    return match(a:string, "^$") > -1
endfunction

function! s:extract_file_tags(lines)
    let tags = []

    for line in a:lines
        if s:is_tag(line)
            call add(tags, s:clean_tag(line))
        elseif s:is_empty(line)
            break
        endif
    endfor

    return tags
endfunction

function! zortex#search#LightlineZortex()
    let buf = bufname()
    if &filetype != g:zortex_filetype
        return ''
    elseif buf == g:zortex_temporary_buffer_name
        return 'Zortex Structures'
    elseif filereadable(buf)
        return join(s:extract_file_tags(readfile(buf)), ' ')
    else
        return ''
    endif
endfunction

" " Update active buffers
" function! s:redraw_file(filename, ...)
"     let curwinid = get(a:, 1, win_getid())
"     let winid = bufwinid(bufname(a:filename))
"     if winid != -1
"         call win_gotoid(winid)
"         edit
"         call win_gotoid(curwinid)
"     endif
" endfunction

" function! s:file_basename(filename)
"     return matchlist(a:filename, '\d*'.g:zortex_extension.'$')[0]
" endfunction

function! s:clean_tag(tag)
    return substitute(a:tag, '^\s*\(.\{-}\)\((.*)\)\?\s*$', '\1', '')
endfunction

function! s:is_tag(string)
    return match(a:string, "@") > -1
endfunction

function! s:remove_tag(string)
    return substitute(a:string, "@", "","g") > -1
endfunction

function! s:new_filepath()
    return g:zortex_notes_dir . strftime("%Y%W%u%H%M%S") . g:zortex_extension " YYYYWWDHHMMSS.zortex
endfunction

function! s:keypress_command(...)
    let keypress = get(a:, 1, 0)
    if keypress
        return get(s:commands, keypress, s:default_command)
    else
        return s:default_command
    endif
endfunction

function! s:tagify(string) abort
    let removed_bullet = substitute(a:string, "^- ", "", "")
    let title_case = substitute(removed_bullet, "\\s[A-Z]", "\\U\\0", "g")
    return '@' . title_case
endfunction

"============================== Handler functions ===========================

function! zortex#search#handler(lines) abort
    let request = s:parse_fzf_response(a:lines)
    if len(request.previewbodies) > 1
        let filelist = map(copy(request.previewbodies), '{ "filename": v:val[0], "text": s:extract_file_tags(v:val[1])[0], "lnum": 1 }')
        call setqflist(filelist, ' ')
    endif

    if empty(request.previewbodies)
        return
    else
        function! s:edit_previewbodies(req) abort
            let cmd = get(s:commands, a:req.keypress, 'edit')
            echom cmd . ' ' . g:zortex_notes_dir . a:req.previewbodies[0][0]
            execute cmd . ' ' . g:zortex_notes_dir . a:req.previewbodies[0][0]
        endfunction

        call get(s:actions, request.keypress, function("s:edit_previewbodies"))(request)
    endif

    if len(request.previewbodies) > 1
        exec 'copen'
    endif
endfunction

function! s:parse_fzf_response(lines) abort
    " Convert fzf-preview 'previewbody' to managable 'basename' and 'filebody'
    function! s:parse_previewbody(previewbody)
        let [filetime; filebody] = a:previewbody
        let TimeToBasename = {time->substitute(time, '[ :-]', '', 'g') . g:zortex_extension}
        let basename = TimeToBasename(filetime)
        return [basename, filebody]
    endfunction

    let request = {
                \ "query": a:lines[0],
                \ "keypress": a:lines[1],
                \ "previewbodies": map(a:lines[2:], 's:parse_previewbody(split(v:val, ""))'),
                \ }
    return request
endfunction

function! s:create_new_note_handler(req) abort
    let f_path = s:new_filepath()
    execute s:keypress_command(a:req.keypress) f_path
    exec "norm A@@"
endfunction

function! s:delete_notes_handler(req) abort
    " Confirm user wants to delete file
    let basenames = map(copy(a:req.previewbodies), 'v:val[0]')
    let choice = confirm("Delete " . join(basenames, ', ') . "?", "&Yes\n&No", 1)
    if choice == 2 | return | endif

    " Delete selected files and their buffers (if they are loaded)
    for basename in basenames
        let bufinfo = getbufinfo(basename)
        " Delete file buffer if exists
        if !empty(bufinfo)
            if !bufinfo[0].changed && bufinfo[0].loaded
                execute "bdelete" bufinfo[0].name
            endif
        endif
        call delete(g:zortex_notes_dir . basename)
    endfor
endfunction

"=========================== Keymap ========================================
" unusable  : a c e m n p u w y
" iffy      : j k l
" usable    : b f g h q s v z t r
" in use    : d o

" " t=tag → tag files
" let s:tag_note_key = get(g:, 'zortex_tag_note_key', 'ctrl-t')

" d=delete → delete all selected notes, asks user for confirmation
let s:delete_note_key = get(g:, 'zortex_delete_note_key', 'ctrl-d')

" o=open → create a new file
let s:new_note_key = get(g:, 'zortex_new_note_key', 'ctrl-o')

" Assign each key to a function for fzf
let s:actions = {
            \ s:delete_note_key: function("s:delete_notes_handler"),
            \ s:new_note_key: function("s:create_new_note_handler"),
            \ }
let s:commands = get(g:, 'zortex_commands', {
            \ 'ctrl-s': 'split',
            \ 'ctrl-v': 'vertical split',
            \ 'ctrl-t': 'tabedit',
            \ })
let s:keymap = extend(copy(s:commands), s:actions)

" FZF expects a comma separated string.
let s:expect_keys = join(keys(s:keymap) + get(g:, 'zortex_expect_keys', []), ',')

let s:default_command = 'edit'

let s:create_note_window = get(g:, 'zortex_create_note_window', 'edit ')

"================================= FZF ========================================

let s:fzf_options =
            \ join([
            \   '--tac',
            \   '--print-query',
            \   '--query=@@',
            \   '--cycle',
            \   '--multi',
            \   '--exact',
            \   '--inline-info',
            \   '+s',
            \   '--bind=' .  join([
            \     'alt-a:select-all',
            \     'alt-q:deselect-all',
            \     'alt-p:toggle-preview',
            \     'alt-u:page-up',
            \     'alt-d:page-down',
            \     'ctrl-w:backward-kill-word',
            \     ], ','),
            \   '--preview=' . shellescape(join([s:bin.preview, g:zortex_extension, '{}'])),
            \   '--preview-window=' . join(filter(copy([
            \       g:zortex_preview_direction,
            \       g:zortex_preview_width,
            \       g:zortex_wrap_preview_text,
            \       g:zortex_show_preview,
            \     ]),
            \   'v:val != "" ')
            \   ,':')
            \   ])

let s:zortex_fzf_options = {
            \ 'window': g:zortex_window_command,
            \ g:zortex_window_direction: g:zortex_window_width,
            \ 'options': join([
            \   s:fzf_options,
            \   '--expect=' . s:expect_keys,
            \ ]),
            \ }

function! zortex#search#search()
    call fzf#run(
    \ fzf#wrap(extend(copy(s:zortex_fzf_options), {
    \ 'sink*': function(exists('*zortex_note_handler') ? 'zortex_note_handler' : 'zortex#search#handler'),
    \ 'source': s:bin.source_files,
    \ }), 1))
endfunction

function! zortex#search#search_unique()
    call fzf#run(
    \ fzf#wrap(extend(copy(s:zortex_fzf_options), {
    \ 'sink*': function(exists('*zortex_note_handler') ? 'zortex_note_handler' : 'zortex#search#handler'),
    \ 'source': join([s:bin.source_files, '-t', 'unique']),
    \ }), 1))
endfunction
