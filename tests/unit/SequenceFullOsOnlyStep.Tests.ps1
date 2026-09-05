# DESIGN 10.1: "WUA is unavailable in WinPE; this step is full-OS only and
# validation rejects it elsewhere."
#
# THE REFUSAL WALKS A SET, WHICH IS WHY THERE ARE TWO FUNCTIONS AND NOT AN `if`
# (CLAUDE.md 8). A test asserting "WindowsUpdate is refused" passes for
# WindowsUpdate and fails nobody after it; a test that walks
# Get-HDTFullOsOnlyStepType covers the type somebody adds next year without
# knowing this file exists. Get-HDTResumeForbiddenStepType is the same pattern,
# already built, and this is deliberately shaped like it.
#
# AND THE REFUSAL LIVES IN THE FLATTENER, NOT IN THE VALIDATOR. The validator
# sees the RAW document, where a step inheriting a group's runIn declares none
# of its own - so a refusal there would miss the WinPE-GROUP case entirely,
# which is the case DESIGN 10.1 is actually about.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:sequencePath = 'C:\HDTLab\does-not-exist\sequence.yaml'

    $script:import = {
        param([string] $Yaml)

        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\does-not-exist\sequence.yaml' = $Yaml }

        return (Import-HDTSequenceDocument -Path 'C:\HDTLab\does-not-exist\sequence.yaml' -FileSystem $fs)
    }

    $script:importError = {
        param([string] $Yaml)

        $record = $null
        try { $null = & $script:import $Yaml } catch { $record = $_ }

        return $record
    }
}

Describe 'Get-HDTFullOsOnlyStepType' {

    It 'names WindowsUpdate, whose COM server is not in a WinPE image at all' {
        InModuleScope Hephaestus {
            Get-HDTFullOsOnlyStepType | Should -Contain 'WindowsUpdate'
        }
    }

    It 'is a list in one place, so a test can walk it' {
        $set = @(InModuleScope Hephaestus { Get-HDTFullOsOnlyStepType })

        $set.Count | Should -BeGreaterThan 0
        foreach ($type in $set) { $type | Should -BeOfType ([string]) }
    }

    # A set that grew to hold every step that happens to be full-OS would stop
    # being a set and become a policy. These two run in WinPE and must never be
    # refused there.
    It 'does not name a step type WinPE runs' {
        $set = @(InModuleScope Hephaestus { Get-HDTFullOsOnlyStepType })

        $set | Should -Not -Contain 'ApplyImage'
        $set | Should -Not -Contain 'DiskPartition'
    }

    # DELIBERATELY ABSENT, and the help says why: their templates already write
    # runIn: FullOS and the engine skips a step whose phase does not match, so
    # an author who writes runIn: WinPE on one gets a message from the step
    # itself that explains the problem.
    It 'does not name InstallRoles, EnableBitLocker or JoinDomain' {
        $set = @(InModuleScope Hephaestus { Get-HDTFullOsOnlyStepType })

        $set | Should -Not -Contain 'InstallRoles'
        $set | Should -Not -Contain 'EnableBitLocker'
        $set | Should -Not -Contain 'JoinDomain'
    }
}

Describe 'Test-HDTStepPhaseForbidden' {

    It 'forbids a full-OS-only type whose runIn is WinPE' {
        InModuleScope Hephaestus {
            Test-HDTStepPhaseForbidden -Type 'WindowsUpdate' -RunIn 'WinPE' | Should -BeTrue
        }
    }

    It 'allows a full-OS-only type whose runIn is FullOS' {
        InModuleScope Hephaestus {
            Test-HDTStepPhaseForbidden -Type 'WindowsUpdate' -RunIn 'FullOS' | Should -BeFalse
        }
    }

    # Any means "wherever it lands", and the engine skips it in WinPE anyway
    # through Test-HDTStepRunInPhase. Only an explicit WinPE is a statement the
    # author got wrong.
    It 'allows a full-OS-only type whose runIn is Any' {
        InModuleScope Hephaestus {
            Test-HDTStepPhaseForbidden -Type 'WindowsUpdate' -RunIn 'Any' | Should -BeFalse
        }
    }

    It 'allows a full-OS-only type that declares no runIn' {
        InModuleScope Hephaestus {
            Test-HDTStepPhaseForbidden -Type 'WindowsUpdate' -RunIn '' | Should -BeFalse
            Test-HDTStepPhaseForbidden -Type 'WindowsUpdate' -RunIn $null | Should -BeFalse
        }
    }

    It 'allows every other type in WinPE' {
        InModuleScope Hephaestus {
            Test-HDTStepPhaseForbidden -Type 'ApplyImage' -RunIn 'WinPE' | Should -BeFalse
            Test-HDTStepPhaseForbidden -Type 'DiskPartition' -RunIn 'WinPE' | Should -BeFalse
            Test-HDTStepPhaseForbidden -Type 'NoOp' -RunIn 'WinPE' | Should -BeFalse
        }
    }

    It 'compares the type case-insensitively' {
        InModuleScope Hephaestus {
            Test-HDTStepPhaseForbidden -Type 'windowsupdate' -RunIn 'WinPE' | Should -BeTrue
        }
    }

    It 'compares the phase case-insensitively' {
        InModuleScope Hephaestus {
            Test-HDTStepPhaseForbidden -Type 'WindowsUpdate' -RunIn 'winpe' | Should -BeTrue
        }
    }
}

