# Checks Tcl brace/quote completeness without executing Vivado commands.

if {[llength $argv] == 0} {
    puts stderr "usage: tclsh check_tcl_syntax.tcl FILE..."
    exit 2
}

foreach path $argv {
    set stream [open $path r]
    set content [read $stream]
    close $stream
    if {![info complete $content]} {
        puts stderr "incomplete Tcl syntax: $path"
        exit 1
    }
    puts "TCL_SYNTAX_OK=$path"
}
