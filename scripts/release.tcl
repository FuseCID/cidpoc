# !/usr/bin/tclsh
#

# Require package rest
# https://core.tcl.tk/tcllib/doc/trunk/embedded/www/tcllib/files/modules/rest/rest.html
package require rest

proc prepareMain { argv } {

    if { [llength $argv] < 8 } {
	puts "Usage:"
	puts "  tclsh release.tcl -cmd prepare \[-buildType buildType|-buildId buildId|-json path] -tcuser username -tcpass password \[-host host]"
	puts "  e.g. tclsh release.tcl -cmd prepare -buildType ProjCNext -tcuser restuser -tcpass somepass -host http://52.214.125.98:8111"
	puts "  e.g. tclsh release.tcl -cmd prepare -buildId %teamcity.build.id% -tcuser %system.teamcity.auth.userId% -tcpass %system.teamcity.auth.password% -host %teamcity.serverUrl%"
	return 1
    }

    if { [dict exists $argv "-json"] } {
	set fname [dict get $argv "-json"]
	set fid [open $fname]
	set json [read $fid]
	set config [json::json2dict $json]
	close $fid
	if { ![verifyConfig $config] } {
	    exit 1
	}
    } else {
	set config [configTree $argv]
    }

    prepare $config
}

proc prepare { config } {

    # Get a flat orderd list of configs
    set recipe [flattenConfig $config ]

    # Verify the given config
    if { ![verifyConfig $config] } {
	dict for { projId conf} $recipe {
	    dict with conf {
		set updated false
		gitSimpleCheckout $projId $vcsBranch
		foreach { depId } $dependencies {
		    set pomVersion [dict get $recipe $depId "pomVersion"]
		    set propName [lindex [dict get $conf "pomProps" $depId] 0]
		    set propVersion [lindex [dict get $conf "pomProps" $depId] 1]
		    if { $propVersion ne $pomVersion } {
			pomUpdate $depId $propName $propVersion $pomVersion
			set updated true
		    }
		}
		if { $updated } {
		    gitPush $vcsBranch
		}
	    }
	}
	exit 1
    }

    logInfo "\nOk to proceed!"
}

proc releaseMain { argv } {

    if { [llength $argv] < 6 } {
	puts "Usage:"
	puts "  tclsh release.tcl \[-buildType buildType|-buildId buildId|-json path] -tcuser username -tcpass password \[-host host]"
	puts "  e.g. tclsh release.tcl -buildType ProjCNext -host http://52.214.125.98:8111"
	puts "  e.g. tclsh release.tcl -buildId %teamcity.build.id% -tcuser %system.teamcity.auth.userId% -tcpass %system.teamcity.auth.password% -host %teamcity.serverUrl%"
	return 1
    }

    if { [dict exists $argv "-json"] } {
	set fname [dict get $argv "-json"]
	set fid [open $fname]
	set json [read $fid]
	set config [json::json2dict $json]
	close $fid
    } else {
	set config [configTree $argv]
    }

    release $config
}

proc release { config } {

    # Get a flat orderd list of configs
    set recipe [flattenConfig $config ]

    # Verify the given config
    if { ![verifyConfig $config] } {
	exit 1
    }

    logInfo "\nProcessing projects: [dict keys $recipe]"
    foreach { projId } [dict keys $recipe] {
	releaseProject recipe $projId
    }

    logInfo "\nGood Bye!"
}

# Private ========================

proc releaseProject { recipeRef projId } {
    upvar $recipeRef recipe
    variable argv

    set proj [dict get $recipe $projId]
    dict with proj {
	logInfo "\nProcessing project: $projId"

	# Checkout the project
	gitCheckout $projId $vcsUrl $vcsBranch
	gitVerifyHeadRevision $projId $vcsBranch $vcsCommit

	set lastAvailableTag [getLastAvailableTag $recipe $proj]

	# Get or create project tag
	if { $lastAvailableTag != 0 } {
	    set tagName $lastAvailableTag
	    logInfo "Use last available tag: $tagName"
	    set proj [dict set proj "updated" "false"]
	} else {
	    set tagName [gitNextAvailableTag $pomVersion]
	    logInfo "Create a new tag: $tagName"
	    set relBranch [gitReleaseBranchCreate $tagName]

	    # Update the dependencies in POM with tagged versions
	    foreach { depId } $dependencies {
		set propName [lindex [dict get $pomProps $depId] 0]
		set propVersion [lindex [dict get $pomProps $depId] 1]
		set depTag [dict get $recipe $depId "tagName"]
		pomUpdate $depId $propName $propVersion $depTag
	    }

	    createNewTag $tagName

	    #gitMerge $projId $vcsBranch $relBranch
	    #gitPush $vcsBranch

	    gitReleaseBranchDelete $relBranch $vcsBranch

	    set proj [dict set proj "updated" "true"]
	}

	# Store the tagName in the config
	set proj [dict set proj "tagName" $tagName]
	dict set recipe $projId $proj
    }
}

