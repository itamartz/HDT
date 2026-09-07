# Initialize-HDTWdsBootFile - THE UEFI NETWORK BOOT PROGRAM WDS ON SERVER 2025
# DOES NOT STAGE FOR ITSELF.
#
# THE DEFECT THIS COMMAND EXISTS FOR, observed on this lab's own HDT-WDS-01 on
# 2026-09-02 and not reproduced from any documentation:
#
#   * wdsutil /initialize-server on Server 2025 creates
#     <RemoteInstall>\Boot\x64uefi\ and puts EXACTLY ONE FILE in it: default.bcd.
#     There is no network boot program in it at all;
#   * a Generation 2 client broadcasts, and WDS ANSWERS - the server logs event
#     4096, "The following client booted from PXE", with the client's MAC;
#   * the client prints "Start PXE over IPv4." and about five seconds later the
#     firmware reports "A boot image was not found";
#   * and wdsutil /get-server /show:config REPORTS "Boot files installed:
#     x64uefi - Yes" THE WHOLE TIME. EVERY SERVER-SIDE DIAGNOSTIC SAYS THE
#     SERVER IS FINE. That is why this is worth a command rather than a line in
#     a runbook: a missing NBP is indistinguishable from a server that never
#     answered, and the server's own report of itself is the misleading part.
#
# THE FILES ARE ALREADY ON THE MACHINE, one directory away, in WDS's own source
# tree at %SystemRoot%\System32\RemInst\boot\x64. Nothing is downloaded. This
# copies what the role already installed into the place the role failed to put
# it.
#
# WHY IT IS A SHIPPED COMMAND AND NOT A SCRIPT ON A SHARE. It lived only in
# C:\HDTLab\Share\TaskSequences\WDS-2025\Initialize-WdsServer.ps1, which
# CLAUDE.md rule 8 calls by its name: a second source of truth. The knowledge -
# which directory WDS serves a UEFI client from, which file it wants, and that
# the server lies about having it - is HDT's, not one customer's workspace's.
#
# IT IS PROVABLE AGAINST A FAKE because every path goes through IFileSystem and
# the source root through IEnvironmentProvider, so the whole of it runs here on
# a Windows 11 laptop with no WDS role in sight.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:reminst = 'C:\Windows\System32\RemInst\boot\x64'

    # THE SIZES ARE THE REAL ONES, read off HDT-WDS-01 on 2026-09-07, because
    # CLAUDE.md's fixture rule is real captured data and because the two files
    # BEING DIFFERENT is the point of staging both: wdsmgfw.efi is 1,095,072
    # bytes and BOOTMGFW.EFI is 2,759,624. The documentation names wdsmgfw.efi;
    # the directory contains both; they are not the same bootloader.
    $script:newSource = {
        return (New-HDTFakeFileSystem -File @{
                ('{0}\wdsmgfw.efi' -f $script:reminst)  = 'wdsmgfw'
                ('{0}\bootmgfw.efi' -f $script:reminst) = 'bootmgfw'
                ('{0}\bootmgr.exe' -f $script:reminst)  = 'bootmgr'
                ('{0}\abortpxe.com' -f $script:reminst) = 'abortpxe'
                # WHAT /initialize-server ACTUALLY LEFT BEHIND: one file.
                'C:\RemoteInstall\Boot\x64uefi\default.bcd'  = 'bcd'
            })
    }

    $script:newEnvironment = {
        return (New-HDTFakeEnvironmentProvider -Variable @{ 'SystemRoot' = 'C:\Windows' })
    }
}

