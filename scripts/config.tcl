# !/usr/bin/tclsh
#

# Require package rest
# https://core.tcl.tk/tcllib/doc/trunk/embedded/www/tcllib/files/modules/rest/rest.html
package require rest
package require json

set scriptDir [file dirname [info script]]
set targetDir [file normalize $scriptDir/target]

proc configMain { argv } {
    variable targetDir

    if { [llength $argv] < 2 } {
	puts "Usage:"
	puts "  tclsh config.tcl [-buildType buildType|-buildId buildId] [-host host]\n"
	puts "  e.g. tclsh config.tcl -buildType ProjCNext -host http://52.214.125.98:8111"
	puts "  e.g. tclsh config.tcl -buildId 363"
	return 1
    }

    set config [configTree]

    #set json [json::dict2json $config]
    set json [config2json $config]

    # Write json to file
    set fname $targetDir/config.json
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

proc configTree { } {
    variable argv

    if { [dict exists $argv "-buildId"] } {
	set buildId [dict get $argv "-buildId"]
    } else {
	# Get the last successful build id
	set buildType [dict get $argv "-buildType"]
	set xml [teamcityGET /app/rest/builds?locator=buildType:$buildType,count:1]
	set node [selectNode $xml {/builds/build}]
	set buildId [$node @id]
    }

    return [getBuildConfig $buildId]
}

proc verifyConfig { config } {
    puts "Verifying configuration\n"
    puts [config2json $config]

    set problems [list]
    set recipe [flattenConfig $config ]
    dict for { key conf} $recipe {
	dict with conf {
	    # for each dependency get the pomVersion
	    foreach { depName } $dependencies {
		set pomVersion [dict get $recipe $depName "pomVersion"]
		# get the corresponding version from pomProps
		set propName [lindex [dict get $conf "pomProps" $depName] 0]
		set propVersion [lindex [dict get $conf "pomProps" $depName] 1]
		# verify that the two versions are equal
		if { $propVersion ne $pomVersion } {
		    lappend problems "Make $key dependent on $depName ($pomVersion)"
		}
	    }
	}
    }

    if  { [llength $problems] > 0 } {
	puts "\nThis configuration is not consistent\n"
	foreach { prob } $problems {
	    puts $prob
	}
	puts ""
	return 0
    }

    return 1
}

# Private ========================

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

proc getBuildConfig { buildId } {

    set xml [teamcityGET /app/rest/builds/id:$buildId]
    set node [selectNode $xml {/build}]
    set revNode [$node selectNodes {revisions/revision}]
    set vcsRootId [[$revNode selectNodes vcs-root-instance] @id]

    # Set project config values
    dict set config projId [[$node selectNodes buildType] @projectId]
    dict set config vcsUrl [selectRootUrl $vcsRootId]
    dict set config vcsTargetBranch "master"
    dict set config vcsBranch [string range [$revNode @vcsBranchName] 11 end]
    dict set config vcsCommit [string range [$revNode @version] 0 6]
    dict set config vcsCommit [string range [$revNode @version] 0 6]

    # Checkout this project
    dict with config {
	set workDir [gitCheckout $projId $vcsUrl $vcsBranch]
	gitVerifyHeadRevision $projId $vcsBranch $vcsCommit
    }

    dict set config pomVersion [pomValue $workDir/pom.xml {mvn:version}]
    dict set config buildNumber [$node @number]

    # Collect the list of snapshot dependencies
    set snapdeps [dict create]
    foreach { depNode } [$node selectNodes {snapshot-dependencies/build}] {
	set depconf [getBuildConfig [$depNode @id]]
	dict set snapdeps [dict get $depconf "projId"] $depconf
    }

    # Collect the POM property names for each snapshot dependency
    set pomProps [dict create]
    if { [dict size $snapdeps] > 0 } {
	set propNode [$node selectNodes {properties/property[@name="cid.pom.dependency.property.names"]}]

	# Check if the required parameter exists
	if { $propNode eq "" } {
	    puts "\nProvide parameter 'cid.pom.dependency.property.names' with format"
	    puts {   [projId] [POM property name] [projId] [POM property name] ...}
	    puts ""
	    error "Cannot obtain mapping for dependent project versions"
	}
	set props [$propNode @value]
	foreach { key } [dict keys $snapdeps] {
	    if { [catch {set name [dict get $props $key]}] } {
		error "Cannot obtain mapping for $key in '$props'"
	    }
	    dict set pomProps $key $name [pomValue $workDir/pom.xml mvn:properties/mvn:$name]
	}
    }
    dict set config pomProps $pomProps

    # Set the list of snapshot dependencies
    dict set config dependencies [dict values $snapdeps]

    return $config
}

# Checkout or clone the specified branch and change to the resulting workdir
proc gitCheckout { projId vcsUrl vcsBranch } {
    variable targetDir
    set workDir [file normalize $targetDir/checkout/$projId]
    if { [file exists $workDir] } {
	cd $workDir
	catch { exec git clean --force } res
	catch { exec git fetch origin $vcsBranch } res
	catch { exec git checkout $vcsBranch } res
	catch { exec git reset --hard origin/$vcsBranch } res
    } else {
	file mkdir $workDir/..
	catch { exec git clone -b $vcsBranch $vcsUrl $workDir } res
	cd $workDir
    }
    return $workDir
}

proc gitSimpleCheckout { projId vcsBranch } {
    variable targetDir
    set workDir [file normalize $targetDir/checkout/$projId]
    cd $workDir
    catch { exec git checkout $vcsBranch }
    return $workDir
}

proc gitVerifyHeadRevision { projId vcsBranch vcsCommit } {
    set headRev [string trim [exec git log --format=%h -n 1]]
    if { $vcsCommit ne $headRev } {
	error "Expected commit in '$projId' branch '$vcsBranch' is '$vcsCommit', but we have '$headRev'"
    }
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
    set serverUrl [expr { [dict exists $argv "-host"] ? [dict get $argv "-host"] : "http://teamcity:8111"}]
    dict set config auth { basic restuser restpass }
    return [rest::get $serverUrl$path "" $config ]
}

# json::dict2json does not support list values
# https://core.tcl.tk/tcllib/tktview/cfc5194fa29b4cdb20a6841068bea82d34accd7e
proc config2json { dict {level 0} }  {
    set pad [format "%[expr 3 * $level]s" ""]
    set result "\{"
    foreach { key } [dict keys $dict] {
	set val [dict get $dict $key]
	set valIsDict [expr { $key eq "pomProps" }]
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
    configMain $argv
}

