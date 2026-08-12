# The IEnvironmentProvider contract (PROJECT constraint 4, DESIGN 3.2.1,
# DESIGN 12.2.1).
#
# DESIGN 3.2.1 reads firmware_type and PROCESSOR_ARCHITECTURE from the
# environment. Constraint 4 says engine logic never touches $env: directly, so
# it arrives through this one-method interface and Get-HDTMachineFact can be
# proven on a BIOS machine, an ARM machine and a machine with neither variable
# set, from a desk with none of those.
#
# Every implementation must pass this file unchanged. Adding an implementation
# is a one-row change to $script:HDTImplementation below.
#
# The registry is built at discovery time, not in BeforeAll: Pester 5 expands
# -ForEach while discovering, so a BeforeAll would produce zero test cases.

# The skip goes on a Context INSIDE the Describe, never on the Describe itself:
# -Skip: on a -ForEach Describe binds before the row's keys exist, so it skips
# nothing. $IsWindows does not exist under Windows PowerShell 5.1.
$script:HDTImplementation = @(
    @{
        Name    = 'FakeEnvironmentProvider'
        Factory = { New-HDTFakeEnvironmentProvider -Variable @{
                PROCESSOR_ARCHITECTURE = 'AMD64'
                firmware_type          = 'UEFI'
            } }
        Skip    = $false
    }
    @{
        Name    = 'EnvironmentProvider'
        Factory = { New-HDTEnvironmentProvider }
        # PROCESSOR_ARCHITECTURE is set on every Windows machine, which is what
        # makes the same assertions serve both rows.
        Skip    = -not ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
    }
)

Describe 'IEnvironmentProvider contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    }

    Context 'implementation' -Skip:$Skip {

        BeforeEach {
            $script:environment = & $Factory $script:repoRoot
        }

        It 'exposes GetVariable' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapter is a pscustomobject carrying one.
            @($script:environment | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name }) |
                Should -Contain 'GetVariable'
        }

        It 'returns the value of a variable that is set' {
            $script:environment.GetVariable('PROCESSOR_ARCHITECTURE') | Should -Not -BeNullOrEmpty
        }

        It 'returns null for a variable that is not set' {
            $script:environment.GetVariable('HDT_NO_SUCH_VARIABLE') | Should -BeNullOrEmpty
        }

        It 'looks a variable up case-insensitively' {
            $upper = $script:environment.GetVariable('PROCESSOR_ARCHITECTURE')
            $lower = $script:environment.GetVariable('processor_architecture')

            $lower | Should -BeExactly $upper
        }

        It 'records each lookup in Operations' {
            $script:environment.GetVariable('PROCESSOR_ARCHITECTURE') | Out-Null
            $script:environment.GetVariable('HDT_NO_SUCH_VARIABLE') | Out-Null

            @($script:environment.Operations).Count | Should -Be 2
            @($script:environment.GetOperationName()) | Should -Be @('GetVariable', 'GetVariable')
            @($script:environment.Operations[1].Arguments)[0] | Should -BeExactly 'HDT_NO_SUCH_VARIABLE'
        }
    }
}
