# !/usr/bin/tclsh
#

# Require package rest
# https://core.tcl.tk/tcllib/doc/trunk/embedded/www/tcllib/files/modules/rest/rest.html
package require rest

proc prepareMain { argv } {

    if { [llength $argv] < 8 } {
	puts "Usage:"
	puts "  tclsh release.tcl -cmd prepare [-buildType buildType|-buildId buildId|-json path] -tcuser username -tcpass password [-host host]"
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
	dict for { key conf} $recipe {
	    dict with conf {
		set updated false
		gitSimpleCheckout $key $vcsBranch
		foreach { depName } $dependencies {
		    set pomVersion [dict get $recipe $depName "pomVersion"]
		    set propName [lindex [dict get $conf "pomProps" $depName] 0]
		    set propVersion [lindex [dict get $conf "pomProps" $depName] 1]
		    if { $propVersion ne $pomVersion } {
			pomUpdate $propName $propVersion $pomVersion
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

    if { [llength $argv] < 8 } {
	puts "Usage:"
	puts "  tclsh release.tcl [-buildType buildType|-buildId buildId|-json path] -tcuser username -tcpass password [-host host]"
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
    foreach { key } [dict keys $recipe] {
	releaseProject recipe $key
    }

    puts "\nGood Bye!"
}

# Private ========================

proc releaseProject { recipe key } {
    upvar $recipe recipeRef

    set proj [dict get $recipeRef $key]
    dict with proj {
	puts "\nProcessing project: $projId"

	# Checkout the project
	gitCheckout $projId $vcsUrl $vcsBranch
	gitVerifyHeadRevision $projId $vcsBranch $vcsCommit

	# Check the last commit message
	set subject [exec git log --max-count=1 --pretty=%s $vcsBranch]
	set lastCommitIsOurs [expr {[string match {\[fuse-cid]*} $subject] && ![string match {* Replace *-SNAPSHOT with *-SNAPSHOT} $subject]} ]
	set useLastAvailableTag [expr { $lastCommitIsOurs || {[maven-release-plugin] prepare for next development iteration} eq $subject }]

	# Scan dependencies for updates
	foreach { depId } $dependencies {
	    set updated [dict get $recipeRef $depId "updated"]
	    set useLastAvailableTag [expr { $useLastAvailableTag && !$updated }]
	}

	# Get or create project tag
	if { $useLastAvailableTag } {
	    set tagName [gitLastAvailableTag $vcsBranch]
	    set proj [dict set proj updated "false"]
	} else {
	    # Update the dependencies in POM with tagged versions
	    foreach { depId } $dependencies {
		set propName [lindex [dict get $pomProps $depId] 0]
		set propVersion [lindex [dict get $pomProps $depId] 1]
		set depTag [dict get $recipeRef $depId "tagName"]
		pomUpdate $propName $propVersion $depTag
	    }
	    set tagName [gitCreateTag [strip $pomVersion "-SNAPSHOT"]]
	    set proj [dict set proj updated "true"]
	}

	# Store the tagName in the config
	set proj [dict set proj tagName $tagName]
	dict set recipeRef $key $proj

	if { !$useLastAvailableTag && $vcsTargetBranch ne $vcsBranch } {

	    # Merge the created tag to the target branch
	    gitMerge $projId $vcsUrl $vcsTargetBranch $vcsBranch
	    gitPush $vcsTargetBranch

	    # Use a simple checkout
	    gitSimpleCheckout $projId $vcsBranch

	    # Update the dependencies in POM with next versions
	    foreach { depId } $dependencies {
		set pomKey [lindex [dict get $pomProps $depId] 0]
		set pomVal [dict get $recipeRef $depId "tagName"]
		set pomNextVal "[nextVersion $pomVal]-SNAPSHOT"
		pomUpdate $pomKey $pomVal $pomNextVal
	    }
	    gitPush $vcsBranch
	}
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

proc gitCreateTag { tagName } {
    set nextVersion "[nextVersion $tagName]-SNAPSHOT"
    mvnRelease $tagName $nextVersion
    return $tagName
}

proc gitLastAvailableTag { branch } {
    set tagName [exec git describe --abbrev=0]
    puts "Using last available tag: $tagName"
    return $tagName
}

proc gitMerge { projId vcsUrl targetBranch mergeBranch } {
    gitCheckout $projId $vcsUrl $targetBranch
    execCmd "git merge --ff-only $mergeBranch"
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

proc mvnRelease { tagName nextVersion } {
    puts "mvn release:prepare -DreleaseVersion=$tagName -Dtag=$tagName -DdevelopmentVersion=$nextVersion"
    exec mvn release:prepare -DautoVersionSubmodules=true {-DscmCommentPrefix=[fuse-cid] } -DreleaseVersion=$tagName -Dtag=$tagName -DdevelopmentVersion=$nextVersion
    execCmd "mvn release:perform"
}

proc nextVersion { version } {
    set tokens [split $version '.']
    set major [lindex $tokens 0]
    set minor [lindex $tokens 1]
    set idx [string length "$major.$minor."]
    set patch [string range $version $idx end]
    set idx [string first "-" $patch]
    if { $idx > 0 } {
	set micro [string range $patch 0 [expr $idx - 1]]
	set patch [string range $patch $idx end]
    } else {
	set micro $patch
	set patch ""
    }
    set micro [expr $micro + 1]
    return "$major.$minor.$micro$patch"
}

proc pomUpdate { pomKey pomVal nextVal } {
    variable tcl_platform
    if { ![file exists pom.xml] } { error "Cannot find [pwd]/pom.xml" }
    set message "Replace $pomKey $pomVal with $nextVal"
    set suffix [expr { $tcl_platform(os) eq "Darwin" ? [list -i ".bak"] : "-i.bak" }]
    exec sed $suffix "s#<$pomKey>$pomVal</$pomKey>#<$pomKey>$nextVal</$pomKey>#" pom.xml
    exec git add pom.xml
    gitCommit $message
}

proc tcRest { path } {
    set tcUrl "http://teamcity:8111"
    dict set restcfg auth { basic restuser restpass }
    return [rest::get $tcUrl$path "" $restcfg ]
}

proc strip { value strip } {
    set idx [expr [string last $strip $value] - 1]
    return [string range $value 0 $idx]
}

# Main ========================

if { [string match "*/release.tcl" $argv0] } {

    set scriptDir [file dirname [info script]]
    source $scriptDir/config.tcl

    set cmd [dict get $argv "-cmd"]
    if { $cmd eq "prepare" } {
	prepareMain $argv
    } else {
	releaseMain $argv
    }
}
