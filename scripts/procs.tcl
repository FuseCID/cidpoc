proc release { name } {
    set visited [list]
    releaseInternal $name visited
}

proc releaseInternal { projName visited } {
    variable config
    upvar $visited upvarA

    # If we have already visited this proj, do nothing

    if { [lsearch $visited $projName] >= 0} {
	return
    }

    # Transitively process snapshot dependencies

    set proj [dict get $config $projName]
    foreach { projName } [dict keys [dict get $proj deps]] {
	releaseInternal $projName visited
    }

    # Release this project

    releaseProject $proj

    # Mark this project as already visited

    lappend upvarA $projName
}

proc releaseProject { proj } {
    variable config
    dict with proj {
	puts "\nProcessing project: $name"

	cd $workDir
	set currBranch [gitCurrentBranch]

	# Get or create project tag

	if { [isPrepareForNext $currBranch] } {
	    set tagName [gitLastAvailableTag $currBranch]
	} else {
	    pomUpdate $proj
	    set tagName [gitCreateTag $currBranch]
	}

	# Store the tagName in the config
	dict set config $name tagName $tagName

	# Merge the current branch into the target branch
	if { $currBranch ne $targetBranch } {
	    gitMerge $currBranch $targetBranch
	    gitPush $targetBranch origin
	    gitPush $currBranch origin
	}
    }
}

proc execCmd { cmd } {
    puts $cmd
    return [eval exec [split $cmd]]
}

proc gitCheckout { branch } {
    execCmd "git checkout --quiet --force $branch"
}

proc gitCreateTag { branch } {
    set value [pomValue "/project/version"]
    set version [strip $value "-SNAPSHOT"]
    set nextver "[nextVersion $version]-SNAPSHOT"
    mvnRelease $version $nextver
}

proc gitCurrentBranch {} {
    return [exec git rev-parse --abbrev-ref HEAD]
}

proc gitLastAvailableTag { branch } {
    set tagName [exec git describe --abbrev=0]
    puts "Using last available tag: $tagName"
    return $tagName
}

proc gitMerge { currBranch targetBranch } {
    gitCheckout $targetBranch
    execCmd "git merge --ff-only $currBranch"
}

proc gitPush { branch remote } {
    puts "git push $remote $branch"
    catch { exec git push $remote $branch } result
    puts $result
}

proc isPrepareForNext { branch } {
    set subject [exec git log --max-count=1 --pretty=%s $branch]
    set expected "\[maven-release-plugin] prepare for next development iteration"
    return [string equal $subject $expected]
}

proc mvnRelease { version nextVersion} {
    execCmd "mvn release:prepare -DautoVersionSubmodules=true -DreleaseVersion=$version -Dtag=$version -DdevelopmentVersion=$nextVersion"
    execCmd "mvn release:clean"
}

proc nextVersion { version } {
    set tokens [split $version '.']
    set major [lindex $tokens 0]
    set minor [lindex $tokens 1]
    set idx [string length "$major.$minor."]
    set patch [string range $version $idx end]
    set idx [string first "-" $patch]
    if { $idx > 0 } {
	set micro [string range $patch 0 [expr $idx - 1]]
	set patch [string range $patch $idx end]
    } else {
	set micro $patch
	set patch ""
    }
    set micro [expr $micro + 1]
    return "$major.$minor.$micro$patch"
}

proc pomValue { path } {
    catch { exec xpath "pom.xml" $path 2> /dev/null } node
    set elname [lindex [split $path '/'] end]
    set start "<$elname>"
    set end "</$elname>"
    set idx [expr [string last $end $node] - 1]
    return [string range $node [string length $start] $idx]
}

proc pomUpdate { proj } {
    variable config
    set deps [dict get $proj deps]
    foreach depName [dict keys $deps] {
	set pomKey [dict get $deps $depName pomKey]
	set pomVal [pomValue /project/properties/$pomKey]
	set tagName [dict get $config $depName tagName]
	set message "Replace dependency $pomKey with $tagName"
	puts $message
	exec sed -i "" "s#<$pomKey>$pomVal</$pomKey>#<$pomKey>$tagName</$pomKey>#" pom.xml
	exec git add pom.xml
	exec git commit -m $message
    }
}

proc strip { value strip } {
    set idx [expr [string last $strip $value] - 1]
    return [string range $value 0 $idx]
}

