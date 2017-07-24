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

proc releaseMain { argv } {

    if { [llength $argv] < 2 } {
        puts "Usage:"
        puts "  tclsh release.tcl -cmd release \[-buildType buildType|-buildId buildId|-json path] \[-tcuser username] \[-tcpass password] \[-host host]"
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

proc prepare { config } {

    # Get a flat orderd list of configs
    set recipe [flattenConfig $config ]

    # Verify the given config
    if { ![verifyConfig $config] } {
        logInfo "\nFixing dependency versions\n"
        dict for { projId conf} $recipe {
            dict with conf {
                set updated false
                gitCheckout $projId $vcsBranch
                foreach { depId } $dependencies {
                    set pomVersion [dict get $recipe $depId "pomVersion"]
                    set propName [lindex [dict get $conf "pomDeps" $depId] 0]
                    set propVersion [lindex [dict get $conf "pomDeps" $depId] 1]
                    if { $propVersion ne $pomVersion } {
                        pomUpdate [list] $depId $propName $propVersion $pomVersion
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

proc release { config } {

    # Verify the given config
    if { ![verifyConfig $config] } {
        exit 1
    }

    # Get a flat orderd list of configs
    set configs [flattenConfig $config ]
    set recipe [list]

    addCmd recipe "## Processing projects: [dict keys $configs]"
    addCmd recipe "export CID_WORKDIR=`pwd`"
    addCmd recipe "rm -rf target/checkout"
    addCmd recipe "set -e"

    addCmd recipe "## Release configuration"
    foreach line [split [config2json $config] "\n"] {
        addCmd recipe "# $line"
    }

    # Build the release recipe
    foreach { projId } [dict keys $configs] {
        set tagName [releaseProject recipe configs $projId]
    }

    # Add the release recipe to a branch
    if { $tagName ne "" } {
        set proj [dict get $configs $projId]
        dict with proj {
            set relBranch "release/$tagName"
            addCmd recipe "## Delete temporary release branch"
            addCmd recipe "git push origin --delete $relBranch"

            gitCheckout $projId $vcsCommit
            gitCreateBranch $relBranch

            set fname "release-recipe.sh"
            set fid [open $fname w]
            puts $fid "#!/bin/bash"
            puts $fid ""

            logInfo "\nBEGIN Release Recipe =========================="

            foreach line $recipe {
                if { [string match "echo \"## *" $line] } {
                    set line "echo \" Step [incr stepIndex] - [string range $line 9 end]"
                }
                puts $fid $line
                puts $line
            }
            close $fid

            logInfo "\nEND Release Recipe ============================\n"

            # Push the recipe to the release branch
            exec git add $fname
            gitCommit "Add release recipe for $tagName"
            gitPush $relBranch true
        }
    }

    logInfo "\nGood Bye!"
}

# Private ========================

proc releaseProject { recipeRef configsRef projId } {
    upvar $recipeRef recipe
    upvar $configsRef configs
    variable argv

    set proj [dict get $configs $projId]
    dict with proj {
        set projDir "target/checkout/$projId"

        addCmd recipe "## Processing project: $projId"

        if { $vcsTagName ne "" } {
            addCmd recipe "## Use $projId ($vcsTagName)"
            return ""
        }

        # Checkout the project
        gitClone $projId $vcsUrl $vcsBranch
        gitCheckout $projId $vcsCommit

        set tagName [gitNextAvailableTag $pomVersion]
        set relBranch [gitCreateBranch "tmp-$tagName"]

        addCmd recipe "cd \$CID_WORKDIR"

        # Clone projects that is not the final target
        set projIdx [lsearch [dict keys $configs] $projId]
        if { $projIdx < [dict size $configs] - 1 } {
            addCmd recipe "mkdir -p $projDir/.."
            addCmd recipe "git clone $vcsUrl $projDir"
            addCmd recipe "cd $projDir"
            addCmd recipe "git checkout $vcsCommit"
            addCmd recipe "git checkout -B $relBranch"
        } else {
            addCmd recipe "git fetch --force origin"
            addCmd recipe "git reset --hard $vcsCommit"
            addCmd recipe "git checkout -B $relBranch"
        }

        if { [llength $dependencies] > 0 } {
            addCmd recipe "## Update the dependencies in POM with tagged versions"
            foreach { depId } $dependencies {
                set propName [lindex [dict get $pomDeps $depId] 0]
                set propVersion [lindex [dict get $pomDeps $depId] 1]
                set nextVersion [dict get $configs $depId "vcsTagName"]
                pomUpdate recipe $depId $propName $propVersion $nextVersion
            }
        }

        addCmd recipe "## Create tag $projId $tagName"

        addCmd recipe "mvn versions:set -DnewVersion=$tagName $mvnExtraArgs"
        addCmd recipe "mvn versions:commit $mvnExtraArgs"
        addCmd recipe "mvn clean install -DskipTests $mvnExtraArgs"
        addCmd recipe "git add --all"
        addCmd recipe "git commit -m \"\[fuse-cid] prepare release $tagName\""
        addCmd recipe "git tag -f -a $tagName -m \"\[fuse-cid] $tagName\""
        addCmd recipe "git push origin $tagName"

        addCmd recipe "## Prepare for next development iteration"

        set nextVersion "[nextVersion $tagName]-SNAPSHOT"
        addCmd recipe "mvn versions:set -DnewVersion=$nextVersion"
        addCmd recipe "mvn versions:commit"
        addCmd recipe "git add --all"
        addCmd recipe "git commit -m \"\[fuse-cid] prepare for next development iteration\""

        addCmd recipe "## Merge release branch into $vcsMasterBranch"

        addCmd recipe "git fetch --force origin"
        addCmd recipe "git checkout $vcsMasterBranch"
        addCmd recipe "git reset --hard origin/$vcsMasterBranch"
        addCmd recipe "git push --force origin $relBranch"
        addCmd recipe "git merge --ff-only $relBranch"
        addCmd recipe "git push origin $vcsMasterBranch"
        addCmd recipe "git push origin --delete $relBranch"

        if { [llength $dependencies] > 0 } {
            addCmd recipe "## Prepare dev branch for next development iteration"
            addCmd recipe "git checkout $vcsDevBranch"
            addCmd recipe "git reset --hard $vcsMasterBranch"
            foreach { depId } $dependencies {
                set propName [lindex [dict get $pomDeps $depId] 0]
                set propVersion [dict get $configs $depId "vcsTagName"]
                set nextVersion "[nextVersion $propVersion]-SNAPSHOT"
                pomUpdate recipe $depId $propName $propVersion $nextVersion
            }
            addCmd recipe "git push origin $vcsDevBranch"
        }

        # Push the release branch
        gitDeleteBranch $vcsBranch $relBranch

        # Store the tagName in the config
        set proj [dict set proj "vcsTagName" $tagName]
        dict set configs $projId $proj

        return $tagName
    }
}

proc addCmd { recipeRef cmd } {
    upvar $recipeRef recipe
    if { [string match "## *" $cmd] } {
        logInfo [string range $cmd 3 end]
        lappend recipe ""
        lappend recipe "echo \"==================================================\""
        lappend recipe "echo \"$cmd\""
        lappend recipe "echo \"==================================================\""
        lappend recipe ""
    } else {
        lappend recipe $cmd
    }
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
    set snapshot [string match "*-SNAPSHOT" $version]
    if { $snapshot } {
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
            if { !$snapshot } { incr num }
            set patch "$start$num"
        } else {
            error "Cannot parse version: $version"
        }
    }
    return "$major.$minor.$micro$patch"
}

proc pomUpdate { recipeRef projId pomKey pomVal nextVal } {
    upvar $recipeRef recipe
    variable tcl_platform
    if { ![file exists pom.xml] } { error "Cannot find [pwd]/pom.xml" }
    set message "Upgrade $projId to $nextVal"
    set suffix [expr { $tcl_platform(os) eq "Darwin" ? [list -i ".bak"] : "-i.bak" }]
    set sedCmd "sed $suffix \"s#<$pomKey>$pomVal</$pomKey>#<$pomKey>$nextVal</$pomKey>#\" pom.xml"
    eval exec $sedCmd
    if { [file exists pom.xml.bak] } {
        exec rm -f pom.xml.bak
        exec git add pom.xml
        gitCommit $message
    }

    addCmd recipe "$sedCmd"
    addCmd recipe "rm -f pom.xml.bak"
    addCmd recipe "git add pom.xml"
    addCmd recipe "git commit -m \"\[fuse-cid] $message\""
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
