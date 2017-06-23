# !/usr/bin/tclsh
#

# Require package rest
# https://core.tcl.tk/tcllib/doc/trunk/embedded/www/tcllib/files/modules/rest/rest.html
package require rest
package require json

set TC_URL "http://teamcity:8111"

proc configMain { argc argv } {

    if { $argc != 1 } {
	puts "Usage:"
	puts "   tclsh config.tcl projId"
	return 1
    }

    set projId [lindex $argv 0]
    set config [configTree $projId]

    #set json [json::dict2json $config]
    set json [config2json $config]

    # Create target dir
    set scriptDir [file dirname [info script]]
    set targetDir [file normalize $scriptDir/target]
    file mkdir $targetDir

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

    puts $json

}

proc configTree { projId } {

    # Get the last successful build id
    set xml [teamcityGET /app/rest/builds?locator=project:$projId,status:SUCCESS,count:1]
    set node [selectNode $xml {/builds/build}]
    set buildId [$node @id]

    return [getBuildConfig $buildId]
}

# Private ========================

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
    dict set config number [$node @number]

    # Set project properies
    foreach { propNode } [$node selectNodes {properties/property}] {
	set name [$propNode @name]
	set value [$propNode @value]
	if { $name eq "cid.pom.dependency.property.names" } {
	    dict set config pomMapping $value
	}
    }

    # Set the list of snapshot dependencies
    set snapdeps [list]
    foreach { depNode } [$node selectNodes {snapshot-dependencies/build}] {
	lappend snapdeps [getBuildConfig [$depNode @id]]
    }
    dict set config snapdeps $snapdeps

    return $config
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

proc teamcityGET { path } {
    variable TC_URL
    dict set config auth { basic restuser restpass }
    return [rest::get $TC_URL$path "" $config ]
}

# json::dict2json does not support list values
# https://core.tcl.tk/tcllib/tktview/cfc5194fa29b4cdb20a6841068bea82d34accd7e
proc config2json { dict {level 0} }  {
    set pad [format "%[expr 3 * $level]s" ""]
    set result "\n$pad\{"
    foreach { key } [dict keys $dict] {
	set val [dict get $dict $key]
	if { $key ne [lindex $dict 0] } { append result "," }
	if { $key eq "snapdeps" } {
	    append result "\n$pad\"$key\": \["
	    for {set i 0} {$i < [llength $val]} {incr i} {
		if { $i > 0 } { append result "," }
		append result [config2json [lindex $val $i] [expr $level + 1]]
	    }
	    append result "\]"
	} else {
	    append result "\n$pad\"$key\": \"$val\""
	}
    }
    append result "\n$pad\}"
    return $result
}

# Main ========================

if { [string match "*/config.tcl" $argv0] } {
    configMain $argc $argv
}

