function! zortex#fold#init()
    " make sure initialisation only happens once
    if exists("b:anyfold_initialised")
        return
    else
        let b:anyfold_initialised = 1
    endif

    call s:init_indent_list()

    autocmd TextChanged,InsertLeave <buffer> call s:reload_folds()

    call s:set_options()

    autocmd WinEnter,BufNewFile,BufRead <buffer> call s:set_options()

    noremap <script> <buffer> <silent> <F7>
                \ :call <SID>echo_indents(1)<cr>
    noremap <script> <buffer> <silent> <F8>
                \ :call <SID>echo_indents(2)<cr>
    noremap <script> <buffer> <silent> <F9>
                \ :call <SID>echo_indents(3)<cr>
    noremap <script> <buffer> <silent> <F10>
                \ :call <SID>echo_indents(4)<cr>
endfunction

function! zortex#fold#update_folds()
    unlockvar! b:anyfold_ind_buffer
    unlockvar! b:anyfold_ind_actual
    unlockvar! b:anyfold_ind_contextual

    call s:init_indent_list()
endfunction

function! s:set_options()
    " setlocal foldignore=
    setlocal foldmethod=expr
    set foldexpr=b:anyfold_ind_buffer[v:lnum-1]
    " if g:anyfold_fold_display
    setlocal foldtext=MinimalFoldText()
    " endif
endfunction

"----------------------------------------------------------------------------/
" Improved fold display
" Inspired by example code by Greg Sexton
" http://gregsexton.org/2011/03/27/improving-the-text-displayed-in-a-vim-fold.html
"----------------------------------------------------------------------------/
function! MinimalFoldText()
    let fs = v:foldstart
    while getline(fs) !~ '\w'
        let fs = nextnonblank(fs + 1)
    endwhile
    if fs > v:foldend
        let line = getline(v:foldstart)
    else
        let line = substitute(getline(fs), '\t', repeat(' ', &tabstop), 'g')
    endif

    let w = winwidth(0) - &foldcolumn - &number * &numberwidth
    let foldSize = 1 + v:foldend - v:foldstart
    let foldSizeStr = " " . substitute(g:anyfold_fold_size_str, "%s", string(foldSize), "g") . " "
    let foldLevelStr = repeat(g:anyfold_fold_level_str, v:foldlevel)
    let lineCount = line("$")
    let expansionString = repeat(" ", w - strwidth(foldSizeStr.line.foldLevelStr))
    return line . expansionString . foldSizeStr . foldLevelStr
endfunction

function! s:init_indent_list()
    let b:anyfold_ind_actual = s:actual_indents(1, line('$'))
    let b:anyfold_ind_contextual = s:contextual_indents(0, 1, line('$'), b:anyfold_ind_actual)
    let b:anyfold_ind_buffer = s:buffer_indents(1, line('$'))
    command! I echo s:buffer_indents(1, line('$'))[line('.')-1]

    lockvar! b:anyfold_ind_buffer
    lockvar! b:anyfold_ind_actual
    lockvar! b:anyfold_ind_contextual
endfunction

"----------------------------------------------------------------------------/
" get indent, filtering ignores special lines (empty lines, comment lines ...)
"----------------------------------------------------------------------------/
function! s:line_indent(lnum)
    let prev_indent = indent(s:prev_non_blank_line(a:lnum))
    let next_indent = indent(s:next_non_blank_line(a:lnum))
    if s:consider_line(a:lnum)
        return indent(a:lnum)
    else
        return max([prev_indent,next_indent])
    endif
endfunction

"----------------------------------------------------------------------------/
" buffer for indents used in foldexpr
"----------------------------------------------------------------------------/
function! s:buffer_indents(line_start, line_end)
    let ind_list = []
    let curr_line = a:line_start
    while curr_line <= a:line_end
        let ind_list += [s:get_indent_fold(curr_line)]
        let curr_line += 1
    endwhile
    return ind_list
endfunction

