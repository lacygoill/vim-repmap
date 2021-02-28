vim9script noclear

if exists('loaded') | finish | endif
var loaded = true

# Init {{{1

const REPEATABLE_MOTIONS: list<dict<any>> = repmap#make#shareEnv()
const MODE2LETTER: dict<string> = {normal: 'n', visual: 'x', operator-pending: 'no', nvo: ' '}

# Interface {{{1
def repmap#listing#complete( #{{{2
    arglead: string,
    cmdline: string,
    pos: number
    ): string
    var from_dash_to_cursor: string = matchstr(cmdline, '.*\s\zs-.*\%' .. (pos + 1) .. 'c')
    if from_dash_to_cursor =~ '-mode\s\+\w*$'
        var modes: list<string> =<< trim END
            normal
            visual
            operator-pending
            nvo
        END
        return join(modes, "\n")

    elseif from_dash_to_cursor =~ '-scope\s\+\w*$'
        return "local\nglobal"

    elseif empty(arglead) || arglead[0] == '-'
        var opt: list<string> =<< trim END
            -mode
            -scope
            -v
            -vv
        END
        return join(opt, "\n")
    endif

    return ''
enddef

def repmap#listing#main(args: string) #{{{2
    # get the asked options
    var cmd_args: list<string> = split(args)
    var opt: dict<any> = {
        mode: matchstr(args, '-mode\s\+\zs[-a-z]\+'),
        scope: matchstr(args, '-scope\s\+\zs\w\+'),
        verbose1: index(cmd_args, '-v') >= 0,
        verbose2: index(cmd_args, '-vv') >= 0,
        }
    # if we add too many `v` flags by accident, we still want the maximum verbosity level
    if match(args, '-vvv\+') >= 0
        opt.verbose2 = true
    endif
    opt.mode = has_key(MODE2LETTER, opt.mode) ? MODE2LETTER[opt.mode] : ''

    # get the text to display
    listing = {global: [], local: []}
    PopulateListing(opt)

    # display it
    var excmd: string = 'RepeatableMotions ' .. args
    debug#log#output({excmd: excmd, lines: GetLines()})
    CustomizePreviewWindow()
enddef
var listing: dict<list<string>>
# }}}1
# Core {{{1
def PopulateListing(opt: dict<any>) #{{{2
    var lists: list<list<dict<any>>> = opt.scope == 'local'
            ?     [get(b:, 'repeatable_motions', [])]
            : opt.scope == 'global'
            ?     [REPEATABLE_MOTIONS]
            :     [get(b:, 'repeatable_motions', []), REPEATABLE_MOTIONS]

    for a_list in lists
        var scope: string = a_list == REPEATABLE_MOTIONS ? 'global' : 'local'
        for m in a_list
            if !empty(opt.mode) && opt.mode != m.bwd.mode
                continue
            endif

            AddTextToWrite(opt, m, scope)
        endfor
    endfor
enddef

def AddTextToWrite(opt: dict<any>, m: dict<any>, scope: string) #{{{2
    var text: string = printf('  %s  %s | %s',
        m.bwd.mode, m.bwd.untranslated_lhs, m.fwd.untranslated_lhs)
    text ..= opt.verbose1
        ?     '    ' .. m['original mapping']
        :     ''

    # Why a list of strings, and not a string?{{{
    #
    # Because eventually, we're going to write the text via `debug#log#output()`
    # which itself invokes `writefile()`.  And the latter writes "\n" as a NUL.
    # The only way to  make `writefile()` write a newline is  to split the lines
    # into several list items.
    #}}}
    var lines: list<string> = [text]
    if opt.verbose2
        lines += ['       ' .. m['original mapping']]
            + ['       Made repeatable from ' .. m['made repeatable from']]
            + ['']
    endif

    extend(listing[scope], lines)
enddef

def GetLines(): list<string> #{{{2
    if empty(listing.global) && empty(listing.local)
        return []
    else
        var lines: list<string>
        for scope in ['global', 'local']
            if !empty(listing[scope])
                lines += ['', scope, '']
                for a_line in listing[scope]
                    lines += [a_line]
                endfor
            endif
        endfor
        return lines
    endif
enddef
# }}}1
# Misc. {{{1
def CustomizePreviewWindow() #{{{2
    if &l:pvw
        matchadd('Title', '^Motions repeated with:', 0)
        matchadd('SpecialKey', '^\%(global\|local\)$', 0)

        nno <buffer><nowait> ]] <cmd>call search('^\%(Motions\<bar>local\<bar>global\)')<cr>
        nno <buffer><nowait> [[ <cmd>call search('^\%(Motions\<bar>local\<bar>global\)', 'b')<cr>
        sil! :1/^Motions/
    endif
enddef

