let s:save_cpo = &cpo
set cpo&vim

let s:V = vital#of('crystal')
let s:P = s:V.import('Process')
let s:J = s:V.import('Web.JSON')
let s:C = s:V.import('ColorEcho')

function! s:echo_error(msg, ...) abort
    echohl ErrorMsg
    if a:0 == 0
        echomsg a:msg
    else
        echomsg call('printf', [msg] + a:000)
    endif
    echohl None
endfunction

function! crystal_lang#tool(name, file, pos, option_str) abort
    let cmd = printf(
                \   '%s tool %s --no-color %s --cursor %s:%d:%d %s',
                \   g:crystal_compiler_command,
                \   a:name,
                \   a:option_str,
                \   a:file,
                \   a:pos[1],
                \   a:pos[2],
                \   a:file
                \ )

    let output = s:P.system(cmd)
    return {"failed": s:P.get_last_status(), "output": output}
endfunction

" `pos` is assumed a returned value from getpos()
function! crystal_lang#impl(file, pos, option_str) abort
    return crystal_lang#tool('implementations', a:file, a:pos, a:option_str)
endfunction

function! s:jump_to_impl(impl) abort
    execute 'edit' a:impl.filename
    call cursor(a:impl.line, a:impl.column)
endfunction

function! crystal_lang#jump_to_definition(file, pos) abort
    echo 'analyzing definitions under cursor...'

    let cmd_result = crystal_lang#impl(a:file, a:pos, '--format json')
    if cmd_result.failed
        return s:echo_error(cmd_result.output)
    endif

    let impl = s:J.decode(cmd_result.output)
    if impl.status !=# 'ok'
        return s:echo_error(impl.message)
    endif

    if len(impl.implementations) == 1
        call s:jump_to_impl(impl.implementations[0])
        return
    endif

    let message = "Multiple definitions detected.  Choose a number\n\n"
    for idx in range(len(impl.implementations))
        let i = impl.implementations[idx]
        let message .= printf("[%d] %s:%d:%d\n", idx, i.filename, i.line, i.column)
    endfor
    let message .= "\n"
    let idx = str2nr(input(message, "\n> "))
    call s:jump_to_impl(impl.implementations[idx])
endfunction

function! crystal_lang#context(file, pos, option_str) abort
    return crystal_lang#tool('context', a:file, a:pos, a:option_str)
endfunction

function! crystal_lang#type_hierarchy(file, option_str) abort
    let cmd = printf(
                \   '%s tool hierarchy --no-color %s %s',
                \   g:crystal_compiler_command,
                \   a:option_str,
                \   a:file
                \ )

    return s:P.system(cmd)
endfunction

function! s:find_completion_start() abort
    let c = col('.')
    if c <= 1
        return -1
    endif

    let line = getline('.')[:c-2]
    return match(line, '\w\+$')
endfunction

function! crystal_lang#complete(findstart, base) abort
    if a:findstart
        echom 'find start'
        return s:find_completion_start()
    endif

    let cmd_result = crystal_lang#context(expand('%'), getpos('.'), '--format json')
    if cmd_result.failed
        return
    endif

    let contexts = s:J.decode(cmd_result.output)
    if contexts.status !=# 'ok'
        return
    endif

    let candidates = []

    for c in contexts.contexts
        for [name, desc] in items(c)
            let candidates += [{
                        \   'word': name,
                        \   'menu': ': ' . desc . ' [var]',
                        \ }]
        endfor
    endfor

    return candidates
endfunction

function! crystal_lang#get_spec_switched_path(absolute_path) abort
    let base = fnamemodify(a:absolute_path, ':t:r')

    " TODO: Make cleverer
    if base =~# '_spec$'
        let parent = fnamemodify(substitute(a:absolute_path, '/spec/', '/src/', ''), ':h')
        return parent . '/' . matchstr(base, '.\+\ze_spec$') . '.cr'
    else
        let parent = fnamemodify(substitute(a:absolute_path, '/src/', '/spec/', ''), ':h')
        return parent . '/' . base . '_spec.cr'
    endif
endfunction

function! crystal_lang#switch_spec_file(...) abort
    let path = a:0 == 0 ? expand('%:p') : fnamemodify(a:1, ':p')
    if path !~# '.cr$'
        return s:echo_error('Not crystal source file: ' . path)
    endif

    execute 'edit!' crystal_lang#get_spec_switched_path(path)
endfunction

function! s:run_spec(root, path, ...) abort
    " Note:
    " `crystal spec` can't understand absolute path.
    let cmd = printf(
            \   '%s spec %s%s',
            \   g:crystal_compiler_command,
            \   a:path,
            \   a:0 == 0 ? '' : (':' . a:1)
            \ )

    " Note:
    " Currently `crystal spec` can't disable ANSI color sequence.
    let saved_cwd = getcwd()
    let cd = haslocaldir() ? 'lcd' : 'cd'
    try
        execute cd a:root
        call s:C.echo(s:P.system(cmd))
    finally
        execute cd saved_cwd
    endtry
endfunction

function! crystal_lang#run_all_spec(...) abort
    let path = a:0 == 0 ? expand('%:p:h') : a:1
    let dir = finddir('spec', path . ';')
    if dir ==# ''
        return s:echo_error("'spec' directory is not found")
    endif

    let spec_path = fnamemodify(dir, ':p:h')
    call s:run_spec(fnamemodify(spec_path, ':h'), fnamemodify(spec_path, ':t'))
endfunction

function! crystal_lang#run_current_spec(...) abort
    " /foo/bar/src/poyo.cr
    let path = a:0 == 0 ? expand('%:p') : fnamemodify(a:1, ':p')
    if path !~# '.cr$'
        return s:echo_error('Not crystal source file: ' . path)
    endif

    " /foo/bar/src
    let source_dir = fnamemodify(path, ':h')

    let dir = finddir('spec', source_dir . ';')
    if dir ==# ''
        return s:echo_error("'spec' directory is not found")
    endif

    " /foo/bar
    let root_dir = fnamemodify(dir, ':p:h:h')

    " src
    let rel_path = source_dir[strlen(root_dir)+1 : ]

    if path =~# '_spec.cr$'
        call s:run_spec(root_dir, path[strlen(root_dir)+1 : ], line('.'))
    else
        let spec_path = substitute(rel_path, '^src', 'spec', '') . '/' . fnamemodify(path, ':t:r') . '_spec.cr'
        if !filereadable(root_dir . '/' . spec_path)
            return s:echo_error("Error: Could not find a spec source corresponding to " . path)
        endif
        call s:run_spec(root_dir, spec_path)
    endif
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
