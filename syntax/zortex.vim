" Vim syntax file
" Language:	Zettel
" Maintainer:	Trey Wilkinson <winston.trey.wilkinson@gmail.com>
" Remark:	Zettelkasten

" if exists("b:current_syntax")
"   finish
" endif
" unlet! b:current_syntax

if !exists('main_syntax')
  let main_syntax = 'zettel'
endif

let s:local_conceallevel = &conceallevel
let s:local_concealcursor = &concealcursor
syn spell toplevel
syn case ignore
syn sync linebreaks=1

let s:conceal = ''
let s:concealends = ''
let s:concealcode = ''
if has('conceal') && get(g:, 'vim_markdown_conceal', 1)
  let s:conceal = ' conceal'
  let s:concealends = ' concealends'
endif
if has('conceal') && get(g:, 'vim_markdown_conceal_code_blocks', 1)
  let s:concealcode = ' concealends'
endif

" Fence languages
if !exists('g:zortex_fenced_languages')
  if exists('g:markdown_fenced_languages')
      let g:zortex_fenced_languages = g:markdown_fenced_languages
  else
      let g:zortex_fenced_languages = []
  endif
endif
let s:done_include = {}
for s:type in map(copy(g:zortex_fenced_languages),'matchstr(v:val,"[^=]*$")')
  if has_key(s:done_include, matchstr(s:type,'[^.]*'))
    continue
  endif
  if s:type =~ '\.'
    let b:{matchstr(s:type,'[^.]*')}_subtype = matchstr(s:type,'\.\zs.*')
  endif
  exe 'syn include @markdownHighlight'.substitute(s:type,'\.','','g').' syntax/'.matchstr(s:type,'[^.]*').'.vim'
  unlet! b:current_syntax
  let s:done_include[matchstr(s:type,'[^.]*')] = 1
endfor
unlet! s:type
unlet! s:done_include

" additions to HTML groups
if get(g:, 'vim_markdown_emphasis_multiline', 0)
    let s:oneline = ''
else
    let s:oneline = ' oneline'
endif

if get(g:, 'vim_markdown_math', 1)
  syn include @tex syntax/tex.vim
  syn region mkdMath start="\\\@<!\$" end="[^ ]\$" contains=@tex keepend oneline
  syn region mkdMath start="\\\@<!\$\$" end="\$\$" skip="\\\$" contains=@tex keepend
  syn region mkdMath start="\\\@<!\\(" end="\\)" contains=@tex keepend oneline
  syn region mkdMath start="\\\[" end="\\]" contains=@tex keepend
endif


" execute 'syn region htmlItalic matchgroup=mkdItalic start="\%(^\|\s\)\zs\*\ze[^\\\*\t ]\%(\%([^*]\|\\\*\|\n\)*[^\\\*\t ]\)\?\*\_W" end="[^\\\*\t ]\zs\*\ze\_W" keepend contains=@Spell' . s:oneline . s:concealends
execute 'syn region zBright matchgroup=mkdItalic start="\%(^\|\s\)\zs\*\ze\S" end="\S\zs\*" keepend contains=@Spell' . s:oneline . s:concealends
execute 'syn region zBold matchgroup=mkdBold start="\%(^\|\s\)\zs\*\*\ze\S" end="\S\zs\*\*" keepend contains=@Spell' . s:oneline . s:concealends
execute 'syn region zBrightBold matchgroup=mkdBoldItalic start="\%(^\|\s\)\zs\*\*\*\ze\S" end="\S\zs\*\*\*" keepend contains=@Spell' . s:oneline . s:concealends


" []
execute 'syn region zLink matchgroup=mkdDelimiter start="\[\ze[^^]" end="\]" contains=@zInline,@Spell skipwhite oneline' . s:concealends

" [^zortex footer note]
execute 'syn region zFooterNote matchgroup=mkdDelimiter start="\[^" end="\]" contains=@zInline,@Spell skipwhite oneline' . s:concealends

" [link](URL) | [link][id] | [link][] | ![image](URL)
execute 'syn region mkdLink matchgroup=mkdDelimiter       start="\\\@<!!\?\[\ze[^]\n]*\n\?[^]\n]*\][[({]" end="\]" contains=@mkdNonListItem,@Spell nextgroup=mkdZettel,mkdURL,mkdID skipwhite' . s:concealends
execute 'syn region mkdURL matchgroup=mkdDelimiter   start="("     end=")"  contained oneline' . s:conceal

