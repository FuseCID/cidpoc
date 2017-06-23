# !/usr/bin/tclsh
#

package require json

proc prmergeMain { argc argv } {

    if { $argc < 3 } {
	puts "Usage:"
	puts "  tclsh prmerge.tcl repoUrl prBranch authToken\n"
	puts "  e.g. tclsh prmerge.tcl %vcsroot.url% %teamcity.build.branch% %github.oauth.token%"
	puts "  e.g. tclsh prmerge.tcl https://github.com/FuseCID/cidpocC pull/4 5810305a47..."
	return 1
    }

    set repoUrl [lindex $argv 0]
    set prBranch [lindex $argv 1]
    set authToken [lindex $argv 2]

    prmerge $repoUrl $prBranch $authToken
}

proc prmerge { repoUrl prBranch authToken } {
    puts "Repository: $repoUrl"
    puts "Branch: $prBranch"

    if { [string first "pull/" $prBranch] != 0 } {
	puts "Not a pull request, do nothing!"
	exit 0
    }

    set idx [string first "github.com" $repoUrl]
    set repo [string range $repoUrl [expr $idx + 11] end]
    set pull [string range $prBranch 5 end]

    if { ![catch { exec curl -X PUT -H "Authorization: token $authToken" -d "\{\"merge_method\":\"rebase\"\}" https://api.github.com/repos/$repo/pulls/$pull/merge 2> /dev/null } res] } {
	puts $res
	set message [dict get [json::json2dict $res] message]
	exit [expr [string match "Pull Request successfully merged" $message] - 1]
    }
}

# Main ========================

if { [string match "*/prmerge.tcl" $argv0] } {
    prmergeMain $argc $argv
}

