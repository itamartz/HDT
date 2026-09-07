# NO E2E SUITE MAY DEMAND A NON-EMPTY PROTECTED VM SET.
#
# Four suites guarded their lab-safety comparison by asserting that the set of
# VMs outside HDT-* was non-empty. The intent was sound - comparing an empty
# snapshot with an empty snapshot passes while checking nothing (SPIKES S9.14,
# six green runs) - but the assertion cannot tell
#
#   (a) Hyper-V could not be read, so the snapshot is meaningless
#
# from
#
#   (b) Hyper-V was read fine and this host has no VM outside HDT-*
#
# and (b) is the NORMAL state of a dedicated CI runner. On 2026-09-07 the E2E
# workflow on GHRUNNER01 failed four assertions for being exactly what a runner
# is supposed to be, and every future run there would have failed the same way.
#
# WHY A CONTRACT AND NOT FOUR FIXES. The fix was applied in four places, which
# means the fifth E2E suite - written next month, by somebody copying the fourth -
# reintroduces it and every test here stays green. So this drives off the set of
# tests/e2e/*.ps1 and fails on the PATTERN rather than on a file name.
#
# WHAT IT DOES NOT FORBID. Comparing the snapshots is the whole point and stays.
# Asserting Readable is the replacement and is required. It is the COUNT of the
# protected set that may not be a pass condition.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # Built in the RUN phase, not BeforeDiscovery (SPIKES S9.15).
    $script:e2eFile = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'tests/e2e') -Filter '*.ps1' -File |
            ForEach-Object { $_.FullName }
    )

    # The shapes that mean "the protected snapshot must not be empty". Matched
    # on the VARIABLE being counted rather than on a whole line, so reformatting
    # does not slip past.
    $script:banned = @(
        '@\(\$script:protectedBefore\)\.Count\s*\|\s*Should\s+-BeGreaterThan\s+0'
        '@\(\$script:vmBefore\)\.Count\s*\|\s*Should\s+-BeGreaterThan\s+0'
        '\(Get-HDTLabProtectedVm\)\.Protected\.Count\s*\|\s*Should\s+-BeGreaterThan\s+0'

        # THE VARIANT THIS CONTRACT MISSED THE FIRST TIME, and it is here
        # because missing it cost a second red CI run. One suite had already
        # spotted that demanding a non-empty PROTECTED set can never pass on a
        # host with no VM outside HDT-*, and moved its guard to the UNFILTERED
        # count instead. That is closer but still wrong: a total of zero is
        # legitimate on a dedicated runner, whose only VMs are the ones the
        # suite makes and which it tears down before this assertion runs.
        #
        # Readable is the only form that distinguishes "Get-VM threw" from
        # "Get-VM returned nothing", so a COUNT of any Hyper-V read is banned
        # as a pass condition, not just a count of the protected subset.
        '@\(Hyper-V\\Get-VM[^)]*\)\.Count\s*\|\s*Should\s+-BeGreaterThan\s+0'
    )
}

Describe 'no E2E suite requires a non-empty protected VM set' {

    It 'finds the E2E suites to judge' {
        # A contract that scans nothing passes for the wrong reason.
        @($script:e2eFile).Count | Should -BeGreaterThan 3

        $name = @($script:e2eFile | ForEach-Object { Split-Path -Leaf $_ })
        $name | Should -Contain 'Deployment.E2E.Tests.ps1'
        $name | Should -Contain 'ReferenceCapture.E2E.Tests.ps1'
        $name | Should -Contain 'UnattendedDeployment.E2E.Tests.ps1'
        $name | Should -Contain 'WindowsUpdate.E2E.Tests.ps1'
    }

    It 'no suite asserts the protected set is non-empty' {
        $violation = @()

        foreach ($file in $script:e2eFile) {
            $text = [System.IO.File]::ReadAllText($file)

            foreach ($pattern in $script:banned) {
                if ($text -match $pattern) {
                    $violation += ('{0}: {1}' -f (Split-Path -Leaf $file), $pattern)
                }
            }
        }

        $violation.Count | Should -Be 0 -Because (
            "a dedicated CI runner legitimately has no VM outside HDT-*, so this " +
            "assertion fails on a healthy host. Assert (Get-HDTLabProtectedVm).Readable " +
            "instead - it answers 'was the snapshot taken' rather than 'did it have " +
            "rows'.`n" + ($violation -join "`n"))
    }

    It 'every suite that compares snapshots also asserts Hyper-V was readable' {
        # THE OTHER HALF. Dropping the count guard without putting Readable in
        # its place would leave exactly the vacuous comparison the count guard
        # was invented to prevent.
        $missing = @()

        foreach ($file in $script:e2eFile) {
            $text = [System.IO.File]::ReadAllText($file)

            # Only suites that actually compare a before/after snapshot.
            if ($text -notmatch 'protectedBefore|vmBefore') { continue }

            if ($text -notmatch '\(Get-HDTLabProtectedVm\)\.Readable') {
                $missing += (Split-Path -Leaf $file)
            }
        }

        $missing.Count | Should -Be 0 -Because (
            "these suites compare a protected-VM snapshot without first proving " +
            "the snapshot could be taken: " + ($missing -join ', '))
    }

    It 'the helper reports readability separately from content' {
        # The contract above is only worth anything if the command it points
        # people at actually makes the distinction.
        $answer = Get-HDTLabProtectedVm

        $answer.PSObject.Properties['Readable'] | Should -Not -BeNullOrEmpty
        $answer.PSObject.Properties['Protected'] | Should -Not -BeNullOrEmpty
    }
}
