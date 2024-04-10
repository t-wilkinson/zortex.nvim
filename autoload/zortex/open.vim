" Needs: openbrowser s:OpenStructure s:OpenArticle s:OpenProject

" Regular Expressions
let s:markdownLinkRE = '\v\[([^\]]+)\]\(([^\)]+)\)'
let s:lineRE = '\v^(\s*)- (.*)$'
let s:zettelRE = '\v^(?<indent>\s*)- (?<tags>#.*#)?(?! )?(?<text>.*)$'
let s:projectRE = '\v^(?<indent>\s*)- (?<tags>#.*#)?(?! )?(.*)$'
let s:zortexLineRE = '\v- (?<tags>#.+# )?(?<text>.*)$'

let s:websiteLinkRE = '\vhttps?:\/\/[^);}]+'
let s:fileLinkRE = s:markdownLinkRE
let s:fragmentLinkRE = '\v\|([^|]+)\|'
let s:zortexLinkRE = '\vref=([^\s;}]+)'
let s:articleLinkRE = '\v\[([^\]]+)\]'
let s:filePathRE = '\v(^|\s)(?<path>[~.]?\/[/\S]+)($|\s)'
let s:linkRE = '\v\[(?<text>[^\]]+)\](\((?<ref>[^\)]+)\))?'
let s:headingRE = '\v^#+ (.*)$'
let s:zettelLinkRE = '\v\[(z:\d{4}\.\d{5}\.\d{5})]\]'
let s:footernoteRE = '\v\[\^(\d+)]'

function! s:ExtractLink(line)
  let l:match = matchlist(a:line, s:websiteLinkRE)
  if !empty(l:match)
    return {
          \ 'line': a:line,
          \ 'type': 'website',
          \ 'url': l:match[0],
          \ }
  endif

  let l:match = matchlist(a:line, s:fileLinkRE)
  if !empty(l:match)
    return {
          \ 'line': a:line,
          \ 'type': 'file',
          \ 'name': l:match[1],
          \ 'url': l:match[2],
          \ }
  endif

  let l:match = matchlist(a:line, s:zortexLinkRE)
  if !empty(l:match)
    return {
          \ 'line': a:line,
          \ 'type': 'zortex-link',
          \ 'url': l:match[1],
          \ }
  endif

  let l:match = matchlist(a:line, s:zettelLinkRE)
  if !empty(l:match)
    let l:pos = getcurpos()
    let l:col = l:pos[2] - 1
    let l:re = s:zettelLinkRE

    while l:match != []
      " find first match that the cursor is on or before
      if l:col <= strlen(l:match[0]) + l:match[0][0]
        break
      endif
      let l:match = matchlist(a:line, l:re, l:match[0][0] + strlen(l:match[0]))
    endwhile

    return {
          \ 'line': a:line,
          \ 'type': 'zettel-link',
          \ 'zettel_id': l:match[1],
          \ }
  endif

  let l:match = matchlist(a:line, s:footernoteRE)
  if !empty(l:match)
    let l:col = col('.')
    let l:re = s:footernoteRE

    while l:match != []
      " find first match that the cursor is on or before
      if l:col <= strlen(l:match[0]) + l:match[0][0]
        break
      endif
      let l:match = matchlist(a:line, l:re, l:match[0][0] + strlen(l:match[0]))
    endwhile

    return {
          \ 'line': a:line,
          \ 'type': 'footernote',
          \ 'ref': l:match[1],
          \ }
  endif

  let l:match = matchlist(a:line, s:fragmentLinkRE)
  if !empty(l:match)
    " get line from cursor to end of line
    let l:col = col('.')
    let l:re = s:fragmentLinkRE

    while l:match != []
      " find first match that the cursor is on or before
      let l:link = l:match[1]
      if l:col <= strlen(l:link) + l:match[0][0]
        break
      endif
      let l:match = matchlist(a:line, l:re, l:match[0][0] + strlen(l:match[0]))
    endwhile

    return {
          \ 'line': a:line,
          \ 'type': 'fragment-link',
          \ 'fragment': l:link,
          \ }
  endif

  let l:match = matchlist(a:line, s:articleLinkRE)
  if !empty(l:match)
    return {
          \ 'line': a:line,
          \ 'type': 'article',
          \ 'name': l:match[1],
          \ }
  endif

  let l:match = matchlist(a:line, s:filePathRE)
  if !empty(l:match)
    return {
          \ 'line': a:line,
          \ 'type': 'path',
          \ 'path': l:match[2],
          \ }
  endif

  let l:match = matchlist(a:line, s:lineRE)
  if !empty(l:match)
    return {
          \ 'line': a:line,
          \ 'type': 'text',
          \ 'indent': strlen(l:match[1]),
          \ 'name': l:match[2],
          \ }
  endif

  let l:match = matchlist(a:line, s:headingRE)
  if !empty(l:match)
    return {
          \ 'line': a:line,
          \ 'type': 'heading',
          \ 'name': l:match[1],
          \ }
  endif

  " get text under visual selection
  let l:selection = join(getline("'<", "'>"), "\n")

  return {}
endfunction

