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

"============================ Article mangement helper functions ==============================

" Update active buffers
function! s:redraw_file(filename, ...)
    let curwinid = get(a:, 1, win_getid())
    let winid = bufwinid(bufname(a:filename))
    if winid != -1
        call win_gotoid(winid)
        edit
        call win_gotoid(curwinid)
    endif
endfunction

" function! s:file_basename(filename)
"     return matchlist(a:filename, '\d*'.g:zortex_extension.'$')[0]
" endfunction

function! s:is_empty(string)
    return match(a:string, "^$") > -1
endfunction

function! s:clean_tag(tag)
    return substitute(a:tag, '^\s*\(.\{-}\)\((.*)\)\?\s*$', '\1', '')
endfunction

function! s:is_tag(string)
    return match(a:string, "@") > -1
endfunction

function! s:remove_tag(string)
    return substitute(a:string, "@", "","g") > -1
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

function! s:get_branch() abort
    " might be better to read/write current buffer
    let cur_line = getline('.')
    let cur_lnum = line('.')
    let cur_indent = indent(cur_lnum)
    let lines = []

    " Cut branch
    for i in range(cur_lnum, line('$'))
        exec 'norm "_dd'
        if indent(cur_lnum) <= cur_indent
            break
        endif
        call add(lines, getline(cur_lnum))
    endfor

    return #{ tag: s:tagify(cur_line), lines: lines }
endfunction

"============================== Handler functions ===========================

function! zortex#article#handler(lines) abort
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

function! s:branch_note_handler(lines) abort
    let branch = s:get_branch()
    let f_tags = s:extract_file_tags(readfile(bufname()))

    let f_path = s:new_filepath()
    execute s:keypress_command() f_path

    call append(0, add(f_tags, branch.tag))
    call append('$', branch.lines)
    exec "norm gg<G"
endfunction

" function! s:branch_note(...) abort
"     let keypress = get(a:, 1, 0)
"     let f_tags = s:extract_file_tags(readfile(bufname()))
"     let f_path = s:new_filepath()
"     execute s:keypress_command(keypress) f_path
"     call append(0, f_tags)
"     call cursor('$', 1)
"     " startinsert
" endfunction

" function! s:remove_tag_from_notes(req) abort
"     let tag = input('please enter tag (including @): ')
"     if tag == '' | return | endif
"     let RemoveTag = {line->substitute(line,
"                     \ '\s*'.tag,
"                     \ '',
"                     \ 'g')}
"     for [basename, filebody] in a:req.previewbodies
"         if len(filebody) == 0 | continue | endif
"         " NOTE: You COULD use the following line but it only applies to a few situations and has a dramatic slowdown
"         " call map(filebody, RemoveTag)
"         let filebody[0] = RemoveTag(filebody[0])
"         call writefile(filebody, g:zortex_notes_dir . basename)
"         call s:redraw_file(g:zortex_notes_dir . basename)
"     endfor
" endfunction

" function! s:add_tag_to_notes(req) abort
"     let tag = input('please enter tag (including @): ')
"     if tag == '' | return | endif
"     for [basename, filebody] in a:req.previewbodies
"         let filebody[0] = filebody[0].' '.l:tag
"         call writefile(filebody, g:zortex_notes_dir . basename)
"         call s:redraw_file(g:zortex_notes_dir . basename)
"     endfor
" endfunction

"=========================== Keymap ========================================
" unusable  : a c e m n p u w y
" iffy      : j k l
" usable    : b f g h q s v z t r
" in use    : d o

" " t=tag → tag files
" let s:tag_note_key = get(g:, 'zortex_tag_note_key', 'ctrl-t')
"
" " r=remove link → unlink buffer with selection list
" let s:remove_tags_key = get(g:, 'zortex_remove_tag_key', 'ctrl-r')

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

"============================  Zortex functions ==============================

let s:listitemRE = '^\s*- \(#.*#\)\? \?\(.*\)$' " ____-_Line
let s:resourceRE = '\[\(.*\)\(:.*\)\?\%( - \)\?\(.*\)](\(.*\))' " [title: subtitle - authors](ref.extension)

