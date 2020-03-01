if exists('g:loaded_repmap')
    finish
endif
let g:loaded_repmap = 1

com -bar -nargs=? -complete=custom,repmap#listing#complete
    \ RepeatableMotions call repmap#listing#main(<q-args>)