function! s:OpenLink()
  let l:line = getline('.')
  let l:filename = expand('%:t:r')

  " get article name
  let l:link = s:ExtractLink(l:line)

  if empty(l:link)
    return
  endif

  if l:link.url =~# '^\./'
    let l:link.url = fnamemodify(g:zortex_notes_dir . '/' . l:link.url, ':p')
  endif
  let @a = printf('%03d%s', str2nr(printf('%03d%03d', localtime() % 1000, getpid() % 1000)), string(l:link))

  if l:filename ==# 'zortex-structures' && l:link.type ==# 'text'
    let l:lines = getbufline('%', 1, '$')
    call s:OpenStructure(l:lines, l:link.name, l:link.indent)
  elseif l:filename ==# 'structure' && l:link.type ==# 'text'
    let l:lines = readfile('structure.zortex')
    let l:opened = s:OpenStructure(l:lines, l:link.name, l:link.indent)
    if !l:opened
      call openbrowser('https://en.wikipedia.org/wiki/Special:Search/' . l:link.name)
    endif
  elseif l:filename ==# 'schedule' && l:link.type ==# 'text'
    call s:OpenProject(l:link.name)
  elseif l:link.type ==# 'wikipedia' || l:link.type ==# 'text'
    if !empty(l:link.name)
      call s:OpenArticle(l:link.name)
    endif
  elseif l:link.type ==# 'path'
    if isdirectory(l:link.path)
      execute 'edit' fnameescape(l:link.path)
    else
      execute 'edit' fnameescape(l:link.path)
    endif
  elseif l:link.type ==# 'fragment-link'
    execute 'call search(''\c\s*- ' . l:link.fragment . '', ''sw'')'
  elseif l:link.type ==# 'footernote'
    execute 'call search(''\[^' . l:link.ref . ']: '', ''b'')'
  elseif l:link.type ==# 'zortex-link'
    call openbrowser(l:link.url)
  elseif l:link.type ==# 'website' || l:link.type ==# 'resource' || l:link.type ==# 'file'
    call openbrowser(l:link.url)
  elseif l:link.type ==# 'article'
    call s:OpenArticle(l:link.name)
  elseif l:link.type ==# 'heading'
    call s:OpenArticle(l:link.name)
  endif
endfunction

function! s:ToZortexLink(info, ...)
  let l:tags = get(a:000, 0, '')
  let l:params = []

  for [l:name, l:value] in items(a:info)
    if !empty(l:value)
      call add(l:params, l:name . '=' . l:value)
    endif
  endfor

  let l:link = '{' . join(l:params, '; ') . '}'
  return !empty(l:tags) ? l:tags . ' ' . l:link : l:link
endfunction

function! s:GetZortexLink(url)
  let l:response = system('curl -s ' . a:url)
  let l:title = matchstr(l:response, '<h1>\zs.\{-}\ze</h1>')
  if empty(l:title)
    let l:title = matchstr(l:response, '<title>\zs.\{-}\ze</title>')
  endif
  if empty(l:title)
    return {}
  endif
  let l:title = substitute(l:title, '\s\+', ' ', 'g')

  return {
        \ 'title': l:title,
        \ 'ref': a:url,
        \ }
endfunction

function! s:ParseLinkText(text)
  let l:subtitleIndex = stridx(a:text, ': ')
  let l:authorsIndex = stridx(a:text, ' - ', l:subtitleIndex >= 0 ? l:subtitleIndex : 0)

  let l:title = ''
  let l:subtitle = ''
  let l:authors = ''

  if l:subtitleIndex > 0 && l:authorsIndex > 0
    let l:title = a:text[:l:subtitleIndex - 1]
    let l:subtitle = a:text[l:subtitleIndex + 2 : l:authorsIndex - 1]
    let l:authors = a:text[l:authorsIndex + 3 :]
  elseif l:subtitleIndex > 0
    let l:title = a:text[:l:subtitleIndex - 1]
    let l:subtitle = a:text[l:subtitleIndex + 2 :]
  elseif l:authorsIndex > 0
    let l:title = a:text[:l:authorsIndex - 1]
    let l:authors = a:text[l:authorsIndex + 3 :]
  else
    let l:title = a:text
  endif

  return {
        \ 'title': l:title,
        \ 'subtitle': l:subtitle,
        \ 'authors': l:authors,
        \ }
endfunction

function! s:GetLink(line)
  let l:match = matchlist(a:line, s:linkRE)
  if !empty(l:match)
    let l:g = l:match[0]
    let l:ref = l:match.ref
    let l:parsed = s:ParseLinkText(l:match.text)
    let l:title = l:parsed.title
    let l:subtitle = l:parsed.subtitle
    let l:authors = l:parsed.authors

    if empty(l:title) && !empty(l:ref) || l:title =~# s:websiteLinkRE
      let l:res = s:GetZortexLink(l:title)
      if !empty(l:res)
        let l:ref = l:res.ref

        let l:parsed = s:ParseLinkText(l:res.title)
        let l:title = l:parsed.title
        let l:subtitle = l:parsed.subtitle
        let l:authors = l:parsed.authors
      endif
    endif

    let l:link = s:ToZortexLink({
          \ 'title': l:title,
          \ 'subtitle': l:subtitle,
          \ 'authors': l:authors,
          \ 'ref': l:ref,
          \ })
    let l:beforeLink = a:line[:l:match[0][0] - 1]
    let l:afterLink = a:line[l:match[0][1] :]
    return l:beforeLink . l:link . l:afterLink

  elseif a:line =~# s:websiteLinkRE
    let l:match = matchlist(a:line, s:websiteLinkRE)[0]
    let l:link = s:ToZortexLink(s:GetZortexLink(l:match))
    return substitute(a:line, l:match, l:link, '')

  elseif a:line =~# s:zortexLineRE
    let l:match = matchlist(a:line, s:zortexLineRE)
    let l:g = l:match[0]
    let l:link = s:ToZortexLink({ 'title': l:match.text })
    return '- ' . l:match.tags . l:link
  endif

  return ''
endfunction

function! s:CreateLink(startLine, endLine)
  for l:i in range(a:startLine, a:endLine)
    let l:line = getline(l:i)
    let l:link = s:GetLink(l:line)
    if !empty(l:link)
      undojoin
      call setline(l:i, l:link)
    endif
  endfor

  write
endfunction

