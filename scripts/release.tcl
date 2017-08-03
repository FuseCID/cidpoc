# !/usr/bin/tclsh
#

proc prepareMain { argv } {

    if { [llength $argv] < 2 } {
        puts "Usage:"
        puts "  tclsh release.tcl -cmd prepare \[-buildType buildType|-buildId buildId] \[-tcuser username] \[-tcpass password] \[-host host]"
        puts "  e.g. tclsh release.tcl -cmd prepare -buildType ProjCNext -tcuser restuser -tcpass somepass -host http://52.214.125.98:8111"
        puts "  e.g. tclsh release.tcl -cmd prepare -buildId %teamcity.build.id% -tcuser %system.teamcity.auth.userId% -tcpass %system.teamcity.auth.password% -host %teamcity.serverUrl%"
        return 1
    }

    set config [configTree $argv]

    prepare $config
}

proc releaseMain { argv } {

    if { [llength $argv] < 2 } {
        puts "Usage:"
        puts "  tclsh release.tcl -cmd release \[-buildType buildType|-buildId buildId] \[-tcuser username] \[-tcpass password] \[-host host]"
        puts "  e.g. tclsh release.tcl -buildType ProjCNext -host http://52.214.125.98:8111"
        puts "  e.g. tclsh release.tcl -buildId %teamcity.build.id% -tcuser %system.teamcity.auth.userId% -tcpass %system.teamcity.auth.password% -host %teamcity.serverUrl%"
        return 1
    }

    set config [configTree $argv]

    release $config
}

proc prepare { config } {

    set recipe [flattenConfig $config ]
    set verifyOk [verifyConfig $config]

    set projId [dict get $config "projId"]
    set proj [dict get $recipe $projId]
    dict with proj {

        gitCheckout $projId $vcsBranch

        if { ![gitIsReachable "origin/$vcsMasterBranch" $vcsBranch] } {
            logWarn "Master branch of $projId not reachable from $vcsBranch"
            logWarn "Reset $vcsBranch of $projId to origin/$vcsMasterBranch"
            exec git reset --hard "origin/$vcsMasterBranch"
            exit 1
        }

        if { !$verifyOk } {
            logInfo "\nFixing consistency issues"

            set messages [list]
            set projNames [list]
            foreach { depId } $dependencies {
                set pomVersion [dict get $recipe $depId "pomVersion"]
                set propName [lindex [dict get $proj "pomDeps" $depId] 0]
                set propVersion [lindex [dict get $proj "pomDeps" $depId] 1]
                if { $propVersion ne $pomVersion } {
                    set msg [pomUpdate $depId $propName $propVersion $pomVersion]
                    lappend projNames $depId
                    lappend messages $msg
                }
            }

            if { [llength $messages] > 0 } {
                if { [llength $messages] > 1 } {
                    set messages [linsert $messages 0 "Upgrading dependencies for [join $projNames ", "]\n"]
                }
                exec git add pom.xml
                gitCommit [join $messages "\n"]
                gitPush $vcsBranch true
            }

            # Exit if verify was not ok
            exit 1
        }
    }

    logInfo "\nOk to proceed!"
}

proc release { config } {

    # Verify the given config
    if { ![verifyConfig $config] } {
        exit 1
    }

    # Get a flat ordered list of configs
    set recipe [flattenConfig $config ]
    releaseProjects $recipe

    logInfo "\nGood Bye!"
}

# Private ========================

