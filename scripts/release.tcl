# !/usr/bin/tclsh
#

# Require package rest
# https://core.tcl.tk/tcllib/doc/trunk/embedded/www/tcllib/files/modules/rest/rest.html
package require rest

proc releaseMain { argc argv } {

    set scriptDir [file dirname [info script]]
    set targetDir [file normalize $scriptDir/target]
    set fname $targetDir/config.json

    if { $argc < 1 && [file exists $fname] } {
	set fid [open $fname]
	set json [read $fid]
	set config [json::json2dict $json]
	close $fid

	releaseConfig $config
	return
    }

    if { $argc != 1 } {
	puts "Usage:"
	puts "   tclsh release.tcl projId"
	return 1
    }

    set projId [lindex $argv 0]
    release $projId
}

proc release { projId } {
    set config [configTree $projId]
    releaseConfig $config
}

# Private ========================

proc releaseConfig { config } {

    puts [config2json $config]

    # Get a flat orderd list of configs
    set recipe [flatConfig $config [dict create]]

    puts "\nProcessing projects: [dict keys $recipe]"
    foreach { key } [dict keys $recipe] {
	releaseProject recipe $key
    }

    puts "\nGood Bye!"
}

proc releaseProject { recipe key } {
    upvar $recipe recipeRef

    set proj [dict get $recipeRef $key]
    dict with proj {
	puts "\nProcessing project: $projId"

	# Clone the project
	cd [gitClone $proj]

	# Check the last commit message
	set subject [exec git log --max-count=1 --pretty=%s $vcsBranch]
	set lastCommitIsOurs [string match {\[fuse-cid]*} $subject]

	# Get or create project tag
	if { $lastCommitIsOurs || {[maven-release-plugin] prepare for next development iteration} eq $subject } {
	    set tagName [gitLastAvailableTag $vcsBranch]
	} else {
	    # Update the dependencies in POM with tagged versions
	    if { [llength [dict get $proj "snapdeps"]] > 0 } {
		set mapping [dict get $proj "pomMapping"]
		foreach { depId } [dict get $proj "snapdeps"] {
		    set pomKey [dict get $mapping $depId]
		    set pomVal [pomValue /project/properties/$pomKey]
		    set tagName [dict get $recipeRef $depId "tagName"]
		    pomUpdate $pomKey $pomVal $tagName
		}
	    }
	    set tagName [gitCreateTag $vcsBranch]
	}

	# Store the tagName in the config
	set proj [dict set proj tagName $tagName]
	dict set recipeRef $key $proj

	# Merge the current branch into the target branch
	if { !$lastCommitIsOurs && $vcsBranch ne $vcsTargetBranch } {
	    gitMerge $vcsTargetBranch $vcsBranch
	    gitPush $vcsTargetBranch origin

	    # Update the dependencies in POM with next versions
	    gitCheckout $vcsBranch
	    set mapping [dict get $proj "pomMapping"]
	    foreach { depId } [dict get $proj "snapdeps"] {
		set pomKey [dict get $mapping $depId]
		set pomVal [pomValue /project/properties/$pomKey]
		pomUpdate $pomKey $pomVal "[nextVersion $pomVal]-SNAPSHOT"
	    }
	    gitPush $vcsBranch origin
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
    return [eval exec [split $cmd]]
}

proc flatConfig { config result } {
    set projId [dict get $config "projId"]
    if { [dict exists $result $projId] == 0 } {
	set depids [list]
	foreach { snap } [dict get $config "snapdeps"] {
	    lappend depids [dict get $snap "projId"]
	    set result [flatConfig $snap $result]
	}
	dict append result $projId [dict replace $config "snapdeps" $depids]
    }
    return $result
}

proc gitCheckout { branch } {
    execCmd "git checkout --quiet --force $branch"
}

proc gitClone { proj } {
    dict with proj {
	set scriptDir [file dirname [info script]]
	set targetDir [file normalize $scriptDir/target]
	set checkoutDir [file normalize $targetDir/checkout/$projId]
	file mkdir $checkoutDir/..
	file delete -force $checkoutDir
	catch { exec git clone -b $vcsBranch $vcsUrl $checkoutDir} res
	puts $res
	return $checkoutDir
    }
}

proc gitCommit { message } {
    puts "\[fuse-cid] $message"
    exec git commit -m "\[fuse-cid] $message"
}

proc gitCreateTag { branch } {
    set value [pomValue {mvn:version}]
    set tagName [strip $value "-SNAPSHOT"]
    set nextVersion "[nextVersion $tagName]-SNAPSHOT"
    mvnRelease $tagName $nextVersion
    return $tagName
}

proc gitLastAvailableTag { branch } {
    set tagName [exec git describe --abbrev=0]
    puts "Using last available tag: $tagName"
    return $tagName
}

proc gitMerge { targetBranch currBranch } {
    gitCheckout $targetBranch
    execCmd "git merge --ff-only $currBranch"
}

proc gitPush { branch remote } {
    puts "git push $remote $branch"
    catch { exec git push $remote $branch } result
    puts $result
}

proc mvnRelease { tagName nextVersion} {
    execCmd "mvn release:prepare -DautoVersionSubmodules=true -DreleaseVersion=$tagName -Dtag=$tagName -DdevelopmentVersion=$nextVersion"
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

proc pomValue { path } {
    set fid [open pom.xml]
    set xml [read $fid]
    close $fid
    set doc [dom parse $xml]
    set root [$doc documentElement]
    set node [$root selectNodes -namespaces {mvn http://maven.apache.org/POM/4.0.0} $path]
	puts $node
    return [$node text]
}

proc pomUpdate { pomKey pomVal nextVal } {
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

    releaseMain $argc $argv
}
