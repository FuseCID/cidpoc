# !/usr/bin/tclsh
#

#
# Define project structure
#
dict set config projA name projA
dict set config projA workDir /Users/tdiesler/git/cidpocA
dict set config projA targetBranch master
dict set config projA deps [dict create]

dict set config projB name projB
dict set config projB workDir /Users/tdiesler/git/cidpocB
dict set config projB targetBranch master
dict set config projB deps [dict create]

dict set config projC name projC
dict set config projC workDir /Users/tdiesler/git/cidpocC
dict set config projC targetBranch master
dict set config projC deps projA pomKey version.cidpoc.a

dict set config projD name projD
dict set config projD workDir /Users/tdiesler/git/cidpocD
dict set config projD targetBranch master
dict set config projD deps projA pomKey version.cidpoc.a
dict set config projD deps projB pomKey version.cidpoc.b

dict set config projE name projE
dict set config projE workDir /Users/tdiesler/git/cidpocE
dict set config projE targetBranch master
dict set config projE deps projB pomKey version.cidpoc.b
dict set config projE deps projD pomKey version.cidpoc.d

