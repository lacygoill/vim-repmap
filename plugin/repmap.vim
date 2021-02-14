vim9script noclear

if exists('loaded') | finish | endif
var loaded = true

com -bar -nargs=? -complete=custom,repmap#listing#complete
    \ RepeatableMotions repmap#listing#main(<q-args>)
