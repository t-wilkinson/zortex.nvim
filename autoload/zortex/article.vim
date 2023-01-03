"============================  Helpers ==============================

let s:listitemRE = '^\(\s*\)- \(#.*#\)\? \?\(.*\)$' " ____-_Line

function! s:zettel_id()
    let rand_str = join(systemlist("strings -n 1 < /dev/urandom | grep -o '[[:digit:]]'  | head -5"), '')[0:4]
    " let rand_str = printf("%05d", rand() % 100000)
    return strftime("z:%H%M.%u%U%g." . rand_str)
endfunction

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

" Parse structures file
function s:get_zortex_structures()
    let lines = readfile(g:zortex_notes_dir . '/structure' . g:zortex_extension)
    let structures = {}
    let structure_indent = 0
    let structure = ''

    for line in l:lines
        let m = matchlist(line, '^\(\s*\)\(\*\|-\) \(.\{-}\)\( #.*#\)\?$')
        if len(l:m) == 0
            if line != ''
                " use to debug why some lines aren't added to structures
                " echo line
            endif
            continue
        endif

        let indent = len(l:m[1])
        let item = l:m[2]
        let text = l:m[3]

        if l:item == '*'
            let structure = l:text
            let structure_indent = l:indent
            let structures[l:structure] = []
            continue
        endif

        if l:structure != '' && l:item == '-' && l:indent > l:structure_indent
            let structures[l:structure] += [ { "text": l:text, "indent": l:indent - l:structure_indent } ]
        endif
    endfor

    return l:structures
endfunction

"=========================== Manage articles ========================================

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
    let line = getline(".")

    let m = matchlist(l:line, s:listitemRE)
    if len(l:m) == 0
        return
    endif

    let id = s:zettel_id()
    let tags = l:m[2] == '' ? '' : " ".l:m[2]
    let lineitem = l:m[3] == '' ? '' : " ".l:m[3]
    call setline(".", "[" . l:id . "]" . l:tags . l:lineitem)
endfunction

function! zortex#article#resource_to_zettel(...)
    let m = matchlist(getline('.'), s:listitemRE)
    if len(l:m) == 0
        return
    endif

    let resource = zortex#article#convert_resource(l:m[3])
    if empty(l:resource)
        return
    endif

    let id = s:zettel_id()
    let tags = empty(l:m[2]) ? '#z-source# ' : '#z-source'.l:m[2] . ' '
    let lineitem = empty(l:m[3]) ? '' : ' '.l:m[3]
    call setline('.', '[' . l:id . ']' . ' ' . l:tags . l:resource)
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

let s:titleRE = '^\(.\{-}\)\(\%(: \)\|\%( | \).\{-1,}\)\?\( - .*\)\?$'
function! s:parse_title(title)
    let m = matchlist(a:title, s:titleRE)
    return { 'title': l:m[1],
           \ 'subtitle': empty(l:m[2]) ? '' : trim(l:m[2][2:]),
           \ 'authors': empty(l:m[3]) ? '' : split(l:m[3][3:], ",")
           \ }
endfunction

function! s:title_to_resource(title)
    let parsed_title = s:parse_title(a:title)
    return { 'title': empty(l:parsed_title.title) ? '' : 'title=' . l:parsed_title.title . '; ',
           \ 'subtitle': empty(l:parsed_title.subtitle) ? '' : 'subtitle=' . l:parsed_title.subtitle . '; ',
           \ 'authors': empty(l:parsed_title.authors) ? '' : join(map(l:parsed_title.authors, '"author=".trim(v:val).";"' ), " ") . ' '
           \ }
endfunction

let s:resourceRE = '\[\([^\]]\{-1,}\)\(: [^\]]\{-1,}\)\?\( - [^\]]*\)\?\](\(.\{-}\)\(\.\w\+\)\?)' " [title: subtitle - authors](ref.extension)
" Convert various resource formats into {title=title; subtitle=subtitle; ...;}
function! zortex#article#convert_resource(line)

    " Exit if line already looks like its in zortex resource format
    if len(matchlist(a:line, '{\w\+=.*;}')) != 0
        return ''
    endif

    " [title: subtitle - authors](ref.extension)
    let m = matchlist(a:line, s:resourceRE)
    if len(l:m) != 0
        let title = empty(l:m[1]) ? '' : 'title=' . l:m[1] . '; '
        let subtitle = empty(l:m[2]) ? '' : 'subtitle=' . l:m[2][2:] . '; '
        let authors = empty(l:m[3]) ? '' : join(map(split(l:m[3][3:], ","), '"author=".trim(v:val).";"' ), " ") . ' '
        let ref = empty(l:m[4]) ? '' : 'ref=' . l:m[4] . l:m[5] . '; '
        let extension = empty(l:m[5]) ? '' : l:m[5][1:]

        if l:ref =~ '^ref=http'
            let resource = 'resource=website;'
        elseif !empty(l:extension)
            let resource = 'resource=' . l:extension . ';'
        else
            let resource = ''
        endif

        " type = vim.eval("get(a:, 1, v:null)")
        " type = f'type={type}; ' if type else ''

        return '{' . trim(l:title . l:subtitle . l:authors . l:ref . l:resource) . '}'
    endif

    " http://domain.tld/path
    let m = matchlist(a:line, 'https\?://[^ ]\+')
    if len(l:m) != 0
        let url = l:m[0]
        let title = s:get_url_title(l:url)
        if empty(title)
            return '{' . 'ref=' . l:url . '; resource=website;}'
        else
            let t = s:title_to_resource(l:title)
            return '{' . l:t.title . l:t.subtitle . l:t.authors . 'ref=' . l:url . '; resource=website;}'
        endif
    endif

    " [title: subtitle - author]
    let m = matchlist(a:line, '\[\([^)]*\)\]')
    if len(l:m) != 0
        let t = s:title_to_resource(l:m[1])
        return '{' . trim(l:t.title . l:t.subtitle . l:t.authors) . '}'
    endif

    return ''
endfunction

function! zortex#article#get_matching_structures(article_name)
    let structures = s:get_zortex_structures()
    let matching_structures = []
    for [structure, items] in items(l:structures)
        for item in l:items
            if s:article_names_match(a:article_name, l:item["text"])
                let matching_structures += [l:structure]
                break
            endif
        endfor
    endfor

    return [l:structures, l:matching_structures]
endfunction

function! s:render_structure(structures, structure)
    let lines = [printf("- %s", a:structure)]
    for item in a:structures[a:structure]
        let indent = item["indent"]
        let text = item["text"]
        let line = printf("%s- %s", repeat(" ", l:indent), l:text)
        let lines += [l:line]
    endfor
    return l:lines
endfunction

function s:render_structures(structures, matching_structures)
    let lines = []
    for structure in a:matching_structures
        let lines += s:render_structure(a:structures, structure) + [""]
    endfor
    return l:lines
endfunction

function s:render_article_structures(article_name)
    let [l:structures, l:matching_structures] = zortex#article#get_matching_structures(a:article_name)
    return s:render_structures(l:structures, l:matching_structures)
endfunction

function! zortex#article#open_structure()
    if &l:filetype != 'zortex'
        return
    endif

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

    let article_name = getline(1)[2:] " assuming @@<article_name>

    call append(0, s:render_article_structures(l:article_name))
    call cursor(1, 1)
endfunction
