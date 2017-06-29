# !/usr/bin/tclsh
#

if { $argc < 5 } {
    puts "Usage:"
    puts "   tclsh switch.tcl -baseUrl baseUrl -cmd \[config|prmerge|prepare|release] args"
    puts "   e.g. tclsh switch.tcl -baseUrl https://raw.githubusercontent.com/FuseCID/cidpoc/master/scripts -cmd config args"

    return 1
}

set baseUrl [dict get $argv "-baseUrl"]
set cmd [dict get $argv "-cmd"]

set args [dict remove $argv "-baseUrl" ]
switch $cmd {
    "config" {
	exec curl -H "Cache-Control: no-cache" $baseUrl/config.tcl > config.tcl 2> /dev/null
	source config.tcl
	configMain $args
    }
    "prmerge" {
	exec curl -H "Cache-Control: no-cache" $baseUrl/prmerge.tcl > prmerge.tcl 2> /dev/null
	source prmerge.tcl
	prmergeMain $args
    }
    "prepare" {
	exec curl -H "Cache-Control: no-cache" $baseUrl/config.tcl > config.tcl 2> /dev/null
	exec curl -H "Cache-Control: no-cache" $baseUrl/release.tcl > release.tcl 2> /dev/null
	source config.tcl
	source release.tcl
	prepareMain $args
    }
    "release" {
	exec curl -H "Cache-Control: no-cache" $baseUrl/config.tcl > config.tcl 2> /dev/null
	exec curl -H "Cache-Control: no-cache" $baseUrl/release.tcl > release.tcl 2> /dev/null
	source config.tcl
	source release.tcl
	releaseMain $args
    }
    default {
	puts "Unknown command: $cmd"
	exit 1
    }
}
