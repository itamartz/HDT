# EVERY SLOW SUITE GIVES BACK THE SCRATCH IT TAKES - as a contract, over the
# SET, because the individual AfterAll blocks are only today's instance.
#
# WHAT HAPPENED. tests/e2e has four files. Each builds its own boot image into
# its own root under C:\HDTLab\scratch - roughly a gigabyte a run, two for the
# ones that stage a full WinPE plus an ISO - and not one of them ever removed
# it. C:\HDTLab\scratch reached 7.1 GB, of which 5 GB was dead build roots from
# runs three weeks apart, and the only folder still in use was the one nothing
# in tests/e2e touches.
#
# WHY THE SCAN AND NOT FOUR ASSERTIONS. A test that names e2e-bootimage passes
# for e2e-bootimage and fails nobody after it. The fifth E2E file, written next
# month, would leak exactly the same way and every test here would stay green.
# So this drives off the set of tests/e2e/*.ps1 and requires, of every scratch
# root a file names, either a removal in that file or a place on the KEEP list
# below - which is short, argued, and in one reviewed place rather than in the
# suite that wants the exemption.
#
# THE KEEP LIST IS NOT AN ESCAPE HATCH, it is the diagnosis. The E2E artifact
# roots hold the screenshots, RESULT.json, HDT.jsonl and state.json copied off a
# content disk that the AfterAll then destroys; tests/e2e/README.md is a table
# telling a human which of those files to open when a run fails. Deleting them
# at the end of every run would leave every future E2E failure undiagnosable.
# They are also BOUNDED - each run overwrites the same filenames, and the four
# of them together came to about 6 MB against 5 GB of build roots.
#
# C:\HDTLab\scratch\bootimage IS ON NEITHER LIST, deliberately, and the last
# assertion here says so by name. It is the user's live build scratch: bounded
# already because Update-HDTBootImage empties it at the start of every run, and
# read afterwards by 25 tests that answer "what actually went into my image?".

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # Built in the RUN phase, not BeforeDiscovery (SPIKES S9.15).
    $script:e2eFile = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/e2e') -Filter '*.ps1' -File |
            ForEach-Object { $_.FullName }
    )

    # The evidence roots. Kept on purpose; see the header.
    $script:keepRoot = @(
        'C:\HDTLab\scratch\e2e'                  # M3 deployment + WinPE smoke screenshots, PROBE.json, DISK-BEFORE.json
        'C:\HDTLab\scratch\e2e-m4'               # M4 RESULT.json, HDT.jsonl, state.json, LAUNCHER.log, m4-*.png
        'C:\HDTLab\scratch\wizard-e2e-artifacts' # W2 wizard screenshots and WIZARDPROBE-*.json
        'C:\HDTLab\scratch\e2e-m7'               # M7 capture proof: HDT.jsonl and m7-*.png
        'C:\HDTLab\scratch\e2e-refdeploy'        # M7 captured-image deployment: HDT.jsonl, DEPLOYED-MARKER.txt, refdeploy-*.png
        'C:\HDTLab\scratch\e2e-refapp'           # M7 application round trip, leg 1: HDT.jsonl and refapp-*.png
        'C:\HDTLab\scratch\e2e-refdep'           # M7 application round trip, leg 2: HDT.jsonl and refdep-*.png
    )
}

