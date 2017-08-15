# !/usr/bin/tclsh
#

# Require package rest
# https://core.tcl.tk/tcllib/doc/trunk/embedded/www/tcllib/files/modules/rest/rest.html
package require rest
package require json

set checkoutDir [file normalize [pwd]/.checkout]

proc configMain { argv } {
    variable checkoutDir

    if { [llength $argv] < 2 } {
        puts "Usage:"
        puts "  tclsh config.tcl \[-buildType buildType|-buildId buildId] \[-tcuser username] \[-tcpass password] \[-host host]\n"
        puts "  e.g. tclsh config.tcl -buildType ProjCNext -host http://52.214.125.98:8111"
        puts "  e.g. tclsh config.tcl -buildId 363"
        return 1
    }

    set config [configTree $argv ]

    #set json [json::dict2json $config]
    set json [config2json $config]

    # Write json to file
    set fname $checkoutDir/config.json
    set fid [open $fname w]
    puts $fid $json
    close $fid

    # Test the round trip
    set fid [open $fname]
    set json [read $fid]
    set config [json::json2dict $json]
    set json [config2json $config]
    close $fid

    verifyConfig $config
}

proc configTree { argv } {

    if { [dict exists $argv "-buildId"] } {
        set buildId [dict get $argv "-buildId"]
        return [configTreeByBuildId $buildId]
    } elseif { [dict exists $argv "-buildType"] } {
        set buildType [dict get $argv "-buildType"]
        return [configTreeByBuildType $buildType]
    } else {
        error "No -buildId nor -buildType parameter given"
    }
}

proc verifyConfig { config } {

    puts "Verifying configuration\n"
    puts [config2json $config]

    set workDir [pwd]
    set problems [list]
    set recipe [flattenConfig $config ]

    dict for { key conf} $recipe {
        dict with conf {

            gitCheckout $projId $vcsBranch

            logDebug "Check whether master branch of $projId is reachable from $vcsBranch"
            if { ![gitIsReachable "origin/$vcsMasterBranch" $vcsBranch] } {
                lappend problems "Master branch of $projId not reachable from $vcsBranch"
            }

            # for each dependency get the pomVersion
            foreach { depName } $dependencies {
                set pomVersion [dict get $recipe $depName "pomVersion"]
                set propName [lindex [dict get $conf "pomDeps" $depName] 0]
                set propVersion [lindex [dict get $conf "pomDeps" $depName] 1]
                logDebug "Verify values of $propName: $propVersion vs. $pomVersion"
                if { $propVersion ne $pomVersion } {
                    lappend problems "Make $key dependent on $depName $pomVersion"
                }
            }
        }
    }

    if  { [llength $problems] > 0 } {
        logError "\nThis configuration is not consistent"
        foreach { prob } $problems {
            logError $prob
        }
    }

    cd $workDir

    return [expr {[llength $problems] < 1}]
}

# Private ========================

proc configTreeByBuildType { buildType } {

    set xml [teamcityGET /app/rest/builds?locator=buildType:$buildType,count:1]
    set node [selectNode $xml {/builds/build}]
    set buildId [$node @id]

    return [configTreeByBuildId $buildId]
}

