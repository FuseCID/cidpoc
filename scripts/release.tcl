# !/usr/bin/tclsh
#

proc prepareMain { argv } {

    if { [llength $argv] < 2 } {
        puts "Usage:"
        puts "  tclsh release.tcl -cmd prepare \[-buildType buildType|-buildId buildId|-json path] \[-tcuser username] \[-tcpass password] \[-host host]"
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
                gitCheckout $projId $vcsBranch
                foreach { depId } $dependencies {
                    set pomVersion [dict get $recipe $depId "pomVersion"]
                    set propName [lindex [dict get $conf "pomDeps" $depId] 0]
                    set propVersion [lindex [dict get $conf "pomDeps" $depId] 1]
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

    if { [llength $argv] < 2 } {
        puts "Usage:"
        puts "  tclsh release.tcl \[-buildType buildType|-buildId buildId|-json path] \[-tcuser username] \[-tcpass password] \[-host host]"
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
        gitCloneOrCheckout $projId $vcsUrl $vcsBranch
        gitVerifyHeadRevision $projId $vcsBranch $vcsCommit

        # Get or create project tag
        if { $vcsTagName ne "" } {
            logInfo "Use last applicable tag: $vcsTagName"
            set proj [dict set proj "updated" "false"]
        } else {
            set tagName [gitNextAvailableTag $pomVersion]
            logInfo "Creating a new tag: $tagName"
            set relBranch [gitReleaseBranchCreate $tagName]

            # Update the dependencies in POM with tagged versions
            foreach { depId } $dependencies {
                set propName [lindex [dict get $pomDeps $depId] 0]
                set propVersion [lindex [dict get $pomDeps $depId] 1]
                set depTag [dict get $recipe $depId "vcsTagName"]
                pomUpdate $depId $propName $propVersion $depTag
            }

            createNewTag $tagName

            if { [dict exists $argv "-merge"] && [dict get $argv "-merge"] } {
                gitMerge $projId $vcsBranch $relBranch
                gitPush $vcsBranch
            }

            gitReleaseBranchDelete $relBranch $vcsBranch

            # Store the tagName in the config
            set proj [dict set proj "vcsTagName" $tagName]
            dict set recipe $projId $proj
        }
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
