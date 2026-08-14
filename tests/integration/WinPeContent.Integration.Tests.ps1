# THE FACT ROADMAP M2'S QUESTION TURNS ON, READ OUT OF A REAL WinPE IMAGE.
#
# M2 asked - and named phase 05 as the owner - "whether WinPE needs
# `wpeutil reboot` rather than `shutdown.exe`". Five plans later
# 05-VERIFICATION.md still recorded it as not_answered, and both
# New-HDTPowerService.ps1 and the IPowerService contract carried the comment
# "UNVERIFIED, RECORDED FOR PHASE 05".
#
# It is not a matter of taste. shutdown.exe IS NOT IN WinPE. A power service that
# names it there is not a service with a stylistic preference, it is a service
# that raises "The term 'shutdown.exe' is not recognized" on the one machine
# nobody can attach a debugger to, at the moment it was supposed to reboot.
#
# WHY THIS FILE EXISTS AT ALL, rather than the sentence above living in a
# comment: a fact nobody re-measures is a fact that goes stale. This mounts the
# REAL ADK winpe.wim - and HDT's own built boot image when there is one - and
# asserts the presence and the absence directly. The day an ADK ships
# shutdown.exe in WinPE, this file says so instead of a design document being
# quietly wrong.
#
# ANTI-VACUITY IS BUILT IN: the same mount asserts wpeutil.exe is PRESENT. A
# mount that failed, or a wrong System32 path, would fail that assertion first -
# so "shutdown.exe is absent" can never be an artefact of looking in the wrong
# place (SPIKES S9.15b).
#
# READ-ONLY, ALWAYS. Mount-WindowsImage -ReadOnly and Dismount -Discard in a
# finally: nothing here modifies an image, least of all the ADK's own.
#
# EVERY SKIP CONDITION IS RECOMPUTED INSIDE BeforeAll (SPIKES S9.15).

