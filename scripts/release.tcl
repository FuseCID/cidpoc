# !/usr/bin/tclsh
#

# Require package rest
# https://core.tcl.tk/tcllib/doc/trunk/embedded/www/tcllib/files/modules/rest/rest.html
package require rest

proc releaseMain { argv } {

    if { [llength $argv] < 2 } {
	puts "Usage:"
	puts "  tclsh release.tcl [-buildType buildType|-buildId buildId|-json path] [-host host] [-user user] [-oauth token]"
	puts "  e.g. tclsh release.tcl -proj ProjCNext -host http://52.214.125.98:8111 -user fuse-cid -oauth 5810305a47"
	puts "  e.g. tclsh release.tcl -proj %teamcity.project.id% -host %teamcity.serverUrl% -user %cid.github.username% -oauth %cid.github.oauth.token%"
	return 1
    }

    if { [dict exists $argv "-json"] } {
	set fname [dict get $argv "-json"]
	set fid [open $fname]
	set json [read $fid]
	set config [json::json2dict $json]
	close $fid
    } else {
	set config [configTree]
    }

    release $config
}

proc release { config } {

    if { ![verifyConfig $config] } {
	exit 1
    }
	
    # Get a flat orderd list of configs
    set recipe [flattenConfig $config ]

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
	set lastCommitIsOurs [string match {\[fuse-cid]*} $subject]
	set useLastAvailableTag [expr { $lastCommitIsOurs || {[maven-release-plugin] prepare for next development iteration} eq $subject }]

	# Get or create project tag
	if { $useLastAvailableTag } {
	    set tagName [gitLastAvailableTag $vcsBranch]
	} else {
	    # Update the dependencies in POM with tagged versions
	    foreach { depId } $dependencies {
		set pomKey [lindex [dict get $pomProps $depId] 0]
		set pomVal [lindex [dict get $pomProps $depId] 1]
		set depTag [dict get $recipeRef $depId "tagName"]
		pomUpdate $pomKey $pomVal $depTag
	    }
	    set tagName [gitCreateTag [strip $pomVersion "-SNAPSHOT"]]
	}

	# Store the tagName in the config
	set proj [dict set proj tagName $tagName]
	dict set recipeRef $key $proj

	if { !$useLastAvailableTag } {

	    # Update the dependencies in POM with next versions
	    foreach { depId } $dependencies {
		set pomKey [lindex [dict get $pomProps $depId] 0]
		set pomVal [dict get $recipeRef $depId "tagName"]
		set pomNextVal "[nextVersion $pomVal]-SNAPSHOT"
		pomUpdate $pomKey $pomVal $pomNextVal
	    }

	    # Push modified branch to origin
	    gitPush $vcsBranch

	    # Merge the created tag to the target branch
	    gitCheckout $projId $vcsUrl $vcsTargetBranch
	    execCmd "git merge --ff-only $tagName"
	    gitPush $vcsTargetBranch
	}
    }
}

proc isPrepareForNext { branch } {
    set subject [exec git log --max-count=1 --pretty=%s $branch]
    set expected "\[maven-release-plugin] prepare for next development iteration"
    return [string equal $subject $expected]
}

proc execCmd { cmd {ignoreError 0} } {
    puts $cmd
    if { $ignoreError } {
	set retval [catch { eval exec [split $cmd] } res]
	return $res
    } else {
	eval exec [split $cmd]
	return "ok"
    }
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
    catch { exec git push origin $branch } result
    puts $result
}

proc mvnRelease { tagName nextVersion } {
    variable argv
    set prepare "release:prepare"
    if { [dict exists $argv "-user"] } {
	lappend prepare "-Dusername=[dict get $argv -user]" "-Dpassword=[dict get $argv -oauth]"
    }
    puts "mvn release:prepare -DreleaseVersion=$tagName -Dtag=$tagName -DdevelopmentVersion=$nextVersion"
    exec mvn $prepare -DautoVersionSubmodules=true {-DscmCommentPrefix=[fuse-cid] } -DreleaseVersion=$tagName -Dtag=$tagName -DdevelopmentVersion=$nextVersion
    execCmd "mvn release:clean"
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
    if { ![file exists pom.xml] } { error "Cannot find [pwd]/pom.xml" }
    set message "Replace $pomKey $pomVal with $nextVal"
    exec sed -i "" "s#<$pomKey>$pomVal</$pomKey>#<$pomKey>$nextVal</$pomKey>#" pom.xml
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

    releaseMain $argv
}