proc createNewTag { tagName } {
    logInfo "mvn versions:set -DnewVersion=$tagName"
    exec [mvnPath] versions:set -DnewVersion=$tagName
    exec [mvnPath] versions:commit
    exec git add --all
    gitCommit "prepare release $tagName"
    gitTag $tagName
    gitPush $tagName

    set nextVersion "[nextVersion $tagName]-SNAPSHOT"
    exec [mvnPath] versions:set -DnewVersion=$nextVersion
    exec [mvnPath] versions:commit
    exec git add --all
    gitCommit "prepare for next development iteration"
}

proc getLastAvailableTag { recipe proj } {

    set headRev [gitGetHash HEAD]
    set subject [gitGetSubject HEAD]
    set lastAvailableTag [gitLastAvailableTag]
    set tagRev [gitGetHash $lastAvailableTag]
    set dependencies [dict get $proj "dependencies"]

    logDebug "Last available tag: $lastAvailableTag - $tagRev"

    # Search for updated dependencies
    if { [llength $dependencies] > 0 } {
	foreach { depId } $dependencies {
	    set tagName [dict get $recipe $depId "tagName"]
	    if { [dict get $recipe $depId "updated"] } {
		logDebug "Found updated dependency: $depId $tagName"
		return 0
	    }
	}
    }

    # If HEAD points to a maven release, we use the associated tag
    if { [string match "?maven-release-plugin] prepare for next *" $subject] } {
	logDebug "HEAD points to maven release"
	return $lastAvailableTag
    }

    # If the tag is reachable from HEAD
    if { [gitIsReachable $tagRev $headRev] } {

	logDebug "Walking back from HEAD"

	set auxRev [gitGetHash $headRev]
	set subject [gitGetSubject $auxRev]

	# Walk back, processing our own upgrade commits
	while { $auxRev ne $tagRev } {
	    logDebug "$auxRev - $subject"
	    if { ![string match "?fuse-cid] Upgrade * to *" $subject] && ![string match "?maven-release-plugin] prepare for next *" $subject] } {
		logWarn "Unrecognized commit on our way to '$lastAvailableTag'"
		return 0
	    }
	    set auxRev [gitGetHash $auxRev^]
	    set subject [gitGetSubject $auxRev]
	}

	return $lastAvailableTag
    }

    # If HEAD is not reachable from the tag
    if { ![gitIsReachable $headRev $tagRev] } {
	logWarn "HEAD not reachable from tag '$lastAvailableTag'"
	return 0
    }

    logDebug "Walking back from $lastAvailableTag"

    set auxRev $tagRev
    set subject [gitGetSubject $auxRev]
    set upgrades [dict create]

    # Walk back, processing our own upgrade commits
    while { $auxRev ne $headRev } {
	logDebug "$auxRev - $subject"
	if { [string match "?fuse-cid] Upgrade * to *" $subject] } {
	    set depId [lindex $subject 2]
	    set depTag [lindex $subject 4]
	    dict set upgrades $depId $depTag
	}
	set auxRev [gitGetHash $auxRev^]
	set subject [gitGetSubject $auxRev]
    }

    # Verify that dependency versions match subject lines
    if { [llength $dependencies] > 0 } {

	logDebug "Known upgrades: $upgrades"

	# The tag is not usable if it does not match the dependency versions
	foreach { depId } $dependencies {
	    set tagName [dict get $recipe $depId "tagName"]
	    logDebug "Tag defined by recipe: $depId $tagName"
	    if { ![dict exists $upgrades $depId] } {
		logWarn "Known upgrades do not contain an entry for: $depId"
		return 0
	    }
	    if { $tagName ne [dict get $upgrades $depId] } {
		logWarn "Tag in recipe does not correspond to upgrade"
		return 0
	    }
	}
    }

    return $lastAvailableTag
}

proc gitCommit { message } {
    logInfo "\[fuse-cid] $message"
    exec git commit -m "\[fuse-cid] $message"
}