Describe 'no E2E suite leaks a scratch directory' {

    It 'finds the E2E suites to judge' {
        # A contract that scans nothing passes for the wrong reason
        # (tests/helpers/README.md section 12), and @($null).Count is 1, so a
        # count alone proves nothing. These names must be in the set.
        @($script:e2eFile).Count | Should -BeGreaterThan 3

        $name = @($script:e2eFile | ForEach-Object { Split-Path -Leaf $_ })
        $name | Should -Contain 'Deployment.E2E.Tests.ps1'
        $name | Should -Contain 'UnattendedDeployment.E2E.Tests.ps1'
        $name | Should -Contain 'WinPeSmoke.E2E.Tests.ps1'
        $name | Should -Contain 'Wizard.E2E.Tests.ps1'
    }

    It 'sees the scratch roots those suites build into' {
        # The scanner has to be shown to FIND things, or "no violations" could
        # mean "read nothing". Every build root below is named by a suite.
        $root = @(Get-HDTScratchRootReference -Path $script:e2eFile | ForEach-Object { $_.Root })

        $root | Should -Contain 'C:\HDTLab\scratch\e2e-m3-bootimage'
        $root | Should -Contain 'C:\HDTLab\scratch\e2e-bootimage'
        $root | Should -Contain 'C:\HDTLab\scratch\e2e-probeimage'
        $root | Should -Contain 'C:\HDTLab\scratch\wizard-e2e'
    }

    It 'reports no leak across tests/e2e' {
        $violation = @(Get-HDTScratchLeakViolation -Path $script:e2eFile -Keep $script:keepRoot)

        $detail = ($violation | ForEach-Object { '{0}: {1}' -f (Split-Path -Leaf $_.Path), $_.Root }) -join "`n"

        $violation.Count | Should -Be 0 -Because (
            "every scratch root a suite names must be removed by that suite's teardown, " +
            "or listed in this file's KEEP list with a reason. A gigabyte a run adds up:`n" + $detail)
    }

    It 'still bites on the deliberate fixture' {
        # The assertion above passes for a repository with no E2E suites at all,
        # so the scanner is pointed at a file that is known to leak.
        $bait = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/scratchleak/LeakingSuite.ps1'

        $violation = @(Get-HDTScratchLeakViolation -Path $bait)

        # On the root it names, not on a count: @($null).Count is 1.
        @($violation | ForEach-Object { $_.Root }) | Should -Contain 'C:\HDTLab\scratch\bait-leak'
    }

    It 'does not accept a removal of some other directory as cover' {
        # The shape that would otherwise slip through: a teardown that removes
        # SOMETHING under scratch, so the file contains a call, while the root it
        # actually filled goes on standing.
        $bait = Join-Path -Path $TestDrive -ChildPath 'wrongtarget.ps1'
        Set-Content -LiteralPath $bait -Encoding UTF8 -Value @(
            '$script:buildRoot = ''C:\HDTLab\scratch\bait-built'''
            'AfterAll { Remove-HDTLabScratchTree -Path ''C:\HDTLab\scratch\bait-other'' -Confirm:$false }'
        )

        @(Get-HDTScratchLeakViolation -Path $bait | ForEach-Object { $_.Root }) |
            Should -Contain 'C:\HDTLab\scratch\bait-built'
    }

    It 'accepts a suite that removes what it built' {
        $ok = Join-Path -Path $TestDrive -ChildPath 'tidy.ps1'
        Set-Content -LiteralPath $ok -Encoding UTF8 -Value @(
            '$script:buildRoot = ''C:\HDTLab\scratch\bait-built'''
            'AfterAll { Remove-HDTLabScratchTree -Path ''C:\HDTLab\scratch\bait-built'' -Confirm:$false }'
        )

        @(Get-HDTScratchLeakViolation -Path $ok).Count | Should -Be 0
    }
}

Describe 'the live build scratch is never a teardown target' {

    It 'is not on the keep list, because it is not a suite artifact' {
        $script:keepRoot | Should -Not -Contain 'C:\HDTLab\scratch\bootimage'
    }

    It 'is removed by no slow suite' {
        # By name, and over BOTH slow suites: tests/integration builds into
        # C:\HDTLab\scratch\bootimage on purpose and reads its mount\ tree
        # afterwards. Whoever adds a tidy-up there next must not reach for it.
        $slowFile = @(
            foreach ($suite in @('tests/e2e', 'tests/integration')) {
                $path = Join-Path -Path $script:repoRoot -ChildPath $suite
                if (Test-Path -LiteralPath $path -PathType Container) {
                    Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File -Recurse |
                        ForEach-Object { $_.FullName }
                }
            }
        )

        $removed = @(Get-HDTScratchRootReference -Path $slowFile |
                Where-Object { $_.Removed } |
                ForEach-Object { $_.Root })

        $removed | Should -Not -Contain 'C:\HDTLab\scratch\bootimage'
    }

    It 'is refused by the teardown helper itself' {
        { Remove-HDTLabScratchTree -Path 'C:\HDTLab\scratch\bootimage' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*bootimage*'
    }
}

Describe 'each E2E suite removes the build root it created' {

    # Today's instance of the rule above, named, so a failure says which file.
    It '<Suite> removes <Root>' -ForEach @(
        @{ Suite = 'Deployment.E2E.Tests.ps1'; Root = 'C:\HDTLab\scratch\e2e-m3-bootimage' }
        @{ Suite = 'UnattendedDeployment.E2E.Tests.ps1'; Root = 'C:\HDTLab\scratch\e2e-bootimage' }
        @{ Suite = 'WinPeSmoke.E2E.Tests.ps1'; Root = 'C:\HDTLab\scratch\e2e-probeimage' }
        @{ Suite = 'Wizard.E2E.Tests.ps1'; Root = 'C:\HDTLab\scratch\wizard-e2e' }
    ) {
        $file = Join-Path -Path $script:repoRoot -ChildPath ('tests/e2e/{0}' -f $Suite)

        @(Get-HDTScratchRootReference -Path $file |
                Where-Object { $_.Removed } |
                ForEach-Object { $_.Root }) | Should -Contain $Root
    }
}
