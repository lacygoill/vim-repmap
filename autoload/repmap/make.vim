if exists('g:autoloaded_repmap#make')
    finish
endif
let g:autoloaded_repmap#make = 1

" Init {{{1

" make sure `MapSave()` and `MapRestore()` are available
try
    import {MapSave, MapRestore} from 'lg/map.vim'
"     E1048: Item not found in script: Foobar
"     E1053: Could not import "foo/bar.vim"
catch /^Vim\%((\a\+)\)\=:E\%(1048\|1053\):/
    echohl ErrorMsg
    " Do not use `:throw` or `:echoerr`!{{{
    "
    " It could  cause a weird issue,  where an exception from  `vim-cookbook` is
    " unexpectedly not caught:
    "
    "     " temporarily disable vim-lg-lib in your vimrc
    "     " (and maybe vim-fold too to reduce the noise in the next errors)
    "     $ vim
    "     " ignore any error due to a missing "lg#()" function during startup
    "     :Cookbook MathIsPrime
    "     Error detected while processing function cookbook#main[20]...cookbook#notify:~
    "     line    2:~
    "     E117: Unknown function: lg#popup#notification~
    "
    " MWE:
    "
    "     $ vim -Nu NONE -S <(cat <<'EOF'
    "         fu Throw()
    "             try
    "                 throw 'some error'
    "             endtry
    "         endfu
    "         sil! call Throw()
    "         try
    "             call Unknown()
    "         catch
    "         endtry
    "     EOF
    "     )
    "     ...~
    "     E117: Unknown function: Unknown~
    "     " result:   'E117' is raised
    "     " expected: 'E117' is caught
    "
    " Update: This comment might no longer be relevant, but the MWE is still relevant.
    "}}}
    " Why `:unsilent`?{{{
    "
    " `#repeatable()` may be invoked from a filetype plugin.
    " And in that case, messages are silent.
    "}}}
    unsilent echom 'E8000: [repmap] the vim-lg-lib dependency is missing'
    echohl NONE
    finish
endtry

" Why not saving the last count to repeat it?{{{
"
" I rarely (never?) feel the need to repeat a count.
" Besides, the default `f` command does not repeat a count.
" Let's be consistent.
"}}}
let s:last_motion = ''

" database for global motions, which will be populated progressively
let s:repeatable_motions = []

let s:KEYCODES =<< trim END
    <BS>
    <Bar>
    <Bslash>
    <C-
    <CR>
    <Cmd>
    <Del>
    <Down>
    <End>
    <Esc>
    <F
    <Home>
    <Left>
    <M-
    <PageDown>
    <PageUp>
    <Plug>
    <Right>
    <S-
    <Space>
    <Tab>
    <Up>
    <lt>
END
let s:KEYCODES = join(s:KEYCODES, '\|')

let s:DEFAULT_MAPARG = {'buffer': 0, 'expr': 0, 'mode': ' ', 'noremap': 1, 'nowait': 0, 'silent': 0, 'script': 0}
"                                                   Why? ┘{{{
"
" This  variable will  be  used  to populate  information  about a  built-in
" motion, for which `maparg()` doesn't output anything.  We need to choose a
" character standing  for the default  mode we want.   As a default  mode, I
" want `nvo`, which  `maparg()` represents via a space when  its output is a
" dictionary.
"
" We need to be consistent with the output of `maparg()`.
"}}}

let s:RECURSIVE_MAPCMD = {
    \ 'n': 'nmap',
    \ 'x': 'xmap',
    \ 'o': 'omap',
    \ '' : 'map',
    \ }

let s:NON_RECURSIVE_MAPCMD = {
    \ 'n': 'nnoremap',
    \ 'x': 'xnoremap',
    \ 'o': 'onoremap',
    \ '' : 'noremap',
    \ }

" Necessary to avoid `<plug>(repeat-motion-tmp)` to be sometimes written literally into the buffer.{{{
"
" That can happen when we press something like `fx` then `c;` (assuming there is
" an `x` character in the buffer).
"
" You might  wonder how that's possible.   After all, when this  `feedkeys()` is
" invoked:
"
"     call feedkeys("\<plug>(repeat-motion-tmp)", 'i')
"
" We should be in operator-pending mode, right?
" Correct.  But,  remember that `feedkeys()`  only writes keys in  the typeahead
" buffer;  it   doesn't  execute  them.   When   `<plug>(repeat-motion-tmp)`  is
" processed, we might be in a different mode.
"
" You could  fix that by  passing the `x` flag  to `feedkeys()`, but  that would
" also cause Vim to press `Esc`, which is undesirable.
"}}}
ino <plug>(repeat-motion-tmp) <nop>

