# Getting the ADK onto a machine, decided in a command and carried out by an
# adapter, so the decision is testable without a 1.5 GB download.
#
# THE DECISION IS NOT "HAVE WE GOT INTERNET". Three facts settle it - is the ADK
# already here, is a vetted offline payload staged, is there a route out - and
# the order matters. A site that is airgapped BY POLICY rather than by cable can
# reach the internet and still must install from the payload its change board
# approved, so the payload beats the connection whenever both are present.
#
# WHEN NOTHING IS AVAILABLE THE ANSWER IS INSTRUCTIONS, NOT AN EXCEPTION.
# An IT department that cannot reach go.microsoft.com needs the two links, the
# /layout command to run on a machine that can, and the folder to drop the
# result in. Failing with 'no internet' would leave them to search for all
# three, which is how an airgapped site ends up installing whatever ADK a
# forum post linked to.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:payload = 'C:\HDTPayload\ADK'

    # A staged payload is both installers side by side. Real captured names:
    # adksetup.exe is the ADK, adkwinpesetup.exe the Windows PE add-on.
    $script:fullPayload = {
        New-HDTFakeFileSystem -File @{
            'C:\HDTPayload\ADK\adksetup.exe'       = 'not really a binary'
            'C:\HDTPayload\ADK\adkwinpesetup.exe'  = 'not really a binary'
        }
    }

    $script:emptyPayload = { New-HDTFakeFileSystem -File @{} }
}

Describe 'Get-HDTAdkInstallPlan' {

    Context 'the ADK is already here' {

        It 'asks for nothing when the ADK already resolves' {
            $plan = Get-HDTAdkInstallPlan -AdkPresent $true -PayloadStaged $true -InternetAvailable $true `
                -PayloadPath $script:payload

            $plan.Action | Should -BeExactly 'AlreadyInstalled'
        }

        It 'says so even with no route out, because nothing needs fetching' {
            $plan = Get-HDTAdkInstallPlan -AdkPresent $true -PayloadStaged $false -InternetAvailable $false `
                -PayloadPath $script:payload

            $plan.Action | Should -BeExactly 'AlreadyInstalled'
        }
    }

    Context 'a staged offline payload' {

        It 'installs from the payload when both installers are staged' {
            $plan = Get-HDTAdkInstallPlan -AdkPresent $false -PayloadStaged $true -InternetAvailable $false `
                -PayloadPath $script:payload

            $plan.Action | Should -BeExactly 'InstallFromPayload'
            $plan.AdkSetupPath | Should -BeExactly 'C:\HDTPayload\ADK\adksetup.exe'
            $plan.WinPeSetupPath | Should -BeExactly 'C:\HDTPayload\ADK\adkwinpesetup.exe'
        }

        It 'prefers the staged payload over the internet' {
            # AIRGAPPED BY POLICY, NOT BY CABLE. The payload is the media the
            # change board approved; a machine that can also reach Microsoft
            # must not quietly install something else.
            $plan = Get-HDTAdkInstallPlan -AdkPresent $false -PayloadStaged $true -InternetAvailable $true `
                -PayloadPath $script:payload

            $plan.Action | Should -BeExactly 'InstallFromPayload'
        }

        It 'does not treat half a payload as a payload' {
            # The ADK without the Windows PE add-on builds no boot image, and
            # the failure would land much later, in Update-HDTBootImage. WHICH
            # FILES MAKE A PAYLOAD IS THE CMDLET'S QUESTION now that the planner
            # is handed the answer, so this asks the cmdlet.
            $half = New-HDTFakeFileSystem -File @{ 'C:\HDTPayload\ADK\adksetup.exe' = 'x' }
            $process = New-HDTFakeProcessService -Result @{}

            $answer = Install-HDTAdk -PayloadPath $script:payload -Force -ProbeInternet { $false } `
                -FileSystem $half -Process $process -Confirm:$false -WarningAction SilentlyContinue

            $answer.Action | Should -BeExactly 'Blocked'
            @($process.Operations).Count | Should -Be 0
        }
    }

    Context 'a machine that can reach Microsoft' {

        BeforeAll {
            $script:online = Get-HDTAdkInstallPlan -AdkPresent $false -PayloadStaged $false -InternetAvailable $true `
                -PayloadPath $script:payload
        }

        It 'downloads when there is a route out and nothing staged' {
            $script:online.Action | Should -BeExactly 'Download'
        }

        It 'carries both Microsoft links, because the add-on is a separate download' {
            $script:online.AdkUrl | Should -BeExactly 'https://go.microsoft.com/fwlink/?linkid=2289980'
            $script:online.WinPeUrl | Should -BeExactly 'https://go.microsoft.com/fwlink/?linkid=2289981'
        }

        It 'names the ADK version those links resolve to' {
            # Pinned, not "latest": 10.1.28000.1 is Arm64-only, so the newest
            # ADK is the wrong one for a lab deploying x64 Windows 11 and
            # Server 2025.
            $script:online.Version | Should -BeExactly '10.1.26100.2454'
        }
    }

    Context 'no ADK, no payload, no route out' {

        BeforeAll {
            $script:blocked = Get-HDTAdkInstallPlan -AdkPresent $false -PayloadStaged $false -InternetAvailable $false `
                -PayloadPath $script:payload
            $script:said = ($script:blocked.Instruction -join "`n")
        }

        It 'hands back instructions rather than an action it cannot take' {
            $script:blocked.Action | Should -BeExactly 'Blocked'
            @($script:blocked.Instruction).Count | Should -BeGreaterThan 0
        }

        It 'gives IT both download links' {
            $script:said | Should -Match ([regex]::Escape('linkid=2289980'))
            $script:said | Should -Match ([regex]::Escape('linkid=2289981'))
        }

        It 'gives the /layout command to run on a machine that has internet' {
            # This is the whole airgap mechanism and the part nobody remembers:
            # adksetup.exe downloads a full offline layout rather than being a
            # payload itself.
            $script:said | Should -Match '/layout'
        }

        It 'says where to put what comes back' {
            $script:said | Should -Match ([regex]::Escape($script:payload))
        }

        It 'names the patch, because the shipped ADK carries a known CVE' {
            # Microsoft flags KB5079391 against CVE-2026-25166 for this ADK. A
            # runbook that stops at "install the ADK" ships the vulnerable one.
            $script:said | Should -Match 'KB5079391'
            $script:said | Should -Match 'CVE-2026-25166'
        }
    }
}

