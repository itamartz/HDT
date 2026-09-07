# THE SNAPSHOT THAT HAS TO TELL "NOTHING TO PROTECT" FROM "COULD NOT LOOK".
#
# Four E2E suites guarded their lab-safety comparison with "the protected set
# must not be empty", because comparing an empty snapshot with an empty snapshot
# passes while checking nothing (SPIKES S9.14, six green runs). The danger is
# real; the guard answered it with the wrong question, and on 2026-09-07 the E2E
# workflow on GHRUNNER01 failed four assertions for being a dedicated runner -
# a host whose only VMs are the ones the suite creates, which is what a CI
# runner IS.
#
# So the readable/empty distinction is the behaviour under test here, and it is
# asserted through the module boundary rather than by reading the source.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTLabProtectedVm' {

    Context 'the shape it always returns' {

        It 'is exported by the helper module' {
            # A helper four suites call has to BE there; a dot-sourced copy in
            # one of them is how the next divergence starts.
            Get-Command -Name 'Get-HDTLabProtectedVm' -Module 'HDTTestTools' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'reports Readable, Total, Protected and Error whatever the host is' {
            $answer = Get-HDTLabProtectedVm

            foreach ($name in 'Readable', 'Total', 'Protected', 'Error') {
                $answer.PSObject.Properties[$name] | Should -Not -BeNullOrEmpty -Because "a caller reads .$name unconditionally"
            }
        }

        It 'takes no parameters, so no suite can narrow the set it is judged against' {
            # THE UNFILTERED READ IS THE POINT. A -Name or -Exclude here would
            # let a suite quietly stop watching the VM it was about to break.
            @((Get-Command -Name 'Get-HDTLabProtectedVm').Parameters.Keys |
                    Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters }) |
                Should -BeNullOrEmpty
        }
    }

    Context 'on this host, which has Hyper-V' -Skip:(-not (Get-Module -ListAvailable -Name Hyper-V)) {

        It 'reports Hyper-V as readable' {
            (Get-HDTLabProtectedVm).Readable | Should -BeTrue
        }

        It 'reports no error when it could read' {
            (Get-HDTLabProtectedVm).Error | Should -BeNullOrEmpty
        }

        It 'counts every VM in Total, including the HDT-* ones Protected leaves out' {
            $answer = Get-HDTLabProtectedVm

            # Total is the unfiltered count; Protected excludes HDT-*. So Total
            # is never smaller, and the difference is exactly the HDT-* VMs.
            $answer.Total | Should -BeGreaterOrEqual @($answer.Protected).Count
        }

        It 'excludes every HDT-* VM from Protected' {
            # THE ONE THE WHOLE GUARD RESTS ON. A protected set that included an
            # HDT-* VM would report a difference every time the suite created or
            # removed its own machine.
            # (Get-HDTLabProtectedVm).Protected, not @(...).Protected - wrapping
            # the RESULT in an array first asks the array for a property the
            # record has.
            @((Get-HDTLabProtectedVm).Protected |
                    Where-Object { [string] $_.Name -like 'HDT-*' }) |
                Should -BeNullOrEmpty
        }

        It 'is stable across two consecutive reads' {
            # The snapshot is compared before against after, so a snapshot that
            # varied on its own would report a difference nobody caused.
            $first = (Get-HDTLabProtectedVm).Protected | ConvertTo-Json -Depth 3
            $second = (Get-HDTLabProtectedVm).Protected | ConvertTo-Json -Depth 3

            $second | Should -BeExactly $first
        }
    }

    Context 'the empty-but-readable case, which is what CI actually is' {

        It 'does not treat an empty protected set as a failure to read' {
            # THE REGRESSION THIS FILE EXISTS FOR. GHRUNNER01 has no VM outside
            # HDT-*, and that is correct rather than broken. Readable answers
            # "was the snapshot taken"; Protected answers "what was in it". A
            # caller that conflates them fails on a healthy runner for ever.
            $answer = Get-HDTLabProtectedVm

            if (@($answer.Protected).Count -eq 0) {
                $answer.Readable | Should -BeTrue -Because 'an empty protected set on a readable host is a dedicated runner, not a fault'
            } else {
                Set-ItResult -Skipped -Because 'this host has VMs outside HDT-*, so the empty case cannot be observed here'
            }
        }
    }
}
