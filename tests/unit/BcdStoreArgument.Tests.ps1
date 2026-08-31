# THE /store PREFIX, IN ONE PLACE, BECAUSE TWO CALLERS NOW NEED IT.
#
# Get-HDTBcdCommand composes the transport's ten commands and the adapter's
# TestRamdiskOptions probe composes an eleventh, and both have to make the same
# decision: an empty store means the system store, which bcdedit selects by
# taking no /store argument at all. Spelling that twice is how the probe ends up
# reading a different store from the one the create writes to - the exact
# question SPIKES S23.7 could not answer without a machine.
#
# It is also what keeps New-HDTImageService branch-free (CLAUDE.md rule 1): the
# adapter concatenates what this returns rather than deciding anything.
#
# It is private, so every call runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:prefix = {
        param([string] $Store)

        $result = InModuleScope Hephaestus -Parameters @{ Store = $Store } {
            param($Store)
            Get-HDTBcdStoreArgument -Store $Store
        }

        # NO UNARY COMMA. Everywhere else in these suites the comma stops a
        # one-element array collapsing on the way out of InModuleScope; here it
        # would hand the caller ONE object that happens to be an array, and
        # @(...) around it counts 1 for both the empty prefix and the two-element
        # one. What is under test is exactly how many arguments reach bcdedit.
        return [string[]] @($result)
    }
}

Describe 'Get-HDTBcdStoreArgument' {

    It 'names the store when one is given' {
        $argument = & $script:prefix 'S:\EFI\Microsoft\Boot\BCD'

        ($argument -join ' ') | Should -BeExactly '/store S:\EFI\Microsoft\Boot\BCD'
    }

    # EMPTY IS NOT A MISSING VALUE, IT IS THE SYSTEM STORE. In the full OS the
    # machine booted through the store bcdedit already targets and the EFI System
    # Partition has no drive letter to name one with, so the right command line
    # is the one with no /store on it at all.
    # @(...) AROUND THE CALL, NOT .Count ON IT. The empty case returns nothing at
    # all, so the call site sees $null - and $null.Count is $null under Windows
    # PowerShell and a THROW under Set-StrictMode -Version Latest, which the gate
    # sets and a direct Invoke-Pester run does not. Both spellings of this
    # assertion passed here and failed the gate; the gate was right.
    It 'returns nothing at all for the system store' {
        @(& $script:prefix '').Count | Should -Be 0
    }

    It 'treats whitespace as the system store rather than as a path' {
        @(& $script:prefix '   ').Count | Should -Be 0
    }

    # A UNARY COMMA HERE WOULD WRAP RATHER THAN PROTECT, and the empty case is
    # where that shows: an array containing an empty array becomes a single
    # empty string once the caller casts it to [string[]], and every bcdedit
    # command line then starts with a stray argument. Both callers wrap the
    # result in @() themselves, so there is nothing to protect.
    It 'contributes no argument at all for the system store, not an empty one' {
        $argument = [string[]] @(& $script:prefix '')

        $argument.Count | Should -Be 0
        ($argument -join ' ') | Should -BeExactly ''
    }

    It 'contributes exactly two arguments for a named store' {
        $argument = [string[]] @(& $script:prefix 'C:\BCD')

        $argument.Count | Should -Be 2
        $argument[0] | Should -BeExactly '/store'
        $argument[1] | Should -BeExactly 'C:\BCD'
    }
}
