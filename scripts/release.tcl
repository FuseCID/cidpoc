# !/usr/bin/tclsh
#

# Require package rest
# https://core.tcl.tk/tcllib/doc/trunk/embedded/www/tcllib/files/modules/rest/rest.html
package require rest

set sourceDir [file dirname [info script]]
source $sourceDir/internal/config.tcl
source $sourceDir/internal/procs.tcl

if { $argc != 1 } {
    puts "Usage:"
    puts "   $argv0 projName"
    return 1
}

set projName [lindex $argv 0]

set res [tcRest /app/rest/buildTypes/id:${projName}_Build]
puts $res

