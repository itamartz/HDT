# The IWdsService double - and the ONLY way anything about WDS is provable on
# this machine (DESIGN 6.1, DESIGN 12.2.3).
#
# THERE IS NO WDS ON THIS HOST AND THERE MAY NOT BE. It is Windows 11 Pro, and
# WDS is a Windows Server role; standing one up is refused by PROJECT.md's lab
# safety rules, which confine a PXE responder to the isolated 'HDT Lab' switch:
# a responder answers every machine on its segment, so on a shared one it would
# answer machines that are not part of the test, and anything else answering
# there would silently invalidate the run. So the replace-in-place semantics
# Import-HDTBootImageToWds implements are asserted against THIS, and the one
# thing the real adapter can prove here - that its absence is reported as a named
# dependency error - is asserted in Import-HDTBootImageToWds.Tests.ps1.
#
# Three methods, thin over three WDS cmdlets:
#
#   GetBootImage(architecture)                    -> object[] { ImageName,
#                                                    Architecture, FileName,
#                                                    Version }
#   ImportBootImage(path, imageName, architecture)
#   RemoveBootImage(imageName, architecture)
#
# THE FAKE IS A STORE, NOT A RECORDER. ImportBootImage adds a row GetBootImage
# then answers with, and RemoveBootImage takes one away - because the assertion
# ROADMAP M4 names is "WDS import replacing rather than duplicating an existing
# image", and a double that only recorded calls could not tell one image from
# two.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:seeded = @(
        [pscustomobject] @{ ImageName = 'HDTPE_x64'; Architecture = 'x64'; FileName = 'HDTPE_x64.wim'; Version = '10.0.26100.1' }
        [pscustomobject] @{ ImageName = 'LegacyPE'; Architecture = 'x64'; FileName = 'LegacyPE.wim'; Version = '10.0.19041.1' }
        [pscustomobject] @{ ImageName = 'HDTPE_arm'; Architecture = 'arm64'; FileName = 'HDTPE_arm.wim'; Version = '10.0.26100.1' }
    )
}