" execute 'syn region mkdZettel matchgroup=mkdDelimiter   start="{"     end="}"  contained oneline' . s:conceal
" execute 'syn region mkdID matchgroup=mkdDelimiter    start="\["    end="\]" contained oneline' . s:conceal
" execute 'syn region mkdEmptyLink matchgroup=mkdDelimiter  start="\\\@<!!\?\[\ze[^]\n]*\n\?[^]\n]*\][[({]\@!" end="\]" contains=@mkdNonListItem,@Spell skipwhite' . s:concealends
" execute 'syn region mkdLink matchgroup=mkdDelimiter  start="\[\ze[^]]*\]{" end="\]" contains=@mkdNonListItem,@Spell nextgroup=mkdZettel,mkdURL,mkdID skipwhite' . s:concealends

" Autolink without angle brackets.
" mkd  inline links:      protocol     optional  user:pass@  sub/domain                    .com, .co.uk, etc         optional port   path/querystring/hash fragment
"                         ------------ _____________________ ----------------------------- _________________________ ----------------- __
syn match   mkdInlineURL /https\?:\/\/\(\w\+\(:\w\+\)\?@\)\?\([A-Za-z0-9][-_0-9A-Za-z]*\.\)\{1,}\(\w\{2,}\.\?\)\{1,}\(:[0-9]\{1,5}\)\?[^] \t]*/

" Autolink with parenthesis.
" syn region  mkdInlineURL matchgroup=mkdDelimiter start="(\(https\?:\/\/\(\w\+\(:\w\+\)\?@\)\?\([A-Za-z0-9][-_0-9A-Za-z]*\.\)\{1,}\(\w\{2,}\.\?\)\{1,}\(:[0-9]\{1,5}\)\?[^] \t]*)\)\@=" end=")"

" Autolink with angle brackets.
" syn region mkdInlineURL matchgroup=mkdDelimiter start="\\\@<!<\ze[a-z][a-z0-9,.-]\{1,22}:\/\/[^> ]*>" end=">"

" Link definitions: [id]: URL (Optional Title)
" syn region mkdLinkDef matchgroup=mkdDelimiter   start="^ \{,3}\zs\[\^\@!" end="]:" oneline nextgroup=mkdLinkDefTarget skipwhite
" syn region mkdLinkDefTarget start="<\?\zs\S" excludenl end="\ze[>[:space:]\n]"   contained nextgroup=mkdLinkTitle,mkdLinkDef skipwhite skipnl oneline
" syn region mkdLinkTitle matchgroup=mkdDelimiter start=+"+     end=+"+  contained
" syn region mkdLinkTitle matchgroup=mkdDelimiter start=+'+     end=+'+  contained
" syn region mkdLinkTitle matchgroup=mkdDelimiter start=+(+     end=+)+  contained

"define Markdown groups
syn match  mkdLineBreak    /  \+$/
syn region mkdBlockquote   start=/^\s*|/                   end=/$/ contains=mkdLink,mkdInlineURL,mkdLineBreak,@Spell

" execute 'syn region mkdCode matchgroup=mkdCodeDelimiter start=/\(\([^\\]\|^\)\\\)\@<!`/                     end=/`/'
" execute 'syn region mkdCode matchgroup=mkdCodeDelimiter start=/\(\([^\\]\|^\)\\\)\@<!``/ skip=/[^`]`[^`]/   end=/``/' . s:concealcode
" execute 'syn region mkdCode matchgroup=mkdCodeDelimiter start=/^\s*\z(`\{3,}\)[^`]*$/                       end=/^\s*\z1`*\s*$/'            . s:concealcode
" execute 'syn region mkdCode matchgroup=mkdCodeDelimiter start=/\(\([^\\]\|^\)\\\)\@<!\~\~/  end=/\(\([^\\]\|^\)\\\)\@<!\~\~/'               . s:concealcode
" execute 'syn region mkdCode matchgroup=mkdCodeDelimiter start=/^\s*\z(\~\{3,}\)\s*[0-9A-Za-zortex_+-]*\s*$/      end=/^\s*\z1\~*\s*$/'           . s:concealcode
" execute 'syn region mkdCode matchgroup=mkdCodeDelimiter start="<pre\(\|\_s[^>]*\)\\\@<!>"                   end="</pre>"'                   . s:concealcode
" execute 'syn region mkdCode matchgroup=mkdCodeDelimiter start="<code\(\|\_s[^>]*\)\\\@<!>"                  end="</code>"'                  . s:concealcode