"----------------------------------------------------------------------------/
" Utility function to check if line is to be considered
"----------------------------------------------------------------------------/
function! s:consider_line(lnum)
    let line = getline(a:lnum)
    if l:line !~? '\v\S'
        " empty line
        return 0
    elseif l:line =~? '^\W\+$'
        " line containing braces or other non-word characters that will not
        " define an indent
        return 0
    else
        return 1
    endif
endfunction

"----------------------------------------------------------------------------/
" Next non-blank line
"----------------------------------------------------------------------------/
function! s:next_non_blank_line(lnum)
    let numlines = line('$')
    let curr_line = a:lnum + 1

    while curr_line <= numlines
        if s:consider_line(curr_line)
            return curr_line
        endif

        let curr_line += 1
    endwhile

    return -1
endfunction

"----------------------------------------------------------------------------/
" Previous non-blank line
"----------------------------------------------------------------------------/
function! s:prev_non_blank_line(lnum)
    let curr_line = a:lnum - 1

    while curr_line > 0
        if s:consider_line(curr_line)
            return curr_line
        endif

        let curr_line += -1
    endwhile

    return 0
endfunction

"----------------------------------------------------------------------------/
" get actual indents
" don't depend on context
" Note: this implements good heuristics also for braces
"----------------------------------------------------------------------------/
function! s:actual_indents(line_start, line_end)
    let curr_line = a:line_start
    let offset = curr_line

    " need to start with a line that has an indent
    while curr_line > 1 && s:consider_line(curr_line) == 0
        let curr_line -= 1
    endwhile
    let offset -= curr_line

    let ind_list = [indent(curr_line)]
    while curr_line < a:line_end
        let curr_line += 1
        let prev_indent = ind_list[-1]
        let next_indent = indent(s:next_non_blank_line(curr_line))
        if s:consider_line(curr_line)
            " non-empty lines that define an indent
            let ind_list += [indent(curr_line)]
        else
            let ind_list += [max([prev_indent, next_indent])]
        endif
    endwhile
    return ind_list[offset : ]
endfunction

"----------------------------------------------------------------------------/
" get indent hierarchy from actual indents
" indents depend on context
"----------------------------------------------------------------------------/
function! s:contextual_indents(init_ind, line_start, line_end, ind_list)
    let prev_ind = a:ind_list[0]
    let hierind_list = [a:init_ind]
    let ind_open_list = [a:ind_list[0]]
    let n_headings = []

    let curr_line = 0
    while curr_line < len(a:ind_list)
        let ind = a:ind_list[curr_line] + len(n_headings)
        let line = getline(curr_line + a:line_start)

        if line =~? '^[z:'
            let n_headings = [0]
            let ind = 0
        endif

        if line =~? '^#'
            " headings
            let n_heading = len(matchstr(line, '^#\+'))

            if len(n_headings) == 0 || n_headings[-1] < n_heading
                " n_heading is larger nesting level than n_headings
                let n_headings += [n_heading]
            elseif n_headings[-1] > n_heading
                " n_heading is smaller nesting level than n_headings
                " remove headings smaller than n_heading
                let prev_depth = n_headings[-1]
                let curr_heading = len(n_headings)
                while curr_heading > 0
                    let curr_heading -= 1
                    if n_headings[curr_heading] < n_heading
                        break
                    endif
                    call remove(n_headings, curr_heading)
                endwhile

                let n_headings = n_headings + [n_heading]
                if n_headings[-1] <= prev_depth
                    let ind = a:ind_list[curr_line] + len(n_headings) - 1
                else
                    let ind = a:ind_list[curr_line] + len(n_headings)
                endif
            else
                " n_heading is same nesting level
                let ind = ind - 1
            endif
        endif

        if ind > prev_ind
            " this line starts a new block
            let hierind_list += [hierind_list[-1] + 1]
            let ind_open_list += [ind]
        elseif ind == prev_ind
            " this line continues a block
            let hierind_list += [hierind_list[-1]]
        elseif ind < prev_ind
            " this line closes current block only if indent is less or equal to
            " indent of the line starting the block (=ind_open_list[-2])
            " line may close more than one block
            let n_closed = 0
            while len(ind_open_list) >= 2 && ind <= ind_open_list[-2]
                " close block
                let ind_open_list = ind_open_list[:-2]
                let n_closed += 1
            endwhile

            " update current block indent
            let ind_open_list[-1] = ind

            let hierind_list += [hierind_list[-1]-n_closed]
        endif

        let prev_ind = ind
        let curr_line += 1
    endwhile

    let hierind_list = hierind_list[1:]
    return hierind_list
