# !/usr/bin/tclsh
#

dict set config ProjA vcsUrl "git@github.com:FuseCID/cidpocA.git"
dict set config ProjA branch master 1.1.0 1

dict set config ProjB vcsUrl "git@github.com:FuseCID/cidpocB.git"
dict set config ProjB branch master 1.1.0 1

dict set config ProjC vcsUrl "git@github.com:FuseCID/cidpocC.git"
dict set config ProjC branch master 1.1.0 1
dict set config ProjC branch next 1.1.0 2

dict set config ProjD vcsUrl "git@github.com:FuseCID/cidpocD.git"
dict set config ProjD branch master 1.1.0 1
dict set config ProjD branch next 1.1.0 2

dict set config ProjE vcsUrl "git@github.com:FuseCID/cidpocE.git"
dict set config ProjE branch master 1.1.0 1
dict set config ProjE branch next 1.1.0 2

proc mainMenu { argv } {
    while 1 {

	# Print the target env header
	puts "\nFuse CID"
	puts "========\n"

	puts "\[1] Config"
	puts "\[2] Modify"
	puts "\[3] Reset"
	puts "\[4] Exit"
	switch [promptForInteger "\n>" 1 4 1] 1 {
	    config
	} 2 {
	    modify
	} 3 {
	    reset
	} 4 {
	    puts "\nGood Bye!"
	    exit 0
	}
    }
}

proc config { } {
    set buildType [promptForString "\nBuildType: "]
    set config [configTreeByBuildType $buildType]
    puts [config2json $config]
}

proc modify { } {
    variable config

    set cap [promptForString "\nCapability: "]
    set cap "[string toupper [string range $cap 0 0]][string range $cap 1 end]"
    set char [string range $cap 0 0]
    set projId "Proj$char"

    if { ![dict exists $config $projId] } {
	puts "Project does not exist: $projId"
	return
    }

    set vcsUrl [dict get $config $projId "vcsUrl"]
    set workDir [gitCheckout $projId $vcsUrl "master"]

    set lines [list]

    # Read lines from capreq
    set resFile "$workDir/src/main/resources/org/fuse/cidpoc/[string tolower $char]/capreq"
    set fid [open $resFile]
    while { [gets $fid line] >= 0 } {
	lappend lines $line
    }
    close $fid

    set prov [lindex $lines 0]
    set msg "$prov => $cap"
    puts $msg

    if { ![promptForBoolean "Make this change: " 1] } {
	return;
    }

    # Write lines to capreq
    set fid [open $resFile "w"]
    puts $fid "provides: $cap"
    for { set i 1 } { $i < [llength $lines] } { incr i } {
	puts $fid [lindex $lines $i]
    }
    close $fid

    exec git add $resFile
    exec git commit -m $msg
    catch { exec git push origin } res; puts $res
}

proc reset { } {
    variable config

    if { ![promptForBoolean "Reset all projects" 0] } {
	return;
    }

    dict for { projId proj } $config {
	dict with proj {
	    dict for { vcsBranch data } $branch {
		set vcsTag [lindex $data 0]
		set offset [lindex $data 1]
		resetProject $projId $vcsUrl $vcsBranch $vcsTag $offset
	    }
	}
    }
}

# Private ========================

proc promptForBoolean {prompt default} {
    while 1 {
	if { bool($default) } {
	    puts -nonewline "$prompt (Y/n) "
	} else {
	    puts -nonewline "$prompt (y/N) "
	}
	flush stdout
	gets stdin ch
	if {[string is true -strict [string tolower $ch]] } {
	    return 1
	} elseif {[string is false -strict [string tolower $ch]]} {
	    return 0
	} elseif { $ch == "" } {
	    return $default
	}
    }
}

proc promptForInteger {prompt min max {default 0}} {
    while 1 {
	puts -nonewline "$prompt "
	if { $default != 0 } { puts -nonewline "\[$default]: " }
	flush stdout
	gets stdin ch
	if {$min <= $ch && $ch <= $max} {
	    return $ch
	} elseif {$ch == ""} {
	    return $default
	}
    }
}

proc promptForString {prompt {default ""}} {
    while 1 {
	puts -nonewline "$prompt "
	if { $default != "" } { puts -nonewline "\[$default]: " }
	flush stdout
	gets stdin line
	if { $line != "" } {
	    return $line
	} elseif { $default != "" } {
	    return $default
	}
    }
}

proc resetProject { projId vcsUrl vcsBranch vcsTag offset } {
    puts "\nProcessing $projId $vcsBranch"

    gitCheckout $projId $vcsUrl $vcsBranch

    # Delete all other tags
    foreach { tag } [exec git tag] {
	if { $tag ne $vcsTag } {
	    puts "Deleting tag $tag"
	    catch { exec git push origin :refs/tags/$tag }
	    catch { exec git tag -d $tag }
	}
    }
    set revs [exec git log --format="%h" --reverse --ancestry-path $vcsTag^..HEAD]
    set rev [lindex $revs $offset]
    catch { exec git reset --hard $rev }
    catch { exec git commit --amend --no-edit }
    if { $vcsBranch ne "master" } {
	catch { exec git rebase master }
    }
    catch { exec git push origin -f $vcsBranch } res; puts $res
}

# Main ========================

if { [string match "*/testsuite.tcl" $argv0] } {

    set scriptDir [file dirname [info script]]
    source $scriptDir/config.tcl
    source $scriptDir/release.tcl

    mainMenu $argv
}
