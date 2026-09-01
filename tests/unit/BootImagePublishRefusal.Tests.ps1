# What a technician reads when a boot image builds and then cannot be published.
#
# THIS FAILURE HAPPENED HERE, AND WHAT IT SAID WAS USELESS. Update-HDTBootImage
# spent six minutes mounting, servicing and capturing a WIM, built
# HDTPE_x64.wim.new and HDTPE_x64.iso.new correctly, and then died on the rename
# with
#
#     Exception calling "MoveItem" with "2" argument(s): "... Cannot create a
#     file when that file already exists."
#
# which is a sentence about a filesystem API. The actual cause was HDT-WSUS-01
# running with C:\HDTLab\Share\Boot\HDTPE_x64.iso in its DVD drive: Move-Item
# -Force deletes the destination before renaming, the delete failed because the
# file was open, and what came back was the error from the rename that followed.
#
# THE BUILD IS NOT LOST, AND THAT IS THE OTHER HALF NOBODY WAS TOLD. Both
# artifacts are on disk under their staging names, complete and verified - so
# the recovery is to close whatever holds the file and rename them, not to
# spend another six minutes building what already exists. A message that does
# not say so costs the rebuild.
#
# AND THE PRE-FLIGHT PROBE DOES NOT CATCH THIS, despite a comment saying it is
# exactly what it catches. It writes and removes the STAGING names, which are
# never the files anybody has open; the locked file is the DESTINATION, and
# nothing tests that. The comment there now says so rather than claiming a
# guarantee it does not provide, and this refusal is where the case is actually
# handled.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

    Describe 'Get-HDTBootImagePublishRefusal' {

        BeforeAll {
            $script:said = Get-HDTBootImagePublishRefusal `
                -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.iso' `
                -Staged 'C:\HDTLab\Share\Boot\HDTPE_x64.iso.new' `
                -Reason 'Cannot create a file when that file already exists.'
        }

        It 'names the artifact that could not be replaced' {
            $script:said | Should -BeLike '*C:\HDTLab\Share\Boot\HDTPE_x64.iso*'
        }

        It 'names the staging file the finished build is sitting in' {
            # THE RECOVERY IS A RENAME, NOT A REBUILD, and this is the only place
            # that says so. Without it the obvious response to a failed build is
            # to run it again, which is six minutes to reach the same rename.
            $script:said | Should -BeLike '*HDTPE_x64.iso.new*'
        }

        It 'says the build itself succeeded' {
            $script:said | Should -Match '(?i)built|succeeded|complete'
        }

        It 'names the cause a technician can act on' {
            # A VIRTUAL MACHINE WITH THE ISO IN ITS DVD DRIVE is the case this
            # lab hits, and naming it is the difference between a message that
            # ends the investigation and one that starts it.
            $script:said | Should -Match '(?i)open'
            $script:said | Should -Match '(?i)DVD'
        }

        It 'carries the underlying reason rather than replacing it' {
            # THE ORIGINAL TEXT SURVIVES. A friendlier message that throws the
            # real error away is worse than the real error when the cause turns
            # out to be something else - permissions, a full disk, a network
            # share that went away.
            $script:said | Should -BeLike '*Cannot create a file when that file already exists.*'
        }

        It 'does not pretend to know which process holds it' {
            # HDT CANNOT SEE THE HANDLE. It offers the likely cause and does not
            # assert one, which is the same line Import-HDTWindowsUpdate draws
            # between what a package states and what an administrator decides.
            $script:said | Should -Not -Match '(?i)\bis held by\b'
        }

        Context 'the WIM, which fails for the same reason and reads differently' {

            It 'names whichever artifact it was given' {
                $wim = Get-HDTBootImagePublishRefusal `
                    -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.wim' `
                    -Staged 'C:\HDTLab\Share\Boot\HDTPE_x64.wim.new' `
                    -Reason 'Access to the path is denied.'

                $wim | Should -BeLike '*HDTPE_x64.wim*'
                $wim | Should -BeLike '*HDTPE_x64.wim.new*'
                $wim | Should -BeLike '*Access to the path is denied.*'
            }
        }
    }
}