endfunction

"----------------------------------------------------------------------------/
" fold expression
"----------------------------------------------------------------------------/
function! s:get_indent_fold(lnum)
    let this_indent = b:anyfold_ind_contextual[a:lnum-1]

    if a:lnum >= line('$')
        let next_indent = 0
    else
        let next_indent = b:anyfold_ind_contextual[a:lnum]
    endif

    " heuristics to define blocks at foldlevel 0
    " if this_indent == 0

    "     let prev_indent = b:anyfold_ind_contextual[a:lnum-2]

    "     if a:lnum == 1
    "         let prevprev_indent = 0
    "     else
    "         let prevprev_indent = b:anyfold_ind_contextual[a:lnum-3]
    "     endif

    "     if a:lnum >= line('$') - 1
    "         let nextnext_indent = 0
    "     else
    "         let nextnext_indent = b:anyfold_ind_contextual[a:lnum+1]
    "     endif

    "     if next_indent > 0
    "         return '>1'
    "     endif

    "     if prev_indent > 0
    "         return 0
    "     else
    "         if prevprev_indent > 0
    "             if next_indent == 0 && nextnext_indent == 0
    "                 return '>1'
    "             else
    "                 return 0
    "             endif
    "         else
    "             return 1
    "         endif
    "     endif
    " endif

    if next_indent <= this_indent
        return this_indent
    else
        return '>' . next_indent
    endif

endfunction