Describe 'New-HDTFakeWdsService' {

    Context 'what it was seeded with' {

        It 'returns the images it was seeded with for an architecture' {
            $wds = New-HDTFakeWdsService -Image $script:seeded

            @($wds.GetBootImage('x64') | ForEach-Object { [string] $_.ImageName }) |
                Should -Be @('HDTPE_x64', 'LegacyPE')
        }

        It 'filters by architecture' {
            $wds = New-HDTFakeWdsService -Image $script:seeded

            @($wds.GetBootImage('arm64') | ForEach-Object { [string] $_.ImageName }) | Should -Be @('HDTPE_arm')
        }

        It 'returns an array even for one row' {
            # tests/helpers/README.md F3. One boot image is the normal case, not
            # an edge one, and a scalar there would make the caller's
            # @($row).Count assertions lie.
            $wds = New-HDTFakeWdsService -Image @($script:seeded[2])

            $wds.GetBootImage('arm64') -is [System.Array] | Should -BeTrue
        }

        It 'returns nothing for an architecture it has no image for' {
            $wds = New-HDTFakeWdsService -Image $script:seeded

            @($wds.GetBootImage('x86')).Count | Should -Be 0
        }

        It 'starts empty when nothing was seeded' {
            $wds = New-HDTFakeWdsService

            @($wds.GetBootImage('x64')).Count | Should -Be 0
        }
    }

    Context 'it is a store' {

        It 'adds an image on ImportBootImage' {
            $wds = New-HDTFakeWdsService

            $wds.ImportBootImage('C:\HDTLab\Share\Boot\HDTPE_x64.wim', 'HDTPE_x64', 'x64')

            $row = @($wds.GetBootImage('x64'))
            $row.Count | Should -Be 1
            [string] $row[0].ImageName | Should -BeExactly 'HDTPE_x64'
            [string] $row[0].Architecture | Should -BeExactly 'x64'
            [string] $row[0].FileName | Should -BeExactly 'HDTPE_x64.wim'
        }

        It 'removes one on RemoveBootImage' {
            $wds = New-HDTFakeWdsService -Image $script:seeded

            $wds.RemoveBootImage('HDTPE_x64', 'x64')

            @($wds.GetBootImage('x64') | ForEach-Object { [string] $_.ImageName }) | Should -Be @('LegacyPE')
        }

        It 'removes only the row for that architecture' {
            $wds = New-HDTFakeWdsService -Image @(
                [pscustomobject] @{ ImageName = 'HDTPE'; Architecture = 'x64'; FileName = 'a.wim'; Version = '1' }
                [pscustomobject] @{ ImageName = 'HDTPE'; Architecture = 'arm64'; FileName = 'b.wim'; Version = '1' })

            $wds.RemoveBootImage('HDTPE', 'x64')

            @($wds.GetBootImage('x64')).Count | Should -Be 0
            @($wds.GetBootImage('arm64')).Count | Should -Be 1
        }

        It 'matches the name case-insensitively on remove' {
            # WDS image names are not case sensitive, and neither is the command
            # that decides whether one already exists.
            $wds = New-HDTFakeWdsService -Image $script:seeded

            $wds.RemoveBootImage('hdtpe_X64', 'x64')

            @($wds.GetBootImage('x64') | ForEach-Object { [string] $_.ImageName }) | Should -Be @('LegacyPE')
        }

        It 'throws when asked to remove an image it does not have' {
            # Remove-WdsBootImage refuses an image name that is not there, and a
            # fake that shrugged would let a caller that removed the wrong thing
            # pass (SPIKES S9.3's lesson, in another service).
            $wds = New-HDTFakeWdsService -Image $script:seeded

            { $wds.RemoveBootImage('NoSuchImage', 'x64') } | Should -Throw
        }

        It 'leaves one image when the same name is imported twice through remove-then-import' {
            $wds = New-HDTFakeWdsService

            $wds.ImportBootImage('C:\a\HDTPE_x64.wim', 'HDTPE_x64', 'x64')
            $wds.RemoveBootImage('HDTPE_x64', 'x64')
            $wds.ImportBootImage('C:\b\HDTPE_x64.wim', 'HDTPE_x64', 'x64')

            @($wds.GetBootImage('x64')).Count | Should -Be 1
            [string] @($wds.GetBootImage('x64'))[0].FileName | Should -BeExactly 'HDTPE_x64.wim'
        }

        It 'accumulates when a caller imports twice without removing' {
            # THE FAILURE THE COMMAND EXISTS TO PREVENT, staged here so the fake
            # is known to be capable of showing it. If this fake silently
            # de-duplicated, Import-HDTBootImageToWds's duplicate test would pass
            # for a command that never called RemoveBootImage.
            $wds = New-HDTFakeWdsService

            $wds.ImportBootImage('C:\a\HDTPE_x64.wim', 'HDTPE_x64', 'x64')
            $wds.ImportBootImage('C:\b\HDTPE_x64.wim', 'HDTPE_x64', 'x64')

            @($wds.GetBootImage('x64')).Count | Should -Be 2
        }
    }

    Context 'failure' {

        It 'throws the seeded message for a method' {
            $wds = New-HDTFakeWdsService -Failure @{ ImportBootImage = 'The image file is not a valid Windows image.' }

            { $wds.ImportBootImage('C:\a\x.wim', 'x', 'x64') } |
                Should -Throw '*not a valid Windows image*'
        }

        It 'throws the seeded message for GetBootImage' {
            $wds = New-HDTFakeWdsService -Failure @{ GetBootImage = 'The Windows Deployment Services server is not configured.' }

            { $wds.GetBootImage('x64') } | Should -Throw '*not configured*'
        }
    }

    Context 'recording' {

        It 'records every call' {
            $wds = New-HDTFakeWdsService -Image $script:seeded

            $wds.GetBootImage('x64') | Out-Null
            $wds.RemoveBootImage('HDTPE_x64', 'x64')
            $wds.ImportBootImage('C:\a\HDTPE_x64.wim', 'HDTPE_x64', 'x64')

            @($wds.GetOperationName()) | Should -Be @('GetBootImage', 'RemoveBootImage', 'ImportBootImage')
        }

        It 'records the arguments' {
            $wds = New-HDTFakeWdsService

            $wds.ImportBootImage('C:\a\HDTPE_x64.wim', 'HDTPE_x64', 'x64')

            @($wds.Operations[0].Arguments) | Should -Be @('C:\a\HDTPE_x64.wim', 'HDTPE_x64', 'x64')
        }

        It 'records before it throws' {
            # The attempt is evidence about what the code under test tried, and a
            # recording made after the throw would lose exactly the call a
            # failure investigation needs.
            $wds = New-HDTFakeWdsService

            try { $wds.RemoveBootImage('NoSuchImage', 'x64') } catch { $null = $_ }

            @($wds.GetOperationName()) | Should -Be @('RemoveBootImage')
        }

        It 'appends to the shared journal' {
            $journal = [System.Collections.ArrayList]::new()
            $wds = New-HDTFakeWdsService -Journal $journal

            $wds.GetBootImage('x64') | Out-Null

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('WdsService.GetBootImage')
        }

        It 'names itself WdsService' {
            (New-HDTFakeWdsService).ServiceName | Should -BeExactly 'WdsService'
        }

        It 'records nothing for seeding' {
            $journal = [System.Collections.ArrayList]::new()
            $wds = New-HDTFakeWdsService -Image $script:seeded -Journal $journal

            @($journal).Count | Should -Be 0
            @($wds.Operations).Count | Should -Be 0
        }
    }
}
