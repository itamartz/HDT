# The ICimProvider contract (PROJECT constraint 4, DESIGN 3.2.1, DESIGN 12.2.1).
#
# Every implementation of ICimProvider - the fake seeded from captured fixtures
# today, the real Get-CimInstance adapter in phase 02 - must pass this file
# unchanged. Adding an implementation is a one-row change to
# $script:HDTImplementation below, not a new test file.
#
# The registry is built at discovery time, not in BeforeAll: Pester 5 expands
# -ForEach while discovering, so a BeforeAll would produce zero test cases.

# Each Factory is invoked at run time as & $Factory $repositoryRoot. It is passed
# the repository root because a discovery-phase variable does not survive into
# Pester's run phase, so a factory may not close over one; declare the parameter
# only if the factory uses it.
$script:HDTImplementation = @(
    @{ Name = 'FakeCimProvider'; Factory = { param($RepositoryRoot) New-HDTFakeCimProvider -FixturePath (Join-Path -Path $RepositoryRoot -ChildPath 'tests/fixtures/cim') } }
    # Phase 02 appends the real Get-CimInstance adapter, tagged so it can be
    # excluded off-Windows:
    # @{ Name = 'CimProvider'; Factory = { param($RepositoryRoot) New-HDTCimProvider } }
)

Describe 'ICimProvider contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    }

    BeforeEach {
        $script:cim = & $Factory $script:repoRoot
    }

    It 'exposes GetInstance' {
        @($script:cim | Get-Member -MemberType Method | ForEach-Object { $_.Name }) |
            Should -Contain 'GetInstance'
    }

    It 'returns at least one Win32_ComputerSystem instance' {
        @($script:cim.GetInstance('Win32_ComputerSystem')).Count | Should -BeGreaterThan 0
    }

    It 'returns instances with a Manufacturer property' {
        $instance = @($script:cim.GetInstance('Win32_ComputerSystem'))[0]

        @($instance.PSObject.Properties.Name) | Should -Contain 'Manufacturer'
        $instance.Manufacturer | Should -Not -BeNullOrEmpty
    }

    It 'returns instances with a Model property' {
        $instance = @($script:cim.GetInstance('Win32_ComputerSystem'))[0]

        @($instance.PSObject.Properties.Name) | Should -Contain 'Model'
        $instance.Model | Should -Not -BeNullOrEmpty
    }

    It 'returns a Win32_BIOS instance with a SerialNumber property' {
        $instance = @($script:cim.GetInstance('Win32_BIOS'))[0]

        @($instance.PSObject.Properties.Name) | Should -Contain 'SerialNumber'
        $instance.SerialNumber | Should -Not -BeNullOrEmpty
    }

    It 'returns a Win32_ComputerSystemProduct instance with a UUID property' {
        $instance = @($script:cim.GetInstance('Win32_ComputerSystemProduct'))[0]

        @($instance.PSObject.Properties.Name) | Should -Contain 'UUID'
        $instance.UUID | Should -Not -BeNullOrEmpty
    }

    It 'returns a Win32_SystemEnclosure instance with ChassisTypes' {
        # DESIGN 3.2 derives HDTIsDesktop/HDTIsLaptop/HDTIsServer from
        # ChassisTypes[0]. Every physical and virtual Windows machine reports an
        # enclosure, so this is safe to assert of any implementation.
        $instance = @($script:cim.GetInstance('Win32_SystemEnclosure'))[0]

        @($instance.PSObject.Properties.Name) | Should -Contain 'ChassisTypes'
        @($instance.ChassisTypes).Count | Should -BeGreaterThan 0
    }

    It 'returns Win32_NetworkAdapterConfiguration instances, including adapters that are not IP enabled' {
        # DESIGN 3.2.1: network facts come from this class, not Get-NetIPAddress,
        # because WinPE has no NetTCPIP module. The ICimProvider contract has no
        # -Filter, so every implementation returns the unfiltered set and the fact
        # gatherer does the IPEnabled filtering itself.
        $instance = @($script:cim.GetInstance('Win32_NetworkAdapterConfiguration'))

        $instance.Count | Should -BeGreaterThan 0
        @($instance | Where-Object { -not $_.IPEnabled }).Count |
            Should -BeGreaterThan 0 -Because 'the unfiltered set must include adapters the gatherer has to drop'
    }

    It 'returns an array even for a single instance' {
        # Win32_BaseBoard is single-instance on real hardware, and a fact gatherer
        # that indexes [0] must not have to care.
        $result = $script:cim.GetInstance('Win32_BaseBoard')

        $result -is [System.Array] | Should -BeTrue
        @($result).Count | Should -BeGreaterThan 0
    }

    It 'defaults to the root/cimv2 namespace' {
        $implicit = @($script:cim.GetInstance('Win32_BIOS'))
        $explicit = @($script:cim.GetInstance('root/cimv2', 'Win32_BIOS'))

        $implicit.Count | Should -Be $explicit.Count
        $implicit[0].SerialNumber | Should -BeExactly $explicit[0].SerialNumber
    }

    It 'accepts an explicit namespace' {
        @($script:cim.GetInstance('root/cimv2', 'Win32_ComputerSystem')).Count | Should -BeGreaterThan 0
    }

    It 'throws for a class that does not exist, naming the class' {
        # Get-CimInstance names the invalid class in its message; a fake that threw
        # something vaguer would hide a typo in a fact gatherer.
        { $script:cim.GetInstance('Win32_NoSuchClassHDT') } |
            Should -Throw -ExpectedMessage '*Win32_NoSuchClassHDT*'
    }
}