function! s:zettel_id()
    let rand_str = printf("%05d", rand() % 100000)
    return strftime("z:%H%M.%u%U%g." . rand_str)
endfunction

" Parse structures file
function s:get_zortex_structures()
    let l:lines = readfile(g:zortex_notes_dir . '/structure' . g:zortex_extension)
    let l:structures = {}
    let l:structure_indent = 0
    let l:structure = ''

    for line in l:lines
        let l:m = matchlist(line, '^\(\s*\)\(\*\|-\) \(.\{-}\)\( #.*#\)\?$')
        if len(l:m) == 0
            if line != ''
                " use to debug why some lines aren't added to structures
                " echo line
            endif
            continue
        endif

        let l:indent = len(l:m[1])
        let l:item = l:m[2]
        let l:text = l:m[3]

        if l:item == '*'
            let l:structure = l:text
            let l:structure_indent = l:indent
            let l:structures[l:structure] = []
            continue
        endif

        if l:structure != '' && l:item == '-' && l:indent > l:structure_indent
            let l:structures[l:structure] += [ { "text": l:text, "indent": l:indent - l:structure_indent } ]
        endif
    endfor

    return l:structures
endfunction

function! s:normalize_article_name(name)
    let l:name = trim(a:name)
    let l:name = substitute(l:name, '\s\+', '-', 'g')
    let l:names = split(l:name, ' == ')
    let l:names = map(l:names, 'trim(v:val, " []")')
    return l:names
endfunction

function! s:article_names_match(n1, n2)
    let l:ns1 = s:normalize_article_name(a:n1)
    let l:ns2 = s:normalize_article_name(a:n2)
    for n1 in l:ns1
        if index(l:ns2, n1, 0, v:true) > -1
            return 1
        endif
    endfor
    return 0
endfunction


"=========================== Functions ========================================

function! zortex#article#branch_to_article()
    let currentLine = getpos('.')[1]
    let totalIndent = indent(currentLine)
    let eof = line('$')
    let lines = []
    " backup +"0 buffers

    " Convert line cursor is on to a zettel
    let lines += [ substitute(getline(currentLine), '^\s*- \(.*\)$', '@@\1', ''), '' ]
    norm! dd

    " De-indent each line until we are out of the branch note
    while line('$') != eof
        let line = getline(currentLine)

        if line == ''
            norm! dd
            continue
        endif
        let m = matchlist(line, '^\(\s*\)- \(.*\)$')
        if len(m) == 0
            norm! dd
            continue
        endif

        let currentIndent = len(m[1])
        if currentIndent <= totalIndent
            break
        endif

        norm! dd
        let newLine = substitute(line, '^' . repeat(' ', totalIndent + 4), '', '')
        let lines += [newLine]
    endwhile

    let f_path = s:new_filepath()
    execute s:keypress_command() f_path
    call setline(1, lines)
    norm! w
endfunction

function! zortex#article#branch_to_outline()
    let currentLine = getpos('.')[1]
    let matchIndent = 0
    let totalIndent = indent(currentLine)
    let eof = line('$')

    " Convert line cursor is on to a zettel
    call setline(currentLine, substitute(getline(currentLine), '^\s*- \zs.*$', '#\0#outline#', ''))
    call zortex#article#listitem_to_zettel()

    " De-indent each line until we are out of the branch note
    while !matchIndent && currentLine != eof + 1 && currentLine != -1
        let currentLineText = getline(currentLine)
        let newIndent = substitute(currentLineText, '^' . repeat(' ', totalIndent), '', '')
        call setline(currentLine, newIndent)
        let currentLine += 1
        let matchIndent = indent(currentLine) <= totalIndent && currentLineText != ''
    endwhile
endfunction

function! zortex#article#copy_zettel_id()
    let line = getline(".")
    let zettel_id = substitute(line, "] #.*$", "]", "")
    let @+ = zettel_id
endfunction

function! zortex#article#copy_zettel()
    let line = getline(".")
    let line = substitute(line, "# .*$", "# ", "")
    let @+ = line . "\n"
endfunction

