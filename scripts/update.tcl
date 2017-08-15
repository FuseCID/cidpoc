# !/usr/bin/tclsh
#

dict set config camel vcsSourceUrl "git@github.com:jboss-fuse/camel.git"
dict set config camel vcsSourceBranch "master"
dict set config camel vcsTargetUrl "git@github.com:FuseCID/camel.git"
dict set config camel vcsTargetBranch "fuse7"

dict set config fuse-patch vcsSourceUrl "git@github.com:jboss-fuse/fuse-patch.git"
dict set config fuse-patch vcsSourceBranch "2.x-redhat"
dict set config fuse-patch vcsTargetUrl "git@github.com:FuseCID/fuse-patch.git"
dict set config fuse-patch vcsTargetBranch "fuse7"

dict set config hawtio vcsSourceUrl "git@github.com:jboss-fuse/hawtio.git"
dict set config hawtio vcsSourceBranch "2.x-redhat"
dict set config hawtio vcsTargetUrl "git@github.com:FuseCID/hawtio.git"
dict set config hawtio vcsTargetBranch "fuse7"

dict set config wildfly-camel vcsSourceUrl "git@github.com:jboss-fuse/wildfly-camel.git"
dict set config wildfly-camel vcsSourceBranch "4.x-redhat"
dict set config wildfly-camel vcsTargetUrl "git@github.com:FuseCID/wildfly-camel.git"
dict set config wildfly-camel vcsTargetBranch "next"

dict set config wildfly-camel-examples vcsSourceUrl "git@github.com:wildfly-extras/wildfly-camel-examples.git"
dict set config wildfly-camel-examples vcsSourceBranch "4.x-redhat"
dict set config wildfly-camel-examples vcsTargetUrl "git@github.com:FuseCID/wildfly-camel-examples.git"
dict set config wildfly-camel-examples vcsTargetBranch "next"

dict set config fuse-eap vcsSourceUrl "git@github.com:jboss-fuse/fuse-eap.git"
dict set config fuse-eap vcsSourceBranch "master"
dict set config fuse-eap vcsTargetUrl "git@github.com:FuseCID/fuse-eap.git"
dict set config fuse-eap vcsTargetBranch "next"

proc updateMain { argv } {
    variable checkoutDir
    variable config

    if { [dict exists $argv "-dir"] } {
        set checkoutDir [dict get $argv "-dir"]
    }

    dict for { projId proj } $config {
        updateProject $projId $proj
    }
}

proc updateProject { projId proj } {
    variable checkoutDir

    logInfo "=================================================="
    logInfo "Update: $checkoutDir/$projId"
    logInfo "=================================================="

    dict with proj {

        # Find the remote name for the vcsTargetUrl
        if { [file exists $checkoutDir/$projId] } {
            cd $checkoutDir/$projId
            set targetRepo [gitRemoteName $vcsTargetUrl]
            if { $targetRepo eq "" } {
                logError [exec git remote -v]
                error "Cannot obtain remote name for: $vcsTargetUrl"
            }
            logInfo "Using remote '$targetRepo' for $vcsTargetUrl"
        } else {
            set targetRepo "origin"
        }

        gitClone $projId $vcsTargetUrl $vcsTargetBranch $targetRepo

        # Find or add the remote name for the vcsSourceUrl
        set sourceRepo [gitRemoteName $vcsSourceUrl]
        if { $sourceRepo eq "" } {
            set sourceRepo "jboss-fuse"
            gitRemoteAdd $sourceRepo $vcsSourceUrl
        }

        catch { exec git checkout $vcsTargetBranch } res
        catch { exec git reset --hard $targetRepo/$vcsTargetBranch } res
        catch { exec git fetch --force $sourceRepo $vcsSourceBranch } res
        catch { exec git checkout -B $vcsSourceBranch FETCH_HEAD } res
        
        gitMerge $projId $vcsSourceBranch $vcsTargetBranch
        gitPush $targetRepo $vcsTargetBranch
    }
}

# Main ========================

if { [string match "*/update.tcl" $argv0] } {

    set scriptDir [file dirname [info script]]
    source $scriptDir/common.tcl

    updateMain $argv
}