BeforeDiscovery {
    $script:discoveryPe = $false
    try {
        Import-Module -Name (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        $script:discoveryPe = Test-Path -LiteralPath (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop) -PathType Leaf
    } catch {
        $script:discoveryPe = $false
    }

    $script:skipWinPeContent = -not $script:discoveryPe

    # SET HERE AND NOWHERE ELSE, because a `-Skip:` is evaluated at DISCOVERY and
    # discovery does not share a scope with BeforeAll. The first draft of this
    # file read a BeforeAll variable from a Context's -Skip: and, under the
    # StrictMode ./build.ps1 sets, DISCOVERY DIED - Pester dropped three of the
    # four contexts and reported "4 passed, 0 failed". SPIKES S9.15 for the
    # fourth time, and the first time its symptom was a MISSING result rather
    # than a wrong one. build.ps1 now fails on FailedContainersCount because of
    # it. The run condition is recomputed in BeforeAll for the bodies.
    $script:skipBuilt = -not (Test-Path -LiteralPath 'C:\HDTLab\scratch\bootimage\Share\Boot\HDTPE_x64.wim' -PathType Leaf)

    if ($script:skipWinPeContent) {
        Write-Warning 'WinPeContent.Integration.Tests.ps1 is SKIPPED. It mounts the real ADK winpe.wim read-only, which does not resolve on this machine. Install the Windows ADK with the Windows PE add-on, or run Get-HDTAdkPath -All to see which assets are missing.'
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # RECOMPUTED, not borrowed from BeforeDiscovery: the two phases do not share
    # a scope and reading it here throws under the StrictMode ./build.ps1 sets.
    $script:adkWim = ''
    try {
        $script:adkWim = [string] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)
    } catch {
        $script:adkWim = ''
    }

    $script:canMount = (-not [string]::IsNullOrWhiteSpace($script:adkWim)) -and
        (Test-Path -LiteralPath $script:adkWim -PathType Leaf)

    # HDT's own image, when a previous BootImage.Integration run left one. It is
    # the image that actually matters - the ADK's is only its ancestor - so it is
    # asserted when it is there and named as absent when it is not.
    $script:builtWim = 'C:\HDTLab\scratch\bootimage\Share\Boot\HDTPE_x64.wim'
    $script:hasBuilt = Test-Path -LiteralPath $script:builtWim -PathType Leaf

    # Under C:\HDTLab\scratch, created here and removed here - one of the three
    # locations CLAUDE.md permits a delete.
    $script:mountRoot = 'C:\HDTLab\scratch\winpe-content'

    $script:HDTSystem32Content = {
        param([string] $ImagePath, [string] $MountPath)

        # Returns a hashtable of name -> bool for the four names this file cares
        # about, from one mount. Assigned before the try, because a value set
        # only inside one is a value the caller may not read.
        $found = @{}

        if (-not (Test-Path -LiteralPath $MountPath -PathType Container)) {
            New-Item -Path $MountPath -ItemType Directory -Force | Out-Null
        }

        try {
            Mount-WindowsImage -ImagePath $ImagePath -Index 1 -Path $MountPath -ReadOnly -ErrorAction Stop | Out-Null

            $system32 = Join-Path -Path $MountPath -ChildPath 'Windows\System32'

            foreach ($name in @('wpeutil.exe', 'wpeinit.exe', 'shutdown.exe', 'reagentc.exe')) {
                $found[$name] = Test-Path -LiteralPath (Join-Path -Path $system32 -ChildPath $name) -PathType Leaf
            }
        } finally {
            Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -LiteralPath $MountPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        return $found
    }

    $script:adkContent = @{}
    $script:builtContent = @{}

    if ($script:canMount) {
        $script:adkContent = & $script:HDTSystem32Content $script:adkWim (Join-Path -Path $script:mountRoot -ChildPath 'adk')

        if ($script:hasBuilt) {
            $script:builtContent = & $script:HDTSystem32Content $script:builtWim (Join-Path -Path $script:mountRoot -ChildPath 'hdt')
        }
    }
}

AfterAll {
    # Nothing should be mounted, and a leftover mount folder would be a mount
    # that never came back. Runs on failure too.
    if (Test-Path -LiteralPath 'C:\HDTLab\scratch\winpe-content') {
        Remove-Item -LiteralPath 'C:\HDTLab\scratch\winpe-content' -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'what WinPE actually ships, and what it does not' -Tag 'Integration' -Skip:$skipWinPeContent {

    Context 'the ADK base image' {

        It 'mounted and was read' {
            # THE ANTI-VACUITY GUARD, FIRST. Four names were looked for; a mount
            # that failed yields none, and every "absent" below would then be
            # true for the wrong reason.
            @($script:adkContent.Keys).Count | Should -Be 4 -Because 'a run that read nothing proves nothing about what is or is not in the image'
        }

        It 'ships wpeutil.exe' {
            $script:adkContent['wpeutil.exe'] | Should -BeTrue
        }

        It 'ships wpeinit.exe' {
            # Named because startnet.cmd runs it before the payload (SPIKES
            # S11.3), and because it is a second known-present control.
            $script:adkContent['wpeinit.exe'] | Should -BeTrue
        }

        It 'DOES NOT ship shutdown.exe' {
            # THE ASSERTION THIS FILE EXISTS FOR, and the answer to ROADMAP M2's
            # question. Not "shutdown.exe behaves differently in WinPE" - it is
            # not there.
            $script:adkContent['shutdown.exe'] | Should -BeFalse -Because 'ROADMAP M2 asked whether WinPE needs wpeutil rather than shutdown.exe, and the reason it does is that shutdown.exe is absent'
        }
    }

    Context "HDT's own boot image" {

        It 'was built by a previous run and could be read' -Skip:$skipBuilt {
            @($script:builtContent.Keys).Count | Should -Be 4
        }

        It 'ships wpeutil.exe' -Skip:$skipBuilt {
            $script:builtContent['wpeutil.exe'] | Should -BeTrue
        }

        It 'DOES NOT ship shutdown.exe either' -Skip:$skipBuilt {
            # Update-HDTBootImage adds optional components and stages files; it
            # removes nothing and it adds no OC that carries shutdown.exe. This
            # is the image a machine actually boots, so it is the one the claim
            # has to hold for.
            $script:builtContent['shutdown.exe'] | Should -BeFalse
        }
    }

    Context 'the engine agrees with the image' {

        It 'names a command WinPE has, for WinPE' {
            # THE LOOP CLOSED. The decision is asserted against the same mount
            # that produced the fact, rather than against a comment quoting it.
            foreach ($operation in @('Restart', 'Stop')) {
                $plan = InModuleScope Hephaestus -Parameters @{ Operation = $operation } {
                    param($Operation)
                    Get-HDTPowerCommand -Environment WinPE -Operation $Operation -DelaySecond 0
                }

                $script:adkContent[[string] $plan.Command] |
                    Should -BeTrue -Because ("{0} in WinPE runs '{1}', which has to be in the image" -f $operation, $plan.Command)
            }
        }

        It 'names a command WinPE does not have, for the full OS' {
            # And the converse: the FullOS plan must NOT be runnable in WinPE, or
            # the distinction this plan drew would be decoration.
            foreach ($operation in @('Restart', 'Stop')) {
                $plan = InModuleScope Hephaestus -Parameters @{ Operation = $operation } {
                    param($Operation)
                    Get-HDTPowerCommand -Environment FullOS -Operation $Operation -DelaySecond 0
                }

                $script:adkContent[[string] $plan.Command] |
                    Should -BeFalse -Because ("{0} in the full OS runs '{1}', and the whole point is that WinPE has no such file" -f $operation, $plan.Command)
            }
        }
    }

    Context 'nothing was left mounted' {

        It 'has no mounted image belonging to this file' {
            @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
                    Where-Object { ([string] $_.Path) -like 'C:\HDTLab\scratch\winpe-content*' }) |
                Should -BeNullOrEmpty
        }
    }
}