proc configTreeByBuildId { buildId } {

    set xml [teamcityGET /app/rest/builds/id:$buildId]
    set rootNode [selectNode $xml {/build}]
    set revNode [$rootNode selectNodes {revisions/revision}]
    set vcsRootId [[$revNode selectNodes vcs-root-instance] @id]

    # Set project config values
    dict set config projId [[$rootNode selectNodes buildType] @projectId]
    dict set config buildNumber [$rootNode @number]
    dict set config buildId [$rootNode @id]
    dict set config vcsUrl [selectRootUrl $vcsRootId]
    dict set config vcsMasterBranch [getBuildParameter $rootNode "cid.master.branch"]
    dict set config vcsDevBranch [getBuildParameter $rootNode "cid.dev.branch"]
    dict set config vcsBranch [string range [$revNode @vcsBranchName] 11 end]
    dict set config vcsCommit [string range [$revNode @version] 0 6]

    # Checkout this project
    dict with config {
        set workDir [gitClone $projId $vcsUrl $vcsBranch]
        catch { exec git checkout $vcsMasterBranch } res
        catch { exec git reset --hard origin/$vcsMasterBranch } res
        catch { exec git checkout $vcsDevBranch } res
        catch { exec git reset --hard origin/$vcsDevBranch } res
        logDebug "\nCloned $projId into $workDir"
        logDebug "   $vcsMasterBranch ([gitHash $vcsMasterBranch]) [gitSubject $vcsMasterBranch]"
        if { $vcsMasterBranch ne $vcsDevBranch } {
            logDebug "   $vcsDevBranch ([gitHash $vcsDevBranch]) [gitSubject $vcsDevBranch]"
        }
        gitCheckout $projId $vcsCommit
    }

    dict set config vcsMergePolicy [getBuildParameter $rootNode "cid.merge.policy" false]
    dict set config vcsSubject [gitSubject [dict get $config "vcsCommit"]]
    dict set config vcsTagName ""

    # Get the release command
    dict set config mvnExtraArgs [getBuildParameter $rootNode "cid.mvn.extra.args" false]

    # Collect the list of snapshot dependencies
    set dependencies [list]
    foreach { depNode } [$rootNode selectNodes {snapshot-dependencies/build}] {
        set depconf [configTreeByBuildId [$depNode @id]]
        lappend dependencies $depconf
        cd $workDir
    }
    dict set config dependencies $dependencies

    # Set the current POM version
    dict set config pomVersion [pomValue $workDir/pom.xml {mvn:version}]

    # Collect the POM property names for each snapshot dependency
    set pomDepsParam [list]
    set pomDeps [dict create]
    if { [llength $dependencies] > 0 } {
        set pomDepsParam [getBuildParameter $rootNode "cid.pom.dependency.property.names"]
        set pomDeps [getPOMDependencies $config $pomDepsParam]
    }
    dict set config pomDepsParam $pomDepsParam
    dict set config pomDeps $pomDeps

    # Set the last applicable tag name
    dict set config vcsTagName [getApplicableTagName $config]

    # Make dependencies come last
    dict unset config dependencies
    dict set config dependencies $dependencies

    return $config
}

proc getBuildParameter { rootNode name {required true}} {
    set propNode [$rootNode selectNodes {properties/property[@name=$name]}]
    if { $propNode eq "" } {
        if { $required } {
            error "Cannot obtain build parameter: $name"
        } else {
            return ""
        }
    }
    return [$propNode @value]
}

proc getApplicableTagName { config } {

    set projId [dict get $config "projId"]
    set pomVersion [dict get $config "pomVersion"]
    set headRev [gitHash HEAD]
    set subject [gitSubject HEAD]
    set lastAvailableTag [gitLastAvailableTag $pomVersion]

    # If HEAD points to a maven release, we use the associated tag
    if { $lastAvailableTag eq "" } {
        logWarn "Cannot find any tag in $projId"
        return ""
    }

    set tagRev [gitHash $lastAvailableTag]
    set dependencies [dict get $config "dependencies"]

    logDebug "Last available tag in $projId: $lastAvailableTag ($tagRev)"
    logDebug "HEAD of $projId is at: $subject ($headRev)"

    # If HEAD points to a maven release, we use the associated tag
    if { [string match "* prepare for next *" $subject] } {
        logDebug "HEAD of $projId points to maven release"
        return $lastAvailableTag
    }

    # If the tag is reachable from HEAD
    if { [gitIsReachable $tagRev $headRev] } {

        logDebug "Walk back from HEAD of $projId"

        set auxRev [gitHash $headRev]
        set subject [gitSubject $auxRev]

        # Walk back, processing our own upgrade commits
        while { $auxRev ne $tagRev } {
            logDebug "$subject ($auxRev)"
            set upgradeMatch [expr {[string match "?fuse-cid] Upgrade *" $subject] || [string match "?fuse-cid] Upgrading *" $subject]}]
            if { !$upgradeMatch && ![string match "* prepare for next *" $subject] } {
                logDebug "Found user commit: $subject ($auxRev)"
                return ""
            }
            set auxRev [gitHash $auxRev^]
            set subject [gitSubject $auxRev]
        }
    } elseif { ![gitIsReachable $headRev $tagRev] } {
        logWarn "HEAD of $projId not reachable from tag $lastAvailableTag"
        return ""
    }

    logDebug "Verify last available tag: $lastAvailableTag"

    # Checkout the last available tag and obtain the POM dependencies
    gitCheckout $projId $tagRev
    set pomDepsParam [dict get $config "pomDepsParam"]
    set pomDeps [getPOMDependencies $config $pomDepsParam]

    logDebug "POM dependencies: $pomDeps"

    # The tag is not usable if it does not match the dependency versions
    foreach { depconf } $dependencies {
        set depId [dict get $depconf "projId"]
        set tagName [dict get $depconf "vcsTagName"]
        logDebug "Tag in dependency $depId: $tagName"
        if { ![dict exists $pomDeps $depId] } {
            logDebug "POM dependencies do not contain an entry for: $depId"
            return ""
        }
        set pomTag [lindex [dict get $pomDeps $depId] 1]
        if { $tagName ne $pomTag } {
            logDebug "Non-matching tags"
            return ""
        }
    }

    logDebug "Ok to use tag: $lastAvailableTag"
    return $lastAvailableTag
}

