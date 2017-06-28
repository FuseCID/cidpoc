# !/usr/bin/tclsh
#

proc resetMain { argv } {

    dict set config cidpocA vcsUrl "git@github.com:FuseCID/cidpocA.git"
    dict set config cidpocA branch master 1.0.0 1

    dict set config cidpocB vcsUrl "git@github.com:FuseCID/cidpocB.git"
    dict set config cidpocB branch master 1.0.0 1

    dict set config cidpocC vcsUrl "git@github.com:FuseCID/cidpocC.git"
    dict set config cidpocC branch master 1.0.0 1
    dict set config cidpocC branch next 1.0.0 2

    dict set config cidpocD vcsUrl "git@github.com:FuseCID/cidpocD.git"
    dict set config cidpocD branch master 1.0.0 1
    dict set config cidpocD branch next 1.0.0 2

    dict set config cidpocE vcsUrl "git@github.com:FuseCID/cidpocE.git"
    dict set config cidpocE branch master 1.0.0 1
    dict set config cidpocE branch next 1.0.0 2

    dict for { key proj } $config {
	dict with proj {
	    dict for { vcsBranch data } $branch {
		set vcsTag [lindex $data 0]
		set offset [lindex $data 1]
		reset $key $vcsUrl $vcsBranch $vcsTag $offset
	    }
	}
    }

    puts "\nGood Bye!"
}

# Main ========================

proc reset { projId vcsUrl vcsBranch vcsTag offset } {
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

if { [string match "*/reset.tcl" $argv0] } {

    set scriptDir [file dirname [info script]]
    source $scriptDir/config.tcl
    source $scriptDir/release.tcl

    resetMain $argv
}