Describe 'Initialize-HDTWdsBootFile' {

    Context 'the network boot program' {

        BeforeEach {
            $script:fs = & $script:newSource
            $script:env = & $script:newEnvironment
        }

        It 'stages the UEFI network boot program into Boot\x64uefi' {
            # THE ONE FILE WHOSE ABSENCE PRODUCES "A boot image was not found".
            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                -FileSystem $script:fs -Environment $script:env -Confirm:$false | Out-Null

            $script:fs.TestPath('C:\RemoteInstall\Boot\x64uefi\wdsmgfw.efi') | Should -BeTrue
        }

        It 'stages every declared boot file' {
            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                -FileSystem $script:fs -Environment $script:env -Confirm:$false | Out-Null

            foreach ($name in 'wdsmgfw.efi', 'bootmgfw.efi', 'bootmgr.exe', 'abortpxe.com') {
                $script:fs.TestPath(('C:\RemoteInstall\Boot\x64uefi\{0}' -f $name)) | Should -BeTrue -Because ("{0} is declared" -f $name)
            }
        }

        It 'stages the architecture-neutral Boot\x64 as well' {
            # A client that resolves the NBP by name against Boot\x64 is then
            # served too, rather than failing for a reason nothing reports.
            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                -FileSystem $script:fs -Environment $script:env -Confirm:$false | Out-Null

            $script:fs.TestPath('C:\RemoteInstall\Boot\x64\wdsmgfw.efi') | Should -BeTrue
        }

        It 'creates the Images folder under each architecture' {
            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                -FileSystem $script:fs -Environment $script:env -Confirm:$false | Out-Null

            $script:fs.TestPath('C:\RemoteInstall\Boot\x64uefi\Images') | Should -BeTrue
            $script:fs.TestPath('C:\RemoteInstall\Boot\x64\Images') | Should -BeTrue
        }

        It 'reports the network boot program it proved' {
            $result = Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                -FileSystem $script:fs -Environment $script:env -Confirm:$false

            [string] $result.NetworkBootProgram | Should -BeExactly 'C:\RemoteInstall\Boot\x64uefi\wdsmgfw.efi'
            $result.Complete | Should -BeTrue
        }

        It 'names the files it staged' {
            $result = Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                -FileSystem $script:fs -Environment $script:env -Confirm:$false

            @($result.Staged) | Should -Contain 'C:\RemoteInstall\Boot\x64uefi\wdsmgfw.efi'
            @($result.Staged).Count | Should -Be 8
        }
    }

    Context 'it is additive, because a resume must not undo a server' {

        It 'leaves a file that is already there exactly as it stands' {
            # The engine checkpoints across reboots and can re-enter a step. A
            # server somebody has since customised must not be overwritten by a
            # resume, so an existing file is left and REPORTED rather than
            # silently replaced.
            $fs = New-HDTFakeFileSystem -File @{
                ('{0}\wdsmgfw.efi' -f $script:reminst)             = 'from the role'
                'C:\RemoteInstall\Boot\x64uefi\wdsmgfw.efi'        = 'somebody edited this'
            }

            $result = Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                -FileSystem $fs -Environment (& $script:newEnvironment) -Confirm:$false

            $fs.ReadAllText('C:\RemoteInstall\Boot\x64uefi\wdsmgfw.efi') | Should -BeExactly 'somebody edited this'
            @($result.AlreadyPresent) | Should -Contain 'C:\RemoteInstall\Boot\x64uefi\wdsmgfw.efi'
        }

        It 'is idempotent - a second run stages nothing and still reports Complete' {
            $fs = & $script:newSource
            $env = & $script:newEnvironment

            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' -FileSystem $fs -Environment $env -Confirm:$false | Out-Null
            $second = Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' -FileSystem $fs -Environment $env -Confirm:$false

            @($second.Staged).Count | Should -Be 0
            $second.Complete | Should -BeTrue
        }
    }

    Context 'refusals' {

        It 'refuses when the WDS source tree is not there, naming the role' {
            # Nothing to copy means the role is not installed, or was installed
            # without its management tools - which is a far better sentence than
            # a copy failing four files in.
            $fs = New-HDTFakeFileSystem

            { Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                    -FileSystem $fs -Environment (& $script:newEnvironment) -Confirm:$false } |
                Should -Throw '*RemInst*'
        }

        It 'refuses when the network boot program is still absent afterwards' {
            # THE ASSERTION THAT MATTERS. A source tree with everything BUT
            # wdsmgfw.efi stages four files, reports success by every other
            # measure, and leaves a server that answers a client and then cannot
            # serve it - which is precisely the failure this command exists for,
            # so it is a refusal rather than a warning.
            $fs = New-HDTFakeFileSystem -File @{
                ('{0}\bootmgfw.efi' -f $script:reminst) = 'bootmgfw'
                ('{0}\bootmgr.exe' -f $script:reminst)  = 'bootmgr'
            }

            { Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                    -FileSystem $fs -Environment (& $script:newEnvironment) -Confirm:$false } |
                Should -Throw '*wdsmgfw.efi*'
        }

        It 'says what the client and the server each report when it is missing' {
            $fs = New-HDTFakeFileSystem -File @{ ('{0}\bootmgr.exe' -f $script:reminst) = 'bootmgr' }

            $record = $null
            try {
                Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                    -FileSystem $fs -Environment (& $script:newEnvironment) -Confirm:$false
            } catch { $record = $_ }

            # The whole value of the message is that it names the CONTRADICTION -
            # the server says yes and the client says no - because somebody
            # reading it has just spent an hour trusting the server.
            [string] $record.Exception.Message | Should -BeLike '*A boot image was not found*'
        }

        It 'throws HDTConfigurationError' {
            $fs = New-HDTFakeFileSystem

            $record = $null
            try {
                Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                    -FileSystem $fs -Environment (& $script:newEnvironment) -Confirm:$false
            } catch { $record = $_ }

            [string] $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    Context 'ShouldProcess' {

        It 'copies nothing under -WhatIf' {
            # It writes into a live PXE server's TFTP root (CLAUDE.md hard rule 6).
            $fs = & $script:newSource

            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                -FileSystem $fs -Environment (& $script:newEnvironment) -WhatIf | Out-Null

            $fs.TestPath('C:\RemoteInstall\Boot\x64uefi\wdsmgfw.efi') | Should -BeFalse
            @($fs.Operations | Where-Object { $_.Operation -eq 'CopyItem' }).Count | Should -Be 0
        }

        It 'declares SupportsShouldProcess' {
            (Get-Command -Name 'Initialize-HDTWdsBootFile').Parameters.Keys | Should -Contain 'WhatIf'
        }
    }

    Context 'other architectures' {

        It 'reads the source from the architecture it was asked for' {
            $fs = New-HDTFakeFileSystem -File @{
                'C:\Windows\System32\RemInst\boot\x86\wdsmgfw.efi' = 'wdsmgfw'
            }

            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' -Architecture 'x86' `
                -FileSystem $fs -Environment (& $script:newEnvironment) -Confirm:$false | Out-Null

            $fs.TestPath('C:\RemoteInstall\Boot\x86uefi\wdsmgfw.efi') | Should -BeTrue
        }

        It 'stages arm64 into one directory, because WDS has no arm64uefi' {
            # WDS's own /get-server /show:config lists x86, x64, arm64, arm,
            # x86uefi and x64uefi - there is no arm64uefi, because arm64 is UEFI
            # only and Boot\arm64 IS its UEFI tree. Inventing a directory WDS
            # never reads would stage files nothing serves.
            $fs = New-HDTFakeFileSystem -File @{
                'C:\Windows\System32\RemInst\boot\arm64\wdsmgfw.efi' = 'wdsmgfw'
            }

            $result = Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' -Architecture 'arm64' `
                -FileSystem $fs -Environment (& $script:newEnvironment) -Confirm:$false

            $fs.TestPath('C:\RemoteInstall\Boot\arm64\wdsmgfw.efi') | Should -BeTrue
            $fs.TestPath('C:\RemoteInstall\Boot\arm64uefi') | Should -BeFalse
            [string] $result.NetworkBootProgram | Should -BeExactly 'C:\RemoteInstall\Boot\arm64\wdsmgfw.efi'
        }
    }

    Context 'the source root' {

        It 'reads SystemRoot through the injected environment rather than $env:' {
            # PROJECT constraint 4: engine logic does not touch $env: directly.
            # Proven by MOVING it - a machine whose Windows is not on C: stages
            # from the right tree here and would not if the path were a literal.
            $fs = New-HDTFakeFileSystem -File @{
                'D:\Windows\System32\RemInst\boot\x64\wdsmgfw.efi' = 'wdsmgfw'
            }
            $env = New-HDTFakeEnvironmentProvider -Variable @{ 'SystemRoot' = 'D:\Windows' }

            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' `
                -FileSystem $fs -Environment $env -Confirm:$false | Out-Null

            $fs.TestPath('C:\RemoteInstall\Boot\x64uefi\wdsmgfw.efi') | Should -BeTrue
            @($env.GetOperationName()) | Should -Contain 'GetVariable'
        }

        It 'takes an explicit -SourcePath over the environment' {
            $fs = New-HDTFakeFileSystem -File @{
                'E:\WdsBits\wdsmgfw.efi' = 'wdsmgfw'
            }

            Initialize-HDTWdsBootFile -RemoteInstallPath 'C:\RemoteInstall' -SourcePath 'E:\WdsBits' `
                -FileSystem $fs -Environment (& $script:newEnvironment) -Confirm:$false | Out-Null

            $fs.TestPath('C:\RemoteInstall\Boot\x64uefi\wdsmgfw.efi') | Should -BeTrue
        }
    }
}