proc getPOMDependencies { proj depsParam } {
    set pomDeps [dict create]
    foreach { depconf } [dict get $proj "dependencies"] {
        set depId [dict get $depconf "projId"]
        if { [catch {set name [dict get $depsParam $depId]}] } {
            error "Cannot obtain mapping for $depId in '$depsParam'"
        }
        dict set pomDeps $depId $name [pomValue [pwd]/pom.xml mvn:properties/mvn:$name]
    }
    return $pomDeps
}

proc flattenConfig { config { result ""} } {
    set projId [dict get $config "projId"]
    if { [dict exists $result $projId] == 0 } {
        set depids [list]
        foreach { snap } [dict get $config "dependencies"] {
            lappend depids [dict get $snap "projId"]
            set result [flattenConfig $snap $result]
        }
        dict append result $projId [dict replace $config "dependencies" $depids]
    }
    return $result
}

proc selectNodes { xml path } {
    set doc [dom parse $xml]
    set root [$doc documentElement]
    return [$root selectNodes $path]
}

proc selectNode { xml path } {
    return [lindex [selectNodes $xml $path] 0]
}

proc selectRootUrl { vcsRootId } {
    set xml [teamcityGET /app/rest/vcs-root-instances/id:$vcsRootId]
    set node [selectNode $xml {/vcs-root-instance/properties/property[@name="url"]}]
    return [$node @value]
}

proc pomValue { pomFile path } {
    set fid [open $pomFile]
    set xml [read $fid]
    close $fid
    set doc [dom parse $xml]
    set root [$doc documentElement]
    set node [$root selectNodes -namespaces {mvn http://maven.apache.org/POM/4.0.0} $path]
    if { $node eq ""} { error "Cannot find nodes for '$path' in: $pomFile" }
    return [$node text]
}

proc teamcityGET { path } {
    variable argv
    set serverUrl [expr {[dict exists $argv "-host"] ? [dict get $argv "-host"] : "http://teamcity:8111"}]
    set tcuser [expr {[dict exists $argv "-tcuser"] ? [dict get $argv "-tcuser"] : "restuser" }]
    set tcpass [expr {[dict exists $argv "-tcpass"] ? [dict get $argv "-tcpass"] : "restpass" }]
    dict set config auth [list basic $tcuser $tcpass]
    return [rest::get $serverUrl$path "" $config ]
}

# json::dict2json does not support list values
# https://core.tcl.tk/tcllib/tktview/cfc5194fa29b4cdb20a6841068bea82d34accd7e
proc config2json { dict {level 0} }  {
    set pad [format "%[expr 3 * $level]s" ""]
    set result "\{"
    foreach { key } [dict keys $dict] {
        set val [dict get $dict $key]
        set valIsDict [expr { $key eq "pomDeps" }]
        set valIsListOfDict [expr { $key eq "dependencies" }]

        if { $key ne [lindex $dict 0] } { append result "," }

        # Value is a list of dictionaries
        if { $valIsListOfDict } {
            append result "\n$pad\"$key\": \["
            for {set i 0} {$i < [llength $val]} {incr i} {
                if { $i > 0 } { append result "," }
                append result [config2json [lindex $val $i] [expr $level + 1]]
            }
            append result "\]"
            continue
        }

        # Value is a dictionary
        if { $valIsDict } {
            if { [dict size $val] > 0 } {
                set val [config2json $val [expr $level + 1]]
            } else {
                set val {{}}
            }
            append result "\n$pad\"$key\": $val"
            continue
        }

        # Normal key/value pair
        append result "\n$pad\"$key\": \"$val\""
    }
    append result "\n$pad\}"
    return $result
}

# Main ========================

if { [string match "*/config.tcl" $argv0] } {
    
    set scriptDir [file dirname [info script]]
    source $scriptDir/common.tcl
    
    configMain $argv
}

