# !/usr/bin/tclsh
#

set sourceUrl "https://raw.githubusercontent.com/FuseCID/cidpoc"
set scriptPath "/master/scripts"

if { $argc < 1 } {
    puts "Usage:"
    puts "   $argv0 \[config|prmerge|release] args"
    return 1
}

# Create target dir
set scriptDir [file dirname [info script]]
set targetDir [file normalize $scriptDir/target]
file mkdir $targetDir

exec curl -H "Cache-Control: no-cache" -o $targetDir/config.tcl $sourceUrl$scriptPath/config.tcl 2> /dev/null
exec curl -H "Cache-Control: no-cache" -o $targetDir/prmerge.tcl $sourceUrl$scriptPath/prmerge.tcl 2> /dev/null
exec curl -H "Cache-Control: no-cache" -o $targetDir/release.tcl $sourceUrl$scriptPath/release.tcl 2> /dev/null

source $targetDir/config.tcl
source $targetDir/prmerge.tcl
source $targetDir/release.tcl

set cmd [lindex $argv 0]
set args [lrange $argv 1 end]
switch $cmd {
    "config" {
	configMain [llength $args] $args
    }
    "prmerge" {
	prmergeMain [llength $args] $args
    }
    "release" {
	releaseMain [llength $args] $args
    }
    default {
	puts "Unknown command: $cmd"
    }
}