Describe 'Import-HDTSequenceDocument, full-OS-only steps' {

    BeforeAll {
        $script:ownRunIn = @'
schemaVersion: 1
id: WU-OWN
name: A WindowsUpdate step that says WinPE itself
steps:
  - name: Patch the machine
    type: WindowsUpdate
    runIn: WinPE
    maxPasses: 3
'@

        $script:groupRunIn = @'
schemaVersion: 1
id: WU-GROUP
name: A WindowsUpdate step inside a WinPE group
steps:
  - group: Preinstall
    runIn: WinPE
    steps:
      - name: Patch the machine
        type: WindowsUpdate
        maxPasses: 3
'@

        $script:fullOsGroup = @'
schemaVersion: 1
id: WU-FULLOS
name: A WindowsUpdate step inside a FullOS group
steps:
  - group: State Restore
    runIn: FullOS
    steps:
      - name: Patch the machine
        type: WindowsUpdate
        maxPasses: 3
'@

        $script:noRunIn = @'
schemaVersion: 1
id: WU-NONE
name: A WindowsUpdate step that declares no runIn anywhere
steps:
  - name: Patch the machine
    type: WindowsUpdate
'@
    }

    It 'refuses a WindowsUpdate step whose own runIn is WinPE' {
        $record = & $script:importError $script:ownRunIn

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        $record.TargetObject | Should -BeExactly $script:sequencePath
    }

    # THE CASE DESIGN 10.1 IS ACTUALLY ABOUT, and the one a validator running
    # over the raw document cannot see: the step declares no runIn of its own.
    It 'refuses a WindowsUpdate step inside a group whose runIn is WinPE' {
        $record = & $script:importError $script:groupRunIn

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
    }

    It 'refuses it naming the step, its type and the phase it was put in' {
        $record = & $script:importError $script:groupRunIn
        $message = [string] $record.Exception.Message

        $message | Should -BeLike '*Patch the machine*'
        $message | Should -BeLike '*WindowsUpdate*'
        $message | Should -BeLike '*WinPE*'
    }

    It 'names the reason, which is that the Windows Update Agent does not exist in WinPE' {
        $record = & $script:importError $script:groupRunIn
        $message = [string] $record.Exception.Message

        $message | Should -BeLike '*Microsoft.Update.Session*'
        $message | Should -BeLike '*FullOS*'
    }

    # DESIGN says it twice because the two names are close enough to reach for
    # the wrong one: offline .msu injection in WinPE is ApplyUpdates (DESIGN
    # 7.5), and an author who got here needs to be told which one is right.
    It 'names ApplyUpdates, which is the step that does patch in WinPE' {
        $record = & $script:importError $script:groupRunIn

        [string] $record.Exception.Message | Should -BeLike '*ApplyUpdates*'
    }

    It 'accepts a WindowsUpdate step in a FullOS group' {
        $sequence = & $script:import $script:fullOsGroup

        @($sequence.Step).Count | Should -Be 1
        $sequence.Step[0].RunIn | Should -Be 'FullOS'
    }

    It 'accepts a WindowsUpdate step that declares no runIn anywhere' {
        $sequence = & $script:import $script:noRunIn

        @($sequence.Step).Count | Should -Be 1
        $sequence.Step[0].RunIn | Should -Be 'Any'
    }

    # THE RULE-8 ASSERTION, and the reason for the two-function split. A
    # refusal that named the type here would cover WindowsUpdate and nothing
    # after it.
    It 'walks the set rather than naming the type in the importer' {
        $path = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Import-HDTSequenceDocument.ps1'
        $text = [System.IO.File]::ReadAllText($path)

        $text | Should -Not -BeLike '*WindowsUpdate*'
        $text | Should -BeLike '*Test-HDTStepPhaseForbidden*'
    }

    # Every type in the set is refused, so a type added to the list later is
    # covered by construction rather than by somebody remembering this file.
    It 'refuses every type the set names, not only the one that prompted it' {
        $set = @(InModuleScope Hephaestus { Get-HDTFullOsOnlyStepType })

        foreach ($type in $set) {
            $yaml = @"
schemaVersion: 1
id: WU-SET
name: One step of each forbidden type in a WinPE group
steps:
  - group: Preinstall
    runIn: WinPE
    steps:
      - name: A $type step
        type: $type
"@

            $record = & $script:importError $yaml

            $record | Should -Not -BeNullOrEmpty
            [string] $record.Exception.Message | Should -BeLike ('*{0}*' -f $type)
        }
    }
}