" syn region markdownCodeBlock start="^\n\( \{4,}\|\t\)" end="^\ze \{,3}\S.*$" keepend
" syn region markdownCodeBlock matchgroup=markdownCodeDelimiter start="^\s*\z(`\{3,\}\).*$" end="^\s*\z1\ze\s*$" keepend
syn region mkdCode matchgroup=mkdCodeDelimiter start="^\s*\z(`\{3,\}\).*" end="^\s*\z1\ze\s*$" keepend
" syn cluster markdownBlock contains=markdownH1,markdownH2,markdownH3,markdownH4,markdownH5,markdownH6,markdownBlockquote,markdownListMarker,markdownOrderedListMarker,markdownCodeBlock,markdownRule

" " Zettelkasten
" syn region zettelTag start=" #"    end="# " conceal oneline cchar= "
"             "\d\{4}\.\d\{3}\.\d\{5}]/
" syn region zettelTag start="\[z:" end="\]" conceal cchar=▣

if get(g:, 'vim_markdown_strikethrough', 1)
    execute 'syn region mkdStrike matchgroup=htmlStrike start="\%(\~\~\)" end="\%(\~\~\)"' . s:concealends
endif

if get(g:, 'vim_markdown_math', 1)
  syn include @tex syntax/tex.vim
  syn region mkdMath start="\\\@<!\$\$" end="\$\$" skip="\\\$" contains=@tex keepend
endif

syn cluster zInline contains=zFooterNote,zLink,@htmlTop,htmlItalic,htmlBold,htmlBoldItalic,mkdFootnotes,mkdInlineURL,mkdLink,mkdLinkDef,mkdLineBreak,mkdBlockquote,mkdCode,mkdRule,htmlH1,htmlH2,htmlH3,htmlH4,htmlH5,htmlH6,mkdMath,mkdStrike,mkdEmptyLink

syn region zQuote start=/"/ end=/"/ oneline

if main_syntax ==# 'zettel'
  let s:done_include = {}
  for s:type in g:zortex_fenced_languages
    if has_key(s:done_include, matchstr(s:type,'[^.]*'))
      continue
    endif
    exe 'syn region markdownHighlight'.substitute(matchstr(s:type,'[^=]*$'),'\..*','','').' matchgroup=mkdCodeDelimiter start="^\s*\z(`\{3,\}\)\s*\%({.\{-}\.\)\='.matchstr(s:type,'[^=]*').'}\=\S\@!.*$" end="^\s*\z1\ze\s*$" keepend contains=@markdownHighlight'.substitute(matchstr(s:type,'[^=]*$'),'\.','','g')
    exe 'syn region markdownHighlight'.substitute(matchstr(s:type,'[^=]*$'),'\..*','','').' matchgroup=mkdCodeDelimiter start="^\s*\z(\~\{3,\}\)\s*\%({.\{-}\.\)\='.matchstr(s:type,'[^=]*').'}\=\S\@!.*$" end="^\s*\z1\ze\s*$" keepend contains=@markdownHighlight'.substitute(matchstr(s:type,'[^=]*$'),'\.','','g')
    let s:done_include[matchstr(s:type,'[^.]*')] = 1
  endfor
  unlet! s:type
  unlet! s:done_include
endif

" Structures
" syntax match zTag /^\d*@\{1,2}\ze\[/
syntax match zTag /^[A-Za-z0-9]*@\{1,2}\([A-Za-z0-9()]\S*\s\?\)\+/  " @@Article names or @Tags or key@Value
" TODO: match only if there's a new line before
syntax match zHeading /^#\{1,6} .*$/             " Headings
" syntax match zSection /^\d\+\.\d\+ [A-Za-z0-9-: ()]\+$/

syntax match String  /^[A-Za-z0-9][^.*:]\+\ze: /           " Label: text
syntax match zLabel /^[0-9A-Z][^.]\+\ze:$/           " Label:\n
syntax match String  /^\s\+[A-Za-z0-9][^.*:]\+\ze: /           " \s+Label: text
syntax match zLabel /^\s\+[0-9A-Z][^.]\+\ze:$/           " \s+Label:\n
syntax match zListLabel /\(\d\+\.\)\@<= \zs[^.]\+\ze:$/       " ^\d. Label text:$

syntax match zOperator /\(- \)\@<=\zs[A-Z][A-Za-z0-9(), ]\+\ze: /      " - Label:\s
" syntax match String /\s[A-Za-z0-9() ]\+\ze: /      " - Label: Some text