" Convert ``   - Line`` to a zettel
function! zortex#article#listitem_to_zettel()
    let l:line = getline(".")

    let l:m = matchlist(l:line, s:listitemRE)
    if len(l:m) == 0
        return
    endif

    let l:id = s:zettel_id()
    let l:tags = l:m[1] ? " ".l:m[1] : ""
    let l:lineitem = l:m[2] ? " ".l:m[2] : ""
    call setline(".", "[" . l:id "]" . l:tags . l:lineitem)
endfunction

" Convert [title: subtitle - authors](ref.extension) to a zettel
function! zortex#article#resource_to_zettel(...)
    let l:line = getline(".")
    let l:m = matchlist(l:line, s:resourceRE)
    if len(l:m) == 0
        return
    endif

    let l:title = l:m[1]
    let l:subtitle = l:m[2] ? printf('subtitle=%s; ', l:m[2]) : ""
    let l:authors = join(map(split(l:m[3], ","), '"author=".trim(v:val).";"' ), " ")
    let l:ref = l:m[4]
    let l:extension = matchstr(l:ref, '\.\zs\w\+$')

    if len(l:ref) >= 4 && l:ref[:4] == 'http'
        let resource = ' resource=website;'
    elseif l:extension
        let resource = printf(' resource=%s;', l:extension[1])
    else
        let resource = ''
    endif

    " type = vim.eval("get(a:, 1, v:null)")
    " type = f'type={type}; ' if type else ''

    let l:type = ""
    let l:id = s:zettel_id()
    let l:line = printf("[%s] #z-source# %stitle=%s; %s%s ref=%s;%s", l:id, l:type, l:title, l:subtitle, l:authors, l:ref, l:resource)
    call setline('.', l:line)
endfunction

function! zortex#article#get_matching_structures(article_name)
    let l:structures = s:get_zortex_structures()
    let l:matching_structures = []
    for [structure, items] in items(l:structures)
        for item in items
            if s:article_names_match(a:article_name, item["text"])
                let l:matching_structures += [structure]
                break
            endif
        endfor
    endfor

    return [l:structures, l:matching_structures]
endfunction

function! zortex#article#open_structure()
    if &l:filetype != 'zortex'
        return
    endif

    let l:article_name = getline(1)[2:] " assuming @@<article_name>
    let [l:structures, l:matching_structures] = zortex#article#get_matching_structures(l:article_name)

    " Create buffer
    if bufexists(g:zortex_temporary_buffer_name)
        execute "bw! " . g:zortex_temporary_buffer_name
    endif

    vsplit
    vertical resize 50
    noswapfile hide enew
    setlocal buftype=nofile
    setlocal bufhidden=hide
    setlocal nobuflisted
    setlocal filetype=zortex
    execute "file! " . g:zortex_temporary_buffer_name

    " Fill buffer
    function! RenderStructure(structures, structure)
        let l:lines = [printf("- %s", a:structure)]
        for item in a:structures[a:structure]
            let l:indent = item["indent"]
            let l:text = item["text"]
            let l:line = printf("%s- %s", repeat(" ", l:indent), l:text)
            let l:lines += [l:line]
        endfor
        return l:lines
    endfunction

    let l:lines = []
    for structure in l:matching_structures
        let l:lines += RenderStructure(l:structures, structure) + [""]
    endfor

    call append(0, l:lines)
    call cursor(1, 1)
endfunction

function! zortex#article#LightlineZortex()
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

function! zortex#article#search()
    call fzf#run(
    \ fzf#wrap(extend(copy(s:zortex_fzf_options), {
    \ 'sink*': function(exists('*zortex_note_handler') ? 'zortex_note_handler' : 'zortex#article#handler'),
    \ 'source': s:bin.source_files,
    \ }), 1))
endfunction

function! zortex#article#search_unique()
    call fzf#run(
    \ fzf#wrap(extend(copy(s:zortex_fzf_options), {
    \ 'sink*': function(exists('*zortex_note_handler') ? 'zortex_note_handler' : 'zortex#article#handler'),
    \ 'source': join([s:bin.source_files, '-t', 'unique']),
    \ }), 1))
endfunction

