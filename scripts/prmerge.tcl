# !/usr/bin/tclsh
#

package require json

if { $argc != 3 } {
    puts "Usage:"
    puts "  $argv0 vcsrootUrl buildBranch oauthToken\n"
    puts "  e.g. $argv0 %vcsroot.url% %teamcity.build.branch% %github.oauth.token%"
    puts "  e.g. $argv0 https://github.com/FuseCID/cidpocC pull/4 5810305a47..."
    return 1
}

set repoUrl [lindex $argv 0]
set buildBranch [lindex $argv 1]
set authToken [lindex $argv 2]

puts "Repository: $repoUrl"
puts "Build branch: $buildBranch"

if { [string first "pull/" $buildBranch] != 0 } {
    puts "Not a pull request, do nothing!"
    exit 0
}

set idx [string first "github.com" $repoUrl]
set repo [string range $repoUrl [expr $idx + 11] end]
set pull [string range $buildBranch 5 end]

if { ![catch { exec curl -X PUT -H "Authorization: token $authToken" -d "\{\"merge_method\":\"rebase\"\}" https://api.github.com/repos/$repo/pulls/$pull/merge 2> /dev/null } res] } {
    puts $res
    set message [dict get [json::json2dict $res] message]
    exit [expr [string match "Pull Request successfully merged" $message] - 1]
}