proc gitGetHash { rev } {
    return [exec git log -n 1 --pretty=%h $rev]
}

proc gitGetSubject { rev } {
    return [exec git log -n 1 --pretty=%s $rev]
}

proc gitIsReachable { target from } {
    if { [gitGetHash $target] == [gitGetHash $from^] } {
	return 1
    }
    set revs [split [exec git rev-list $target..$from]]
    return [expr {[llength $revs] > 1}]
}

proc gitLastAvailableTag { } {
    set tagList [exec git tag]
    set tagName [lindex $tagList [expr { [llength $tagList] - 1 }]]
    return $tagName
}

proc gitNextAvailableTag { pomVersion } {
    set tagName [nextVersion $pomVersion]
    set tagList [exec git tag]
    while { [lsearch $tagList $tagName] >= 0 } {
	set tagName [nextVersion $tagName]
    }
    return $tagName
}

proc gitMerge { projId target source } {
    gitSimpleCheckout $projId $target
    exec git merge --ff-only $source
}

proc gitPush { branch } {
    logInfo "git push origin $branch"

    # A successful push may still result in a non-zero return
    if { [catch { exec git push origin $branch } res] } {
	foreach { line} [split $res "\n"] {
	    if { [string match "error: *" $line] || [string match "fatal: *" $line]  } {
		error $res
	    }
	}
	logInfo $res
    }
}

proc gitReleaseBranchCreate { tagName } {
    set relBranch "tmp-$tagName"
    catch { exec git branch $relBranch }
    catch { exec git checkout $relBranch } res; logInfo $res
    return $relBranch
}

proc gitReleaseBranchDelete { relBranch curBranch } {
    catch { exec git checkout --force $curBranch }
    catch { exec git push origin --delete $relBranch }
    catch { exec git branch -D $relBranch }
}

proc gitSimpleCheckout { projId vcsBranch } {
    variable targetDir
    set workDir [file normalize $targetDir/checkout/$projId]
    cd $workDir
    catch { exec git checkout $vcsBranch }
    return $workDir
}

proc gitTag { tagName } {
    exec git tag -a $tagName -m "\[fuse-cid] $tagName"
}

proc isPrepareForNext { branch } {
    set subject [exec git log --max-count=1 --pretty=%s $branch]
    set expected "\[maven-release-plugin] prepare for next development iteration"
    return [string equal $subject $expected]
}

proc mvnPath { } {
    variable argv
    if { [dict exists $argv "-mvnHome"] } {
	set res "[dict get $argv -mvnHome]/bin/mvn"
    } else {
	if { [catch { exec which mvn } res] } {
	    error "Cannot find 'mvn' executable"
	}
    }
    return $res
}

proc nextVersion { version } {
    # Strip a potential -SNAPSHOT suffix
    if { [string match "*-SNAPSHOT" $version] } {
	set idx [expr {[string length $version] - 10}]
	set version [string range $version 0 $idx]
    }
    set tokens [split $version '.']
    set major [lindex $tokens 0]
    set minor [lindex $tokens 1]
    if { [llength $tokens] < 4 } {
	set patch ".fuse-700001"
	set micro [lindex $tokens 2]
    } else {
	set micro [lindex $tokens 2]
	set idx [string length "$major.$minor.$micro"]
	set patch [string range $version $idx end]
	if { [string match ".fuse-??????" $patch] }  {
	    set start [string range $patch 0 5]
	    set num [string range $patch 6 end]
	    set patch "$start[expr { $num + 1}]"
	} else {
	    error "Cannot parse version: $version"
	}
    }
    return "$major.$minor.$micro$patch"
}

proc pomUpdate { projId pomKey pomVal nextVal } {
    variable tcl_platform
    if { ![file exists pom.xml] } { error "Cannot find [pwd]/pom.xml" }
    set message "Upgrade $projId to $nextVal"
    set suffix [expr { $tcl_platform(os) eq "Darwin" ? [list -i ".bak"] : "-i.bak" }]
    exec sed $suffix "s#<$pomKey>$pomVal</$pomKey>#<$pomKey>$nextVal</$pomKey>#" pom.xml
    exec git add pom.xml
    gitCommit $message
}

# Main ========================

if { [string match "*/release.tcl" $argv0] } {

    set scriptDir [file dirname [info script]]
    source $scriptDir/config.tcl

    if { [dict exists $argv "-cmd"] && [dict get $argv "-cmd"] eq "prepare" } {
	prepareMain $argv
    } else {
	releaseMain $argv
    }
}
