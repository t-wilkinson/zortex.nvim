"============================  Helpers ==============================

let s:listitemRE = '^\(\s*\)- \(#.*#\)\? \?\(.*\)$' " ____-_Line
let s:zettelRE = '^\[z:.*] #.\{-}# {\(.*\);\?}'

function! s:normalize_article_name(name)
    let name = trim(a:name)
    let name = substitute(l:name, '\s\+', '-', 'g')
    let names = split(l:name, ' == ')
    let names = map(l:names, 'trim(v:val, " []")')
    return l:names
endfunction

function! s:article_names_match(n1, n2)
    let ns1 = s:normalize_article_name(a:n1)
    let ns2 = s:normalize_article_name(a:n2)
    for n1 in l:ns1
        if index(l:ns2, n1, 0, v:true) > -1
            return 1
        endif
    endfor
    return 0
endfunction

"=========================== Manage articles ========================================

function! s:new_filepath()
    return g:zortex_notes_dir . strftime("%Y%W%u%H%M%S") . g:zortex_extension " YYYYWWDHHMMSS.zortex
endfunction

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

function! s:get_url_title(url)
    if a:url !~ '^https\?://'
        return ''
    endif

    let title = system("python3 -c \"import bs4, requests; print(bs4.BeautifulSoup(requests.get('" . a:url . "').content, 'lxml').title.text.strip())\"")

    if v:shell_error != 0
        return ''
    endif

    return substitute(l:title, '\n', '', 'g')
endfunction