" Interface {{{1
fu repmap#make#repeatable(what) abort "{{{2
    " can make several motions repeatable

    " sanitize input
    if keys(a:what)->sort() !=# ['buffer', 'from', 'mode', 'motions']
        throw 'E8001: [repmap] missing key'
    endif

    for mode in (a:what.mode == '' ? [''] : split(a:what.mode, '\zs'))
        " Make the motions repeatable{{{
        "
        " We need to  install a wrapper mapping around each  motion, to save the
        " last used one.  Otherwise, how  the repeating mappings would know what
        " motion to repeat?
        "
        " We  also  need  a  database  of repeatable  motions,  with  all  their
        " information.  Otherwise, how  the repeating mappings would  be able to
        " emulate the original motion?
        "}}}
        let islocal = a:what.buffer
        let from = a:what.from
        for m in a:what.motions
            " Why this check?{{{
            "
            " If  the motion  is global,  one of  its lhs  could be  shadowed by
            " a  buffer-local  mapping  using  the same  lhs.   We  handle  this
            " particular case by temporarily removing the latter.
            "}}}
            if !islocal && (execute(mode .. 'map <buffer> ' .. m.bwd) !~# '^\n\nNo mapping found$'
                       \ || execute(mode .. 'map <buffer> ' .. m.fwd) !~# '^\n\nNo mapping found$')
                let map_save = s:MapSave([m.bwd, m.fwd], mode, v:true)
                call s:unshadow(m, mode)
                call s:make_repeatable(m, mode, islocal, from)
                call s:MapRestore(map_save)
            else
                call s:make_repeatable(m, mode, islocal, from)
            endif
        endfor

        " if not already done, install the `,` and `;` mappings to repeat the motions
        if maparg(',') !~# 'move_again('
            let mapcmd = mode .. 'noremap'
            exe mapcmd .. " , <cmd>call <sid>move_again('bwd')<cr>"
            exe mapcmd .. " ; <cmd>call <sid>move_again('fwd')<cr>"
        endif
    endfor
endfu

fu repmap#make#is_repeating() abort "{{{2
    return get(s:, 'is_repeating_motion', 0)
endfu
" }}}1
" Core {{{1
fu s:make_repeatable(m, mode, islocal, from) abort "{{{2
    " can only make ONE motion repeatable

    let bwd_lhs = a:m.bwd
    let fwd_lhs = a:m.fwd
    let bwd_maparg = s:maparg(bwd_lhs, a:mode, 0, 1, a:from)
    let fwd_maparg = s:maparg(fwd_lhs, a:mode, 0, 1, a:from)
    " Don't bail out if `s:maparg()` is empty.
    " We could be working on some default motion (`maparg()` has no info for that).
    if type(bwd_maparg) != v:t_dict || type(fwd_maparg) != v:t_dict
        return
    endif

    " if we ask for a local motion to be made repeatable,
    " the 2 lhs should be used in local mappings
    if a:islocal && (!get(bwd_maparg, 'buffer', 0) || !get(fwd_maparg, 'buffer', 0))
        throw 'E8002: [repmap] invalid motion: ' .. a:from
    endif

    " Could we install the wrapper mappings *before* populating `s:repeatable_motions`?{{{
    "
    " No.
    " It would  cause `s:populate()`  to capture the  definition of  the wrapper
    " mapping instead of the original motion.
    " So, when  we would press  a motion, we would  enter an infinite  loop: the
    " wrapper would call itself again and again, until E132.
    "
    " The fact  that the wrapper  mapping is, by default,  non-recursive doesn't
    " change  anything.   When  we  would  press the  lhs,  Vim  would  evaluate
    " `s:move('lhs')`.
    " At the end, Vim  would compute the keys to press: the  latter would be the
    " output of  `s:move('lhs')`.  That's  where the recursion  comes from.  It's
    " like pressing `cd`, where `cd` is defined like so:
    "
    "     nno <expr> cd Func()
    "     fu Func()
    "         return Func()
    "     endfu
    "}}}

    let origin = execute('verb ' .. a:mode .. 'map ' .. (a:islocal ? ' <buffer> ' : '') .. bwd_lhs)
        \ ->matchstr('.*\n\s*\zsLast set from.*')
    let motion = {
        \ 'made repeatable from': a:from,
        \ 'original mapping': origin,
        \ }
    " Why don't we write an assignment to populate `motion`?{{{
    "
    " `motion` is an array (!= scalar), so Vim passes it to `s:populate()`
    " as a REFERENCE (not as a VALUE), and the function operates in-place.
    " IOW: no need to write:
    "
    "     let motion = s:populate(motion, ...)
    "}}}
    call s:populate(motion, a:mode, bwd_lhs, 0, bwd_maparg)
    " now `motion` contains sth like:{{{
    "
    " {'bwd': {'expr': 0, 'noremap': 1, 'lhs': '...', 'mode': ' ', ...}}
    "                                                          │
    "                                                          └ nvo
    "}}}
    call s:populate(motion, a:mode, fwd_lhs, 1, fwd_maparg)
    " now `motion` contains sth like:{{{
    "
    " {'bwd': {'expr': 0, 'noremap': 1, 'lhs': '...', 'mode': ' ', ... },
    "  'fwd': {'expr': 0, 'noremap': 1, 'lhs': '...', 'mode': ' ', ... }}
    "}}}

    " Why?{{{
    "
    " `b:repeatable_motions` may not exist.  We must make sure it does.
    "
    " I don't want to automatically create it  in an autocmd.  I only want it if
    " necessary.
    "}}}
    " Ok, but why not `let repeatable_motions = get(b:, 'repeatable_motions', [])` ?{{{
    "
    " It  would  give  us  an  empty  list which  would  NOT  be  the  reference
    " to  `b:repeatable_motions`.    It  would   just  be  an   empty  list.
    "
    " We need  to update the *existing*  database of local motions,  not restart
    " from scratch.
    "}}}
    if a:islocal && !exists('b:repeatable_motions')
        let b:repeatable_motions = []
    endif

    " What does `repeatable_motions` contain?{{{
    "
    " A reference to a list of motions:  `[s:|b:]repeatable_motions`
    "}}}
    "   Why is it a reference, and not a value?{{{
    "
    " Vim *always* assigns a reference of an array to a variable, not its value.
    " So, `repeatable_motions`  contains a reference to  its script/buffer-local
    " counterpart.
    "}}}
    let repeatable_motions = {a:islocal ? 'b:' : 's:'}repeatable_motions

    if s:collides_with_db(motion, repeatable_motions)
        return
    endif

    call s:install_wrapper(a:mode,
        \ a:m,
        \ bwd_maparg,
        \ motion.bwd.rhs,
        \ motion.fwd.rhs
        \ )

    " add the motion in a db, so that we can retrieve info about it later;
    " in particular its rhs
    call add(repeatable_motions, motion)

    if a:islocal
        " Why?{{{
        "
        " When the filetype plugins are re-sourced (`:e`), Vim removes the local
        " mappings (`b:undo_ftplugin`).   But, our current plugin  hasn't erased
        " the repeatable wrappers from its database (b:repeatable_motions).
        "
        " We  must eliminate  the  database whenever  the  filetype plugins  are
        " resourced.  We could do it directly from the Vim filetype plugins, but
        " it  seems unreliable.   We'll undoubtedly  forget to  do it  sometimes
        " for  other  filetypes.   Instead,  the current  plugin  should  update
        " `b:undo_ftplugin`.
        "}}}
        call s:update_undo_ftplugin()
    endif
endfu

fu s:move(lhs, _) abort "{{{2
"              ^{{{
"              original rhs:
"              only used to make the output of `:map` more readable,
"              and still be able to find the mapping by looking for a keyword after running `:FzMaps`
"}}}
    let motion = s:get_motion_info(a:lhs)

    " if for some reason, no motion in the db matches `a:lhs`
    if type(motion) != v:t_dict
        return ''
    endif

    let dir = s:get_direction(a:lhs, motion)

    " Why don't you translate `a:lhs`?{{{
    "
    " No need to.
    " This function is used in the rhs of wrapper mappings:
    "
    "     exe mapcmd .. '  ' .. a:m.bwd .. '  <sid>move(' .. string(a:m.bwd) .. ')'
    "     exe mapcmd .. '  ' .. a:m.fwd .. '  <sid>move(' .. string(a:m.fwd) .. ')'
    "                                                        ├─────────────┘
    "                                                        └ automatically translated
    "
    " And mapping commands automatically translate special keys.
    "}}}
    let s:last_motion = a:lhs

    " Why don't you translate the special keys when the mapping uses `<expr>`?{{{
    "
    " Not necessary.
    " Because, the rhs is *not* a key sequence.  It's an *expression*.
    " It just needs to be evaluated.
    "
    " Ok, but don't we need to translate special Vim key codes in the evaluation?
    " Nope.
    " The evaluation  of the  rhs of  an `<expr>`  mapping must  *never* contain
    " special key  codes.  The expression  must take care of  returning feedable
    " keys itself.
    "}}}
    " Why do you need to translate them otherwise?{{{
    "
    " If the mapping doesn't use `<expr>`, the rhs is *not* fed directly.
    " But  `:nno`  &friends  automatically  translate any  special  key  in  the
    " rhs;  so we  need  to emulate  this  behavior, and  that's  why we  invoke
    " `s:translate()`.
    "}}}
    return motion[dir].expr
        \ ?     eval(motion[dir].rhs)
        \ :     s:translate(motion[dir].rhs)
endfu

fu s:move_again(dir) abort "{{{2
    " This function is called by various mappings whose suffix is `,` or `;`.

    " make sure the arguments are valid,
    " and that we've used at least one motion in the past
    if index(['bwd', 'fwd'], a:dir) == -1 || empty(s:last_motion)
        return
    endif

    let motion = s:get_motion_info(s:last_motion)
    " How could we get an unrecognized motion?{{{
    "
    " You have a motion defined in a given mode.
    " But `s:move_again()` is invoked to repeat it in a different mode.
    "
    " Or:
    " The last motion is  local to a buffer, you change the  buffer, and in this
    " one the motion doesn't exist...
    "}}}
    if type(motion) != v:t_dict
        return
    endif

    " What does this variable mean?{{{
    "
    " It's a numeric flag, whose value can be:
    "
    "    ┌────┬───────────────────────────────────────────┐
    "    │ 0  │ we are NOT going to repeat a motion       │
    "    ├────┼───────────────────────────────────────────┤
    "    │ -1 │ we are about to repeat a motion BACKWARDS │
    "    ├────┼───────────────────────────────────────────┤
    "    │ 1  │ we are about to repeat a motion FORWARDS  │
    "    └────┴───────────────────────────────────────────┘
    "}}}
    " Why do we set it now?{{{
    "
    " Suppose we've pressed `fx`, and now we want to repeat it with `;`.
    " In this case:
    "
    "     motion[a:dir].expr = 1
    "     motion[a:dir].rhs = <sid>fts()
    "                              │
    "                              └ custom function defined in another script
    "
    " The code in `s:fts()` is going to be evaluated, and the result typed as keys.
    " But, `s:fts()` needs to know whether we are pressing `f` to ask for a target,
    " or repeating a previous `fx`:
    "
    "     if repmap#make#is_repeating()
    "         " repeat last `fx`
    "         ...
    "     else
    "         " ask for a target, then press `f{target}`
    "         ...
    "     endif
    "}}}
    let s:is_repeating_motion = a:dir is# 'fwd' ? 1 : -1

    " Why not returning the sequence of keys directly?{{{
    "
    " The original  motion could be  silent or recursive; blindly  returning the
    " keys could alter these properties.
    "
    " As an  example, the `;`  and `,` mappings are  non-recursive (`:noremap`),
    " because that's what we want by default.  However, for some motions, we may
    " need recursiveness.
    "
    " Example: `]e` to move the line down.
    "
    " Therefore, if we  returned the sequence directly, it  wouldn't be expanded
    " even when  it needs to  be.  So,  we use `feedkeys()`  to write it  in the
    " typeahead  buffer  recursively or  non-recursively  depending  on how  the
    " original motion was defined.
    "
    " And if the  original mapping was silent, the wrapper should be too.
    " IOW, if the rhs is an Ex command, it shouldn't be displayed on the command
    " line.
    "}}}
    " To emulate `<silent>`, why not simply `:redraw!`?{{{
    "
    "    - overkill
    "
    "    - If the motion wants to echo a message, it will probably be erased.
    "      That's not what `<silent>` does.
    "      `<silent>` only prevents the rhs from being  echo'ed.
    "      But it can still display a message if it wants to.
    "
    "    - Sometimes, the command-line seems to flicker.
    "      Currently,  it  happens when  we  cycle  through the  levels  of
    "      lightness of the colorscheme (`]oL  co;  ;`).
    "}}}
    exe s:get_current_mode() .. (!motion[a:dir].noremap ? 'map' : 'noremap')
        \ .. (motion[a:dir].nowait ? ' <nowait>' : '')
        \ .. (motion[a:dir].expr ? ' <expr>' : '')
        \ .. (motion[a:dir].silent ? ' <silent>' : '')
        \ .. (motion[a:dir].script ? ' <script> ' : '')
        \ .. ' <plug>(repeat-motion-tmp) '
        \ .. motion[a:dir].rhs

    call feedkeys("\<plug>(repeat-motion-tmp)", 'i')

    " Why do we reset this variable?{{{
    "
    " It's for  a custom function which  we could define to  implement a special
    " motion like `fFtTssSS`.  Similar to what we have to do in `s:fts()`.
    "
    " `tTfFssSS` are  special because  the lhs, which  is saved  for repetition,
    " doesn't  contain the  necessary  character  which must  be  passed to  the
    " command.  IOW, when the last motion  was `fx`, `f` is insufficient to know
    " where to move.
    "}}}
    call timer_start(0, {-> execute('let s:is_repeating_motion = 0')})
endfu

fu s:populate(motion, mode, lhs, is_fwd, maparg) abort "{{{2
    let dir = a:is_fwd ? 'fwd' : 'bwd'

    " make a custom mapping repeatable
    if !empty(a:maparg)
        let a:motion[dir] = a:maparg
        " Why?{{{
        "
        " `a:maparg` was obtained via `maparg()`.
        " The latter automatically translates `<C-j>` into `<NL>`.
        " This will break mappings whose lhs contains `<C-j>` (e.g. `z C-j`).
        "}}}
        if a:motion[dir].lhs =~# '\C<NL>'
            let a:motion[dir].lhs =
                \ substitute(a:motion[dir].lhs, '\C<NL>', "\<c-j>", 'g')
        endif

    " make a built-in motion repeatable
    else
        let a:motion[dir] = deepcopy(s:DEFAULT_MAPARG)
            \ ->extend({'mode': empty(a:mode) ? ' ' : a:mode})
        "                    Why? ┘{{{
        "
        " Because if `maparg()`  doesn't give any info, we want  to fall back on
        " the mode `nvo`.  And to be  consistent, we want to populate our motion
        " with exactly  the same info that  `maparg()` would give for  `nvo`: an
        " empty space.
        "
        " So, if we initially passed the  mode `''` when we invoked the function
        " to make some motions repeatable, we now  want to use `' '` to populate
        " the database of repeatable motions.
        "
        " This inconsistency between `''` and `' '` mimics the one found in `maparg()`.
        " For `maparg()`, `nvo` is represented with:
        "
        "    - an empty string in its input
        "    - a single space in its output
        "}}}
        let a:motion[dir].lhs = a:lhs
        let a:motion[dir].rhs = a:lhs
    endif

    " we save the lhs keysequence, unmodified, so that `:RepeatableMotions`
    " has something readable to display
    let a:motion[dir].untranslated_lhs = a:motion[dir].lhs

    " We now translate it to normalize its form.{{{
    "
    " `a:motion[dir].lhs` comes from `repmap#make#repeatable()`.
    " Its form depends on how the user wrote the motion.
    " Example:
    "
    "     Z<c-l>
    "     Z<C-L>
    "
    " ... are different, but both describe the same keysequence.
    "
    " This difference  may cause an  issue later,  when we make  some comparison
    " between the lhs of a motion and some keysequence.
    " We must make sure that we're always comparing the same (translated) form.
    "}}}
    let a:motion[dir].lhs = s:translate(a:motion[dir].lhs)
endfu
" }}}1
" Util {{{1
fu s:collides_with_db(motion, repeatable_motions) abort "{{{2
    " Purpose:{{{
    "
    " Detect whether the motion we're trying  to make repeatable collides with
    " a motion in the db.
    "}}}
    " When does a collision occur?{{{
    "
    " When `a:motion` is already in the db (TOTAL collision).
    " Or when a motion in the db has the same mode as `a:motion`, and one of its
    " `lhs` key has the same value as one of `a:motion` (PARTIAL collision).
    "}}}
    " Why is a collision an issue?{{{
    "
    " If you try to install a wrapper around a key which has already been wrapped,
    " you'll probably end up losing the original definition:
    " in the db, it may be replaced by the one of the first wrapper.
    "
    " Besides:
    " Vim shouldn't make a motion repeatable twice (total collision).
    " Because  it means  we  have a  useless  invocation of  `repmap#make#repeatable()`
    " somewhere in our config; it should be removed.
    "
    " Vim shouldn't change the motion to which a lhs belongs (partial collision).
    " For example, suppose that:
    "
    "    - we make this motion repeatable: `[m` + `]m`
    "    - and we try to make this other motion repeatable: `[m` + `]]`
    "
    " We've probably made an error.  We should be warned so that we can fix it.
    "}}}

    "   ┌ Motion
    "   │
    for m in a:repeatable_motions
        if [m.bwd.lhs, m.bwd.mode] ==# [a:motion.bwd.lhs, a:motion.bwd.mode]
        \ || [m.fwd.lhs, m.fwd.mode] ==# [a:motion.fwd.lhs, a:motion.fwd.mode]
            try
                throw printf('E8003: [repmap] cannot process motion  %s : %s',
                    \ m.bwd.lhs, m.fwd.lhs)
            finally
                return 1
            endtry
        endif
    endfor
    return 0
endfu

fu s:get_current_mode() abort "{{{2
    " Why the substitutions?{{{
    "
    "     mode(1)->substitute("[vV\<c-v>]", 'x', ''):
    "
    "         normalize output of `mode()` to match the one of `maparg()`
    "         in case we're in visual mode
    "
    "     substitute(..., 'no', 'o', '')
    "
    "         same thing for operator-pending mode
    "}}}
    return mode(1)->substitute("[vV\<c-v>]", 'x', '')->substitute("no[vV\<c-v>]\\=", 'o', '')
endfu

fu s:get_direction(lhs, motion) abort "{{{2
    "            ┌ no need to translate: it has been translated in a mapping
    "            │         ┌ no need to translate: it has been translated in `s:populate()`
    "            │         │
    let is_fwd = a:lhs is# a:motion.fwd.lhs
    return is_fwd ? 'fwd' : 'bwd'
endfu

fu s:get_mapcmd(mode, maparg) abort "{{{2
    "                 ┌ the value of the 'noremap' key stands for the NON-recursiveness{{{
    "                 │ but we want a flag standing for the recursiveness
    "                 │ so we need to invert the value of the key
    "                 │
    "                 │                         ┌ by default, we don't want
    "                 │                         │ a recursive wrapper mapping
    "                 │                         │}}}
    let isrecursive = !get(a:maparg, 'noremap', 1)

    let mapcmd = s:{isrecursive ? '' : 'NON_'}RECURSIVE_MAPCMD[a:mode]
    let mapcmd ..= ' <expr>'
    let mapcmd ..= map(['buffer', 'nowait', 'silent', 'script'],
        \ {_, v -> get(a:maparg, v, 0) ? '<' .. v .. '>' : ''})
        \ ->join()

    return mapcmd
endfu

fu s:get_motion_info(lhs) abort "{{{2
    " Purpose:{{{
    " return the info about the motion in the db:
    "
    "    - which contains `a:lhs` (no matter for which direction)
    "    - whose mode is identical to the one in which we currently are
    "}}}

    let mode = s:get_current_mode()
    let motions = maparg(a:lhs, mode, 0, 1)->get('buffer', 0)
        \ ? get(b:, 'repeatable_motions', [])
        \ : s:repeatable_motions

    for m in motions
        " Why don't you translate `a:lhs` to normalize it?{{{
        "
        " No need to.
        "
        " The current function is called from:
        "
        "    - `s:move()`
        "    - `s:move_again()`
        "
        " In `s:move()`, `s:get_motion_info()` is passed a keysequence which has
        " been translated automatically  because `s:move()` was in the  rhs of a
        " mapping.
        "
        " In  `s:move_again()`, `s:get_motion_info()`  is  passed a  keysequence
        " from `s:last_motion`.  The keysequence saved  in the latter is already
        " translated.
        "}}}
        " Same question for `m.bwd.lhs` and `m.fwd.lhs`?{{{
        "
        " No need to.
        " We've done it already in `s:populate()`.
        "}}}
        if index([m.bwd.lhs, m.fwd.lhs], a:lhs) >= 0
        \ && index([mode, ' '], m.bwd.mode) >= 0
        "                       ├────────┘
        "                       └ mode of the motion:
        "                         originally obtained with `maparg()`
        "
        " Why this last condition? {{{
        "
        " We only pass a lhs to this function.  So, without this condition, when
        " the function would  try to find the relevant info  in the database, it
        " wouldn't care about the mode of the motion.
        " It would  stop searching as  soon as it would  find one which  has the
        " right lhs.  It's wrong; it should also care about the mode.
        "
        " Here's what could happen:
        "
        "    1. go to a function containing a `:return` statement
        "    2. enter visual mode
        "    3. press `%` on `fu`
        "    4. press `;`
        "    5. press Escape
        "    6. press `;`
        "
        " Now `;` makes  us enter visual mode.  It shouldn't.   We want a motion
        " in normal mode.
        "}}}
        " Why a single space?{{{
        "
        " `m.bwd.mode` could  be a  space, if the  original mapping  was defined
        " with `:noremap` or `:map`.  But `mode`  will never be a space, because
        " it gets its value from `mode(1)`, which will return:
        "
        "     'n', 'v', 'V', 'C-v' or 'no'
        "
        " So, we need to compare `m.bwd.mode` to the current mode, AND to a space.
        "}}}
            return m
        endif
    endfor
endfu

fu s:install_wrapper(mode, m, maparg, orig_rhs_bwd, orig_rhs_fwd) abort "{{{2
    " Why do you pass the original rhs of the mappings to `s:move()`?{{{
    "
    " `s:move()` doesn't need it.
    " But it makes the output of `:map` more readable:
    "
    "     " wtf does this mapping?
    "     n  >t          * <SNR>145_move('>t')
    "
    "     " ok, this mapping moves a tab page
    "     n  >t          * <SNR>145_move('>t', '<Cmd>call <SNR>144_move_tabpage(''+1'')<CR>')
    "
    " And more  useful; without the  original rhs,  it's impossible to  find the
    " `>t` mapping by  looking for the keyword "tab" or  "tabpage" after running
    " `:FzMaps`.
    "}}}
    let mapcmd = s:get_mapcmd(a:mode, a:maparg)
    exe printf('%s %s <sid>move(%s, %s)', mapcmd, a:m.bwd, string(a:m.bwd), string(a:orig_rhs_bwd))
    exe printf('%s %s <sid>move(%s, %s)', mapcmd, a:m.fwd, string(a:m.fwd), string(a:orig_rhs_fwd))
endfu

fu s:maparg(name, mode, abbr, dict, from) abort "{{{2
    let maparg = maparg(a:name, a:mode, a:abbr, a:dict)
    " Why this guard?{{{
    "
    " If `maparg()` is empty, we're working on a built-in motion.
    " It doesn't make sense to allow the  next `extend()` to include a `rhs` key
    " in the output dictionary.
    "
    " If you allow it, `s:populate()` will raise `E716`.
    "
    "     E716: Key not present in Dictionary: lhs ...~
    "
    " This is because  `s:populate()` will wrongly think that it's  working on a
    " custom motion instead of a built-in one.
    "}}}
    if empty(maparg) | return {} | endif

    " There could be a mismatch between the mode you asked, and the one `maparg()` gives you.{{{
    "
    " This issue should arise only when you're working with a "pseudo-mode".
    " That is a collection of real modes.
    "
    " For example, you could try to make a motion repeatable in normal mode, but
    " if the motion was defined  with `:[nore]map`, then `maparg(...).mode` will
    " be a space and not `n`.
    " Similarly, you could try to make a motion repeatable in `nvo` mode, but if
    " the motion  was only  defined with `:n[nore]map`,  then `maparg(...).mode`
    " will be `n` and not a space.
    "
    " It would probably  be difficult to handle such cases,  so we don't bother;
    " we just bail out, and give a warning message to the user, so that they can
    " fix their function call; all they have to do, is to use the correct mode:
    "
    "    - if the motion is defined in `nvo` mode, then they should pass an empty string
    "    - if the motion is defined in `n` mode, then they should pass the `'n'` string
    "    ...
    "
    " Note that you may have a motion defined in a pseudo-mode for which there's
    " no mapping command:
    "
    "     noremap <c-q> <esc>
    "     nunmap <c-q>
    "     map <c-q>
    "     ov <C-Q>       * <Esc>~
    "     ^^
    "
    " Such a motion can't be made repeatable.
    " Again, we don't bother handling this corner case.
    " You  should not  have such  a motion  in your  config; if  you do,  try to
    " install it properly via several mapping commands.
    " You can also try to run this:
    "
    "     " `#restore()` should reinstall the motion via several mapping commands
    "     call s:MapSave('<c-q>')->s:MapRestore()
    "     map <c-q>
    "     o  <C-Q>       * <Esc>~
    "     v  <C-Q>       * <Esc>~
    "}}}
    if a:mode != maparg.mode && !(a:mode == '' && maparg.mode == ' ')
    "                            ├──────────────────────────────────┘
    "                            └ this mismatch does not cause any issue; ignore it
        echohl ErrorMsg
        " `unsilent` in case the repmap function was invoked with `sil!` (to suppress any error when it doesn't exist)
        unsilent echom printf("%s can't be made repeatable in '%s' mode; it's defined in '%s' mode",
            \ a:name, {'': 'nvo', 'v': 'v'}[a:mode], maparg.mode)
        unsilent echom '    ' .. a:from
        echohl NONE
        return 1
    endif

    " Why do you overwrite the `rhs` key?  And why do you do re-invoke `maparg()` a second time?{{{
    "
    " To make sure `<SID>` is translated.
    "
    " In the `rhs` key, `<SID>` is *not* translated.
    " OTOH, if you don't provide the `{dict}` argument, `<SID>` *is* translated.
    "}}}
    " Why do you replace `|` with `<bar>`?{{{
    "
    " This `rhs` key will be used in `s:move()` and `s:move_again()`.
    " Atm, a bar does not need to be escaped for `s:move()`.
    " But it does for `s:move_again()`.
    "
    " The easiest way to support those 2 cases, is to just replace a bar with `<bar>`.
    " `s:move()` will translate it into a literal bar via `s:translate()`.
    " And `s:move_again()` will also translate it via an ad-hoc temporary mapping.
    "}}}
    call extend(maparg, {'rhs': maparg(a:name, a:mode)->substitute('|', '<bar>', 'g')})
    return maparg
endfu

fu repmap#make#share_env() abort "{{{2
    return s:repeatable_motions
endfu

fu s:translate(seq) abort "{{{2
    " Purpose:{{{
    " When  we  populate  the  database   of  repeatable  motions,  as  well  as
    " `s:last_motion`,  we   need  to   get  a  normalized   form  of   the  lhs
    " keysequence(s).  So that future comparisons are reliable.
    "
    " For more info, see the comment at the end of `s:populate()`.
    "
    " Also:
    " The keysequence  returned by `s:move()`  is directly fed to  the typeahead
    " buffer.  If it contains special key codes, they must be translated.
    "}}}
    "                             ┌ to not break the string passed to `eval()` prematurely
    "                             │
    "                             │┌ to prevent a real backslash contained in the sequence
    "                             ││ from being removed by `eval("...")`
    "                             ││
    return ('"' .. escape(a:seq, '"\')
        \ ->substitute('\m\c\ze\%(' .. s:KEYCODES .. '\)', '\\', 'g') .. '"')
        \ ->eval()
endfu

fu s:unshadow(m, mode) abort "{{{2
    exe 'sil! ' .. a:mode .. 'unmap <buffer> ' .. a:m.bwd
    exe 'sil! ' .. a:mode .. 'unmap <buffer> ' .. a:m.fwd
endfu

fu s:update_undo_ftplugin() abort "{{{2
    if get(b:, 'undo_ftplugin', '')->stridx('unlet! b:repeatable_motions') == -1
        let b:undo_ftplugin = get(b:, 'undo_ftplugin', 'exe')
            \ .. '| unlet! b:repeatable_motions'
    endif
endfu

