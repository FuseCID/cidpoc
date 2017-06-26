# !/usr/bin/tclsh
#

package require json

proc prmergeMain { argv } {

    if { [llength $argv] < 6 } {
	puts "Usage:"
	puts "  tclsh prmerge.tcl -repo repoUrl -branch pullBranch -oauth token\n"
	puts "  e.g. tclsh prmerge.tcl -repo https://github.com/FuseCID/cidpocC -branch pull/4 -oauth 5810305a47"
	puts "  e.g. tclsh prmerge.tcl -repo %vcsroot.url% -branch %teamcity.build.branch% -oauth %cid.github.oauth.token%"
	return 1
    }

    set repo [dict get $argv "-repo"]
    set branch [dict get $argv "-branch"]
    set oauth [dict get $argv "-oauth"]

    prmerge $repo $branch $oauth
}

proc prmerge { repo branch oauth } {
    puts "Repository: $repo"
    puts "Branch: $branch"

    if { [string first "pull/" $branch] != 0 } {
	puts "Not a pull request, do nothing!"
	exit 0
    }

    set idx [string first "github.com" $repo]
    set repo [string range $repo [expr $idx + 11] end]
    set pull [string range $branch 5 end]

    if { ![catch { exec curl -X PUT -H "Authorization: token $oauth" -d "\{\"merge_method\":\"rebase\"\}" https://api.github.com/repos/$repo/pulls/$pull/merge 2> /dev/null } res] } {
	puts $res
	set message [dict get [json::json2dict $res] message]
	exit [expr [string match "Pull Request successfully merged" $message] - 1]
    }
}

# Main ========================

if { [string match "*/prmerge.tcl" $argv0] } {
    prmergeMain $argv
}

