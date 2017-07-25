# !/usr/bin/tclsh
#

dict set config ProjA vcsUrl "git@github.com:FuseCID/cidpocA.git"
dict set config ProjA vcsRef 1.1.0 1 master

dict set config ProjB vcsUrl "git@github.com:FuseCID/cidpocB.git"
dict set config ProjB vcsRef 1.1.0 1 master

dict set config ProjC vcsUrl "git@github.com:FuseCID/cidpocC.git"
dict set config ProjC vcsRef 1.1.0 1 master next

dict set config ProjD vcsUrl "git@github.com:FuseCID/cidpocD.git"
dict set config ProjD vcsRef 1.1.0 1 master next

dict set config ProjE vcsUrl "git@github.com:FuseCID/cidpocE.git"
dict set config ProjE vcsRef 1.1.0 1 master next

proc mainMenu { argv } {
    while 1 {

        # Print the target env header
        puts "\nFuse CID"
        puts "========\n"

        puts "\[1] Config"
        puts "\[2] Modify"
        puts "\[3] Release"
        puts "\[4] Reset"
        puts "\[5] Exit"
        switch [promptForInteger "\n>" 1 5 1] 1 {
            doConfig
        } 2 {
            doModify
        } 3 {
            doRelease
        } 4 {
            doReset
        } 5 {
            puts "\nGood Bye!"
            exit 0
        }
    }
}

proc doConfig { } {
    set buildType [promptForString "\nBuildType: "]
    set config [configTreeByBuildType $buildType]
    puts [config2json $config]
}

proc doModify { } {
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
    set workDir [gitCloneOrCheckout $projId $vcsUrl]

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

proc doRelease { } {
    set buildType [promptForString "\nBuildType: "]
    set config [configTreeByBuildType $buildType]
    release $config
}

proc doReset { } {
    variable config

    if { ![promptForBoolean "Reset all projects" 0] } {
        return;
    }

    dict for { projId proj } $config {
        dict with proj {
            dict for { rev data } $vcsRef {
                set offset [lindex $data 0]
                set branches [lindex $data 1]
                resetProject $projId $vcsUrl $rev $offset $branches
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

proc resetProject { projId vcsUrl vcsRef offset branches } {
    puts "\nProcessing $projId"

    gitCloneOrCheckout $projId $vcsUrl
    catch { exec git fetch origin --tags }

    # Delete all other tags
    foreach { tag } [exec git tag] {
        if { $tag ne $vcsRef } {
            puts "Deleting tag $tag"
            catch { exec git push origin :refs/tags/$tag }
            catch { exec git tag -d $tag }
        }
    }
    set revs [exec git log --format="%h" --reverse --ancestry-path $vcsRef^..HEAD]
    set rev [lindex $revs $offset]
    foreach { branch } $branches {
        gitCheckout $projId $branch
        catch { exec git reset --hard $rev }
        if { $branch eq "master" } {
            catch { exec git commit --amend --no-edit }
            set rev [exec git rev-parse HEAD]
        }
        catch { exec git push origin -f $branch } res; puts $res
    }
}

# Main ========================

if { [string match "*/testsuite.tcl" $argv0] } {

    set scriptDir [file dirname [info script]]
    source $scriptDir/config.tcl
    source $scriptDir/release.tcl

    mainMenu $argv
}
