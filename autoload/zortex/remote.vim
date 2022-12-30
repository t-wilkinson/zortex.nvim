function! s:ssh(command) abort
    return jobstart('ssh ' . g:zortex_remote_server . ' -f  "cd ' . g:zortex_remote_server_dir . '; ls; ' . escape(a:command, '\"') . '"')
endfunction

function! s:rsync(local, remote) abort
    function! s:OnError(id, data, event)
        if a:data[0] == '' " eof
            return
        endif
        echoerr join(a:data, "\n")
    endfunction

    if a:local[0] == '/'
        return jobstart('rsync -azr --update --delete ' . a:local . ' ' . a:remote, {'on_stderr': function('s:OnError') })
    else
        return jobstart('rsync -azr --update --delete ' . g:zortex_root_dir . '/' . a:local . ' ' . a:remote, {'on_stderr': function('s:OnError') })
    endif
endfunction

function! s:save_env_variables() abort
    let env_variables = {
                \ "PORT": g:zortex_remote_wiki_port,
                \ "EXTENSION": g:zortex_extension,
                \ "NOTES_DIR": g:zortex_remote_server_dir . '/notes'
                \ }
    let exports = map(items(l:env_variables), {_, x -> x[0].'='.x[1]})
    call writefile(l:exports, g:zortex_root_dir . '/app/.env.remote')
endfunction

function! zortex#remote#sync() abort
    let ids = []
    function! Sync(local, remote) closure
        let l:ids += [s:rsync(a:local, a:remote)]
    endfunction

    let remote_root = g:zortex_remote_server.':'.g:zortex_remote_server_dir.'/'

    " env variables
    call Sync('app/.env.remote', remote_root.'.env')

    " notes dir
    call Sync(g:zortex_notes_dir.'/', remote_root.'notes')

    " static files
    call Sync('app/_static', remote_root)
    call Sync('app/out', remote_root)

    " remote server
    call Sync('app/remote.js', remote_root)
    call Sync('app/bin', remote_root)

    " libraries
    call Sync('app/lib', remote_root)
    call Sync('node_modules', remote_root)

    return ids
endfunction

function! zortex#remote#stop_server() abort
    call s:ssh('fuser -k ' . g:zortex_remote_wiki_port . '/tcp')
endfunction

function! zortex#remote#start_server() abort
    " asume linux server for now
    call s:ssh('./bin/zortex-linux --path ' . g:zortex_remote_server_dir . '/remote.js')
endfunction

function! zortex#remote#restart_server() abort
    call s:save_env_variables()
    call jobwait(zortex#remote#sync())
    call jobwait(zortex#remote#stop_server())
    call jobwait(zortex#remote#start_server())
endfunction
