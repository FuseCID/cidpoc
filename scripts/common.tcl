# !/usr/bin/tclsh
#

set checkoutDir [file normalize [pwd]/.checkout]

# Checkout the specified revision and change to the resulting workdir
proc gitCheckout { projId rev } {
    variable checkoutDir
    cd [file normalize $checkoutDir/$projId]
    logDebug "Checkout $projId [gitHash $rev] [gitSubject $rev]"
    catch { exec git checkout $rev } res;
    return [pwd]
}

# Clone or checkout the specified branch and change to the resulting workdir
proc gitClone { projId vcsUrl { vcsBranch "master" } { remote "origin" } } {
    variable checkoutDir
    set workDir [file normalize $checkoutDir/$projId]
    if { [file exists $workDir] } {
        cd $workDir
        catch { exec git clean --force } res
        catch { exec git fetch --force $remote } res
        catch { exec git checkout $vcsBranch } res
        catch { exec git reset --hard $remote/$vcsBranch } res
    } else {
        file mkdir $workDir/..
        if { [catch { exec git clone -b $vcsBranch $vcsUrl $workDir } res] } {
            logInfo $res
        }
        cd $workDir
    }
    return $workDir
}

proc gitCommit { msg } {
    logInfo "Commit: \[fuse-cid] $msg"
    exec git commit -m "\[fuse-cid] $msg"
}

proc gitCreateBranch { newBranch } {
    catch { exec git checkout -B $newBranch } res;
    logInfo $res
    return $newBranch
}

proc gitDeleteBranch { delBranch } {
    logInfo "Delete branch: $delBranch"
    catch { exec git push origin --delete $delBranch }
    catch { exec git branch -D $delBranch }
}

proc gitHash { rev } {
    return [exec git log -n 1 --pretty=%h $rev]
}

proc gitIsReachable { target from } {
    if { [gitHash $target] eq [gitHash $from] } {
        return 1
    }
    set revs [split [exec git rev-list $target^..$from]]
    if { [llength $revs] < 1 } {
        return 0
    }
    foreach { rev } $revs {
        if { [gitHash $target] eq [gitHash $rev] } {
            return true
        }
    }
    return false
}

proc gitLastAvailableTag { version } {
    set parts [nextVersionParts $version]
    dict with parts {
        set prefix "$major.$minor.$micro"
    }
    # Delete potentially stale tags
    foreach { tagName} [exec git tag -l "$prefix*"] {
        exec git tag -d $tagName
    }
    catch { exec git fetch origin --tags } res
    set tagList [exec git tag -l "$prefix*"]
    if { [llength $tagList] < 1 } { return "" }
    set tagName [lindex $tagList [expr { [llength $tagList] - 1 }]]
    return $tagName
}

proc gitNextAvailableTag { version } {
    set tagName [gitLastAvailableTag $version]
    if { $tagName ne ""} {
        set result [nextVersion $tagName]
    } else {
        set result [nextVersion $version]
    }
    return $result
}

proc gitMerge { projId sourceBranch targetBranch { policy "none" }} {
    gitCheckout $projId $targetBranch
    catch { exec git gc }
    if { $policy eq "none" } {
        logInfo "Merge $projId $sourceBranch ([gitHash $sourceBranch]) into $targetBranch ([gitHash $targetBranch])"
        logInfo [exec git merge $sourceBranch]
    } else {
        logInfo "Merge $projId $sourceBranch ([gitHash $sourceBranch]) into $targetBranch ([gitHash $targetBranch]) with --$policy"
        logInfo [exec git merge --$policy $sourceBranch]
    }
}

proc gitPush { remote rev { force false } } {

    set args [list $remote $rev]
    if { $force } { set args [linsert $args 1 "--force"] }
    logInfo "git push $args"

    # A successful push may still result in a non-zero return
    if { [catch { eval exec git push $args } res] } {
        foreach { line} [split $res "\n"] {
            if { [string match "error: *" $line] || [string match "fatal: *" $line]  } {
                error $res
            }
        }
        logInfo $res
    }
}

proc gitRemoteAdd { name vcsUrl } {
    set remotes [split [exec git remote]]
    if { [lsearch $remotes $name] < 0} {
        exec git remote add $name $vcsUrl
    }
}

proc gitRemoteName { vcsUrl } {
    set remote ""
    foreach { name url action } [split [exec git remote -v]] {
        if { $url eq $vcsUrl } {
            set remote $name
        }
    }
    return $remote
}

proc gitRemoteRemove { name } {
    exec git remote remove $name
}

proc gitSubject { rev } {
    return [exec git log -n 1 --pretty=%s $rev]
}

proc gitTag { tagName } {
    exec git tag -a $tagName -m "\[fuse-cid] $tagName"
}

proc logDebug { msg } {
    log 4 $msg
}

proc logInfo { msg } {
    log 3 $msg
}

proc logWarn { msg } {
    log 2 $msg
}

proc logError { msg } {
    log 1 $msg
}

proc log { level msg } {
    variable argv

    set debugPrefix [dict create 4 "Debug: " 3 "" 2 "Warn: " 1 "Error: "]
    set maxLevel [string tolower [expr { [dict exists $argv "-debug"] ? [dict get $argv "-debug"] : 3 }]]

    if { $level <= $maxLevel } {

        # Process leading white space
        set trim [string trim $msg]
        set idx [string first $trim $msg]
        if { $idx > 0 } {
            puts -nonewline [string range $msg 0 [expr { $idx -1 }]]
            set msg [string range $msg $idx end]
        }

        puts "[dict get $debugPrefix $level]$msg"
    }
}