"----------------------------------------------------------------------------/
" Update folds
" Only lines that have been changed are updated
" Note: update mechanism may not always update brace based folds since it
" detects block to be updated based on indents.
"----------------------------------------------------------------------------/
function! s:reload_folds()

    " many of the precautions taken are necessary because the marks of
    " previously changed text '[ & '] are not always reliable, for instance if
    " text is inserted by a script. There may be vim bugs such as
    " vim/vim#1281.
    "

    " for some reason, need to redraw, otherwise vim will display
    " beginning of file before jumping to last position
    redraw

    let changed_start = min([getpos("'[")[1], line('$')])
    let changed_end = min([getpos("']")[1], line('$')])

    " fix that getpos(...) may evaluate to 0 in some versions of Vim
    let changed_start = max([changed_start, 1])
    let changed_end = max([changed_end, 1])

    let changed_tmp = [changed_start, changed_end]
    let changed = [min(changed_tmp), max(changed_tmp)]

    let changed_lines = changed[1] - changed[0] + 1
    let delta_lines = line('$') - len(b:anyfold_ind_actual)

    " if number of changed lines smaller than number of added / removed lines,
    " something went wrong and we mark all lines as changed.
    if changed_lines < delta_lines
        let changed[0] = 1
        let changed[1] = line('$')
        let changed_lines = changed[1] - changed[0] + 1
    endif

    " if number of lines has not changed and indents are the same, skip update
    if delta_lines == 0
        let indents_same = 1
        let curr_line = changed[0]
        while curr_line <= changed[1]
            if s:line_indent(curr_line) != b:anyfold_ind_actual[curr_line - 1]
                let indents_same = 0
                break
            endif
            let curr_line += 1
        endwhile
        if indents_same
            return
        endif
    endif

    " get first and last line of previously changed block
    let changed[0] = s:prev_non_blank_line(changed[0])
    let changed[1] = s:next_non_blank_line(changed[1])
    if changed[0] == 0
        let changed[0] = 1
    endif
    if changed[1] == -1
        let changed[1] = line('$')
    endif
    let changed_lines = changed[1] - changed[0] + 1

    unlockvar! b:anyfold_ind_actual
    unlockvar! b:anyfold_ind_contextual
    unlockvar! b:anyfold_ind_buffer

    let b:anyfold_ind_actual = s:extend_line_list(b:anyfold_ind_actual, changed[0], changed[1])
    let b:anyfold_ind_contextual = s:extend_line_list(b:anyfold_ind_contextual, changed[0], changed[1])
    let b:anyfold_ind_buffer = s:extend_line_list(b:anyfold_ind_buffer, changed[0], changed[1])

    if changed_lines > 0

        " partially update actual indent
        let b:anyfold_ind_actual[changed[0]-1 : changed[1]-1] = s:actual_indents(changed[0], changed[1])

        " find end of current code block for updating contextual indents
        " 1) find minimal indent present in changed block
        " 2) move down until line is found with indent <= minimal indent of
        " changed block
        let min_indent = min(b:anyfold_ind_actual[changed[0]-1 : changed[1]-1])

        " subtract one to make sure that new indent is applied to all lines of the
        " current block
        let min_indent = max([min_indent-1, 0])

        " find end of current block for updating contextual indents
        let curr_line = changed[1]
        let block_start_found = 0
        while !block_start_found
            if curr_line < line('$')
                let curr_line += 1
            endif
            if b:anyfold_ind_actual[curr_line-1] <= min_indent
                let block_start_found = 1
            endif

            if curr_line == line('$') && !block_start_found
                let block_start_found = 1
            endif
        endwhile
        let changed_block_end = curr_line

        " find beginning of current block, now minimal indent is indent of
        " last line of block
        let min_indent = min([b:anyfold_ind_actual[curr_line-1], min_indent])

        let curr_line = changed[0]
        let block_start_found = 0
        while !block_start_found
            if curr_line > 1
                let curr_line += -1
            endif
            if b:anyfold_ind_actual[curr_line-1] <= min_indent
                let block_start_found = 1
            endif

            if curr_line == 1 && !block_start_found
                let block_start_found = 1
            endif
        endwhile
        let changed_block_start = curr_line

        let changed_block = [changed_block_start, changed_block_end]

        let init_ind = b:anyfold_ind_contextual[changed_block[0]-1]
        let b:anyfold_ind_contextual[changed_block[0]-1 : changed_block[1]-1] =
                    \ s:contextual_indents(init_ind, changed_block[0], changed_block[1],
                    \ b:anyfold_ind_actual[changed_block[0]-1:changed_block[1]-1])

        let b:anyfold_ind_buffer[changed_block[0]-1 : changed_block[1]-1] = s:buffer_indents(changed_block[0], changed_block[1])
    endif

    lockvar! b:anyfold_ind_actual
    lockvar! b:anyfold_ind_contextual
    lockvar! b:anyfold_ind_buffer

    set foldexpr=b:anyfold_ind_buffer[v:lnum-1]

endfunction

"----------------------------------------------------------------------------/
" Extend lists containing entries for each line to the current number of lines.
" Zero out part that correspond to changed lines and move all other entries to
" the correct positions.
"----------------------------------------------------------------------------/
function! s:extend_line_list(list, insert_start, insert_end)
    let nchanged = a:insert_end - a:insert_start + 1
    let delta_lines = line('$') - len(a:list)

    let b1 = a:insert_start-2
    let b2 = a:insert_end-delta_lines

    let push_front = b1 >= 0
    let push_back = b2 <= len(a:list) - 1

    if push_front && push_back
        return a:list[ : b1] + repeat([0], nchanged) + a:list[b2 : ]
    elseif push_front
        return a:list[ : b1] + repeat([0], nchanged)
    elseif push_back
        return repeat([0], nchanged) + a:list[b2 : ]
    else
        return repeat([0], nchanged)
    endif

endfunction

"----------------------------------------------------------------------------/
" Debugging
"----------------------------------------------------------------------------/
function! s:echo_indents(mode)
    if a:mode == 2
        echom b:anyfold_ind_actual[line('.')-1]
    elseif a:mode == 3
        echom b:anyfold_ind_contextual[line('.')-1]
    elseif a:mode == 4
        echom b:anyfold_ind_buffer[line('.')-1]
    endif
endfunction