Describe 'Install-HDTAdk' {

    BeforeAll {
        $script:seeded = @{
            'C:\HDTPayload\ADK\adksetup.exe /quiet /features OptionId.DeploymentTools'  = @{ ExitCode = 0 }
            'C:\HDTPayload\ADK\adkwinpesetup.exe /quiet'                                = @{ ExitCode = 0 }
        }
    }

    It 'runs both installers, the ADK before the add-on' {
        # ORDER IS NOT COSMETIC. The Windows PE add-on installs into the ADK's
        # own tree and its setup refuses when the ADK is not there yet.
        $process = New-HDTFakeProcessService -Result $script:seeded

        # -Force IS PASSED, ALWAYS. Without it the command probes the real
        # machine with Get-HDTAdkPath - so this test passed on a build agent
        # without the ADK and reported AlreadyInstalled on a developer's box
        # that had it.
        [void] (Install-HDTAdk -PayloadPath 'C:\HDTPayload\ADK' -Force `
                -FileSystem (& $script:fullPayload) -Process $process -Confirm:$false)

        @($process.Operations).Count | Should -Be 2
        # Arguments[0] is the file the fake was asked to start - the recording
        # shape every hand-written fake here shares (Sequence/Operation/Arguments).
        $process.Operations[0].Arguments[0] | Should -BeExactly 'C:\HDTPayload\ADK\adksetup.exe'
        $process.Operations[1].Arguments[0] | Should -BeExactly 'C:\HDTPayload\ADK\adkwinpesetup.exe'
    }

    It 'starts nothing under -WhatIf' {
        $process = New-HDTFakeProcessService -Result $script:seeded

        [void] (Install-HDTAdk -PayloadPath 'C:\HDTPayload\ADK' -Force `
                -FileSystem (& $script:fullPayload) -Process $process -WhatIf)

        @($process.Operations).Count | Should -Be 0
    }

    It 'starts nothing when it is blocked, and returns the instructions' {
        $process = New-HDTFakeProcessService -Result $script:seeded

        $answer = Install-HDTAdk -PayloadPath 'C:\HDTPayload\ADK' -Force -ProbeInternet { $false } `
            -FileSystem (& $script:emptyPayload) -Process $process -Confirm:$false -WarningAction SilentlyContinue

        @($process.Operations).Count | Should -Be 0
        $answer.Action | Should -BeExactly 'Blocked'
        ($answer.Instruction -join "`n") | Should -Match '/layout'
    }

    It 'does nothing at all when the ADK is already installed' {
        $process = New-HDTFakeProcessService -Result $script:seeded

        # THE PROBE IS STUBBED, NOT LEFT TO THE MACHINE. Reading the real
        # Get-HDTAdkPath here would pass on a developer box with the ADK and
        # install the payload on a build agent without it - the same
        # machine-dependence that -Force is passed to avoid everywhere else.
        $answer = Install-HDTAdk -PayloadPath 'C:\HDTPayload\ADK' -ProbeAdk { $true } `
            -FileSystem (& $script:fullPayload) -Process $process -Confirm:$false

        @($process.Operations).Count | Should -Be 0
        $answer.Action | Should -BeExactly 'AlreadyInstalled'
    }
}

}
