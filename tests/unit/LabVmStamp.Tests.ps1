# THE STAMP, WHICH IS HOW THE HARNESS TELLS ITS OWN VMs FROM THE LAB'S.
#
# CLAUDE.md is explicit that the protected set is a prefix and not a list of
# names: "a name list rots, and this one did." The lab now runs infrastructure
# VMs that match HDT-* and that this repository did not build, so the budget and
# the teardown helper need to know which VMs are theirs WITHOUT anybody
# remembering to write a name down.
#
# The answer is that New-HDTLabVirtualMachine records what it did, at the moment
# it did it, in the VM's own Notes field. Membership is then a fact about the VM
# rather than a fact somebody maintained.
#
# Every assertion here is pure - no Hyper-V, no VM, no host state.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTLabVmStamp' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'Get-HDTLabVmStamp' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'returns a marker that names this repository as the creator' {
        # It has two jobs and the string does both: it tells the harness which
        # VMs are its own, and it tells a human reading Hyper-V Manager that the
        # machine is disposable. A UUID would do the first and not the second.
        $stamp = Get-HDTLabVmStamp

        $stamp | Should -BeOfType ([string])
        $stamp | Should -BeLike '*HDTTestTools*'
        $stamp | Should -BeLike '*disposable*'
    }

    It 'returns the same marker every call' {
        # If it varied, a VM stamped yesterday would drop out of the budget and
        # out of teardown today.
        (Get-HDTLabVmStamp) | Should -BeExactly (Get-HDTLabVmStamp)
    }

    It 'returns a marker no human would type into a Notes field by accident' {
        $stamp = Get-HDTLabVmStamp

        $stamp.Length | Should -BeGreaterThan 40
        $stamp | Should -BeLike '*tests/helpers/HDTTestTools*'
    }
}

Describe 'Test-HDTLabVmStamped' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'Test-HDTLabVmStamped' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'accepts a note that is exactly the stamp' {
        Test-HDTLabVmStamped -Note (Get-HDTLabVmStamp) | Should -BeTrue
    }

    It 'accepts a note that carries the stamp among other text' {
        # An operator adding a line to a VM's notes must not silently drop that
        # VM out of the budget, or - far worse - out of teardown.
        $note = "Rebuilt 2026-09-06 for the WSUS spike.`r`n{0}`r`nDo not snapshot." -f (Get-HDTLabVmStamp)

        Test-HDTLabVmStamped -Note $note | Should -BeTrue
    }

    It 'refuses an empty note' {
        # Which is what every VM on this host that the harness did not create
        # carries today.
        Test-HDTLabVmStamped -Note '' | Should -BeFalse
        Test-HDTLabVmStamped -Note '   ' | Should -BeFalse
    }

    It 'refuses a null note' {
        Test-HDTLabVmStamped -Note $null | Should -BeFalse
    }

    It 'refuses a note that does not carry the stamp' {
        foreach ($note in @('WSUS server', 'Created by hand', 'HDTTestTools', 'disposable')) {
            Test-HDTLabVmStamped -Note $note | Should -BeFalse -Because ("'{0}' is not the stamp" -f $note)
        }
    }
}
