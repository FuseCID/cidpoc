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

    puts "\nOk to proceed!"
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

    puts "\nProcessing projects: [dict keys $recipe]"
    foreach { projId } [dict keys $recipe] {
	releaseProject recipe $projId
    }

    puts "\nGood Bye!"
}

# Private ========================

proc releaseProject { recipe projId } {
    upvar $recipe recipeRef

    set proj [dict get $recipeRef $projId]
    dict with proj {
	puts "\nProcessing project: $projId"

	# Checkout the project
	gitCheckout $projId $vcsUrl $vcsBranch
	gitVerifyHeadRevision $projId $vcsBranch $vcsCommit

	# Check the last commit message
	set headRev [gitGetHash HEAD]
	set subject [gitGetSubject HEAD]
	set lastAvailableTag [gitLastAvailableTag]
	set lastCommitIsOurs [string match "?fuse-cid] Upgrade *" $subject]
	set prepareForNext [string match "?maven-release-plugin] prepare for next *" $subject]
	set useLastAvailableTag [expr { $prepareForNext || $lastCommitIsOurs }]

	# Verify that HEAD is reachable from lastAvailableTag
	if { !$useLastAvailableTag } {
	    set auxRev [gitGetHash $lastAvailableTag]
	    while { $auxRev ne $headRev } {
		if { [catch { set auxRev [gitGetHash $auxRev^] }] } {
		    break
		}
	    }
	    set useLastAvailableTag [expr {$auxRev eq $headRev}]
	}

	# Verify the last available tag
	if { $useLastAvailableTag && [llength $dependencies] > 0 } {
	    set upgrades [dict create]

	    # Scan the subject lines for version updates
	    set auxRev [gitGetHash $lastAvailableTag^]
	    while { $auxRev ne $headRev } {
		set subject [gitGetSubject $auxRev]
		if { [string match "?fuse-cid] Upgrade * to *" $subject] } {
		    set depId [lindex $subject 2]
		    set depTag [lindex $subject 4]
		    dict set upgrades $depId $depTag
		    set auxRev [gitGetHash $auxRev^]
		} else {
		    break
		}
	    }

	    # Scan dependencies for updates
	    foreach { depId } $dependencies {
		set lastTag [dict get $recipeRef $depId "lastTag"]
		set updated [dict get $recipeRef $depId "updated"]
		if { !$updated && [dict exists $upgrades $depId] } {
		    set updated [expr { $lastTag ne [dict get $upgrades $depId] }]
		}
		set useLastAvailableTag [expr { $useLastAvailableTag && !$updated }]
	    }
	}

	# Get or create project tag
	if { $useLastAvailableTag } {
	    set tagName $lastAvailableTag
	    puts "Use last available tag: $tagName"
	    set proj [dict set proj "lastTag" $tagName]
	    set proj [dict set proj "updated" "false"]
	} else {
	    set tagName [gitNextAvailableTag $pomVersion]
	    puts "Create a new tag: $tagName"
	    set relBranch [gitReleaseBranchCreate $tagName]

	    # Update the dependencies in POM with tagged versions
	    foreach { depId } $dependencies {
		set propName [lindex [dict get $pomProps $depId] 0]
		set propVersion [lindex [dict get $pomProps $depId] 1]
		set depTag [dict get $recipeRef $depId "tagName"]
		pomUpdate $depId $propName $propVersion $depTag
	    }

	    mvnRelease $tagName
	    gitReleaseBranchDelete $relBranch $vcsBranch

	    set proj [dict set proj "lastTag" $tagName]
	    set proj [dict set proj "updated" "true"]
	}

	# Store the tagName in the config
	set proj [dict set proj tagName $tagName]
	dict set recipeRef $projId $proj
    }
}

proc isPrepareForNext { branch } {
    set subject [exec git log --max-count=1 --pretty=%s $branch]
    set expected "\[maven-release-plugin] prepare for next development iteration"
    return [string equal $subject $expected]
}

proc execCmd { cmd } {
    puts $cmd
    eval exec [split $cmd]
}

proc gitCommit { message } {
    puts "\[fuse-cid] $message"
    exec git commit -m "\[fuse-cid] $message"
}

proc gitGetHash { rev } {
    return [exec git log -n 1 --pretty=%h $rev]
}

proc gitGetSubject { rev } {
    return [exec git log -n 1 --pretty=%s $rev]
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
	set tagName [nextVersion $tagName]
    }
    return $tagName
}

proc gitPush { branch } {
    puts "git push origin $branch"

    # A successful push may still result in a non-zero return
    if { [catch { exec git push origin $branch } res] } {
	foreach { line} [split $res "\n"] {
	    if { [string match "error: *" $line] || [string match "fatal: *" $line]  } {
		error $res
	    }
	}
	puts $res
    }
}

proc gitReleaseBranchCreate { tagName } {
    set relBranch "tmp-$tagName"
    catch { exec git branch $relBranch }
    catch { exec git checkout $relBranch } res; puts $res
    return $relBranch
}

proc gitReleaseBranchDelete { relBranch curBranch } {
    catch { exec git checkout --force $curBranch }
    catch { exec git push origin --delete $relBranch }
    catch { exec git branch -D $relBranch }
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

proc mvnRelease { tagName { perform 1 }} {
    set nextVersion [nextVersion $tagName]
    puts "mvn release:prepare -DreleaseVersion=$tagName -Dtag=$tagName -DdevelopmentVersion=$nextVersion"
    exec [mvnPath] release:prepare -DautoVersionSubmodules=true {-DscmCommentPrefix=[fuse-cid] } -DreleaseVersion=$tagName -Dtag=$tagName -DdevelopmentVersion=$nextVersion
    if { $perform } {
	puts "mvn release:perform"
	exec [mvnPath] release:perform
    }
}

proc nextVersion { version } {
    set tokens [split $version '.']
    set major [lindex $tokens 0]
    set minor [lindex $tokens 1]
    if { [llength $tokens] < 4 } {
	set patch ".fuse-700001"
	set micro [lindex $tokens 2]
	if { [string match "*-SNAPSHOT" $micro] } {
	    set idx [expr {[string length $micro] - 10}]
	    set micro [string range $micro 0 $idx]
	}
    } else {
	set micro [lindex $tokens 2]
	set idx [string length "$major.$minor.$micro"]
	set patch [string range $version $idx end]
	if { [string match "*-SNAPSHOT" $patch] } {
	    set idx [expr {[string length $patch] - 10}]
	    set patch [string range $patch 0 $idx]
	} elseif { [string match ".fuse-??????" $patch] }  {
	    set start [string range $patch 0 5]
	    set num [string range $patch 6 end]
	    set patch "$start[expr { $num + 1}]"
	} else {
	    error "Cannot parse version: $version"
	}
    }
    set result "$major.$minor.$micro$patch"
    if { ![string match "*-SNAPSHOT" $version] } {
	set result "$result-SNAPSHOT"
    }
    return $result
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