proc releaseProjects { recipe } {

    set projKeys [dict keys $recipe]
    logInfo "=================================================="
    logInfo "Step [incr i] - Processing projects: $projKeys"
    logInfo "=================================================="

    set projIndex [expr { [llength $projKeys] - 1 }]
    set finalProjId [lindex $projKeys $projIndex]

    foreach { proj } [dict values $recipe] {
        dict with proj {

            logInfo "=================================================="
            logInfo "Step [incr i] - Processing project: $projId"
            logInfo "=================================================="

            if { $vcsTagName ne "" } {
                logInfo "Use existing tag $projId - $vcsTagName"
                continue
            }

            # Clone projects that is not the final target
            if { $finalProjId ne $projId } {
                gitClone $projId $vcsUrl $vcsBranch
            }

            gitCheckout $projId $vcsCommit

            set tagName [gitNextAvailableTag $pomVersion]
            set relBranch [gitCreateBranch "tmp-$tagName"]
            set nextVersion "[nextVersion $tagName]-SNAPSHOT"

            set messages [list]
            if { [llength $dependencies] > 0 } {

                logInfo "=================================================="
                logInfo "Step [incr i] - Update the dependencies in POM with tagged versions"
                logInfo "=================================================="

                foreach { depId } $dependencies {
                    set propName [lindex [dict get $pomDeps $depId] 0]
                    set propVersion [lindex [dict get $pomDeps $depId] 1]
                    set nextPropVersion [dict get $recipe $depId "vcsTagName"]
                    set msg [pomUpdate $depId $propName $propVersion $nextPropVersion]
                    lappend messages $msg
                }
            }

            logInfo "=================================================="
            logInfo "Step [incr i] - Create tag $projId $tagName"
            logInfo "=================================================="

            if { $mvnExtraArgs ne "" } {
                execMvn versions:set -DnewVersion=$tagName $mvnExtraArgs
                execMvn versions:commit $mvnExtraArgs
                execMvn clean install -DskipTests $mvnExtraArgs
            } else {
                execMvn versions:set -DnewVersion=$tagName
                execMvn versions:commit
                execMvn clean install -DskipTests
            }

            exec git add --all
            set messages [linsert $messages 0 "prepare release $tagName\n"]
            gitCommit [join $messages "\n"]

            gitTag $tagName
            gitPush $tagName

            # Delete the release branch
            gitDeleteBranch $relBranch

            # Store the tagName in the config
            dict set recipe $projId "vcsTagName" $tagName
        }
    }
}

proc execMvn { args } {
    logInfo "mvn $args"

    set oldval [fconfigure stdout -buffering]
    fconfigure stdout -buffering line

    set fid [open "|mvn $args"]
    fconfigure $fid -buffering line

    set buildSuccess 0
    while { ![eof $fid] } {
        set line [gets $fid]
        if { [string match "*BUILD SUCCESS*" $line] } {
            set buildSuccess true
        }
        puts stdout $line
    }

    fconfigure stdout -buffering $oldval
    if { !$buildSuccess } { error "Maven build failed" }
}

proc nextVersion { version } {
    set parts [nextVersionParts $version]
    dict with parts {
        return "$major.$minor.$micro.$patch"
    }
}

proc nextVersionParts { version } {
    # Strip a potential -SNAPSHOT suffix
    set snapshot [string match "*-SNAPSHOT" $version]
    if { $snapshot } {
        set idx [expr {[string length $version] - 10}]
        set version [string range $version 0 $idx]
    }
    set tokens [split $version '.']
    set major [lindex $tokens 0]
    set minor [lindex $tokens 1]
    if { [llength $tokens] < 4 } {
        set patch "fuse-700001"
        set micro [lindex $tokens 2]
    } else {
        set micro [lindex $tokens 2]
        set idx [string length "$major.$minor.$micro."]
        set patch [string range $version $idx end]
        if { [string match "fuse*" $patch] }  {
            set start [string range $patch 0 3]
            set num 700001
            if { [string match "fuse-??????" $patch] } {
                set num [string range $patch 5 end]
            }
            if { !$snapshot } { incr num }
            set patch "$start-$num"
        } else {
            error "Cannot parse version: $version"
        }
    }
    dict set result major $major
    dict set result minor $minor
    dict set result micro $micro
    dict set result patch $patch
    return $result
}

proc pomUpdate { projId pomKey pomVal nextVal } {
    variable tcl_platform
    if { ![file exists pom.xml] } { error "Cannot find [pwd]/pom.xml" }
    set message "Upgrade $projId to $nextVal"
    set suffix [expr { $tcl_platform(os) eq "Darwin" ? [list -i ".bak"] : "-i.bak" }]
    set sedCmd "sed $suffix \"s#<$pomKey>$pomVal</$pomKey>#<$pomKey>$nextVal</$pomKey>#\" pom.xml"
    eval exec $sedCmd
    if { [file exists pom.xml.bak] } {
        exec rm -f pom.xml.bak
    }
    return $message
}

# Main ========================

if { [string match "*/release.tcl" $argv0] } {

    set scriptDir [file dirname [info script]]
    source $scriptDir/config.tcl

    set cmd [dict get $argv "-cmd"]
    switch $cmd {
        "prepare" { prepareMain $argv }
        "release" { releaseMain $argv }
        default { error "Invalid command: $cmd" }
    }
}