syntax match zOperator /- \zs#.*#\ze / " - #tag1#tag2# Text
syntax match zAttribute / \@<=\zs@\w\+\(([^)]*)\)\?/    " @event, @due(2025-12-05), etc.

syntax match zBullet /^\s*\zs[-+x*]\ze\s/            " Unordered lists
syntax match zOperator /^\s*[A-Za-z0-9]\+\.\ze\s/  " Numbered lists
syntax match zTask /\(- \)\@<=\zs\[[ x~X]]\ze / " - [x] Task


syntax match zOperator /\d\d\?:\d\d/ " Times of day 
syntax match zOperator /[A-Z]\S* \d\+:\d\+\(-\d\+\)/ " Scripture quotes
syntax match zDefinition /[A-Za-z0-9- )(.].\{-}\ze :=/ " Word := is defined as...
syntax match Statement /[ \r\n]\d\+s\?: /  " history year
syntax match Statement /[ \r\n]\s\d\+s\?-\d\+s\?: /  " history year range

" Operators
syntax match zOperator / \(:\|:=\|<->\|<-\|->\|>-\|-<\|>-<\|\~>\|<=>\|=>\|!=\|==\|+\|vs\.\|\/\||\) /
syntax match zOperator /\d\{1,3}%\_s/ " Percents
syntax match zOperator /\(,\|;\)\_s/ " Commas
syntax match zOperator /: /
syntax match zOperator /:$/

syntax match zOperator /\w\zs\(\.\|?\)\ze\( \|$\)/ " Sentence period.
syntax match zOperator /^[A-Z][^.?]\+?$/           " Sentence question?

" syntax match zOperator /\w\+=\ze\(\w\|\/\|\.\)/ " Dunno
" syntax match zOperator /\(\w\|*\)\zs: /
" syntax match zOperator /#\([A-Z0-9]\S*\s\?\)\+#/
" syntax match zOperator /^\d\{14}:/
" syntax match zOperator /\$\d\+\.\d\+/ " Price
" syntax match zOperator /z:\d\{4}\.\d\{5}\.\d\{5}/

" syntax match Statement /|[^|]\+|/ " Search for tag
" syntax match zTag /^\s*\zs%/ " queries

" $HOME/.vim/plugged/vim/colors/dracula.vim
command! -nargs=+ Hi hi def link <args>

Hi mkdBlockquote    Comment
Hi mkdCodeDelimiter mkdSurround
Hi mkdCode          Function
Hi mkdCodeEnd       String
Hi mkdCodeStart     String
Hi mkdDelimiter     Delimiter
Hi mkdStrike        String

Hi mkdFootnote      Comment
Hi mkdFootnotes     htmlLink
Hi mkdID            Tag
Hi mkdInlineURL     Tag
Hi mkdLineBreak     Visual
Hi mkdEmptyLink     Tag
Hi mkdLinkDef       mkdID
Hi mkdLinkDefTarget mkdURL
Hi mkdLinkTitle     htmlString
Hi mkdListItem      Identifier
Hi mkdRule          Identifier
Hi mkdString        String
Hi mkdZettel        htmlString

Hi htmlString       Tag
Hi htmlLink         Statement
Hi mkdItalic        mkdSurround
Hi mkdBold          mkdSurround
Hi mkdBoldItalic    mkdSurround

Hi mkdLink          Label
Hi mkdURL           Label

Hi zBright       String
Hi zBold         Directory
Hi zBrightBold   Title
Hi zettelTag Tag
Hi zFooterNote      Comment

Hi mkdSurround      Statement

" hi zHeading gui=bold,italic guifg=#3e8fb0
" Hi zHeading         mkdBoldItalic
" hi zHeading gui=bold guibg=#3e8fb0 guifg=#232136
hi zHeading gui=bold,italic guifg=#eb6f92
hi zSection guifg=#eb6f92

Hi zLink     Tag
Hi zQuote           String
Hi zTag             Directory
Hi zOperator        Tag
" Hi zLabel           Conditional
hi zLabel gui=bold guifg=#3e8fb0
Hi zBullet          Tag
" Hi zListLabel       Macro
Hi zListLabel       Underlined
" hi zLabel gui=bold
Hi zAttribute           Comment
Hi zTask            Question

let b:current_syntax = "zettel"
if main_syntax ==# 'zettel'
  unlet main_syntax
  let &conceallevel=s:local_conceallevel
  let &concealcursor=s:local_concealcursor
endif

delcommand Hi
" vim: ts=8 filetype=vim
