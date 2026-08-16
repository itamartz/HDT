# The IFeatureService contract (PROJECT constraint 4, DESIGN 10.2, DESIGN 12.2.1).
#
# Two methods:
#
#   GetFeature()                                  -> object[]  every feature the
#                                                              target OS knows,
#                                                              with its state
#   InstallFeature(name[], managementTools, source) -> the result row
#
# GetFeature IS FLAT AND UNFILTERED, for the reason IDiskService's three listings
# are: the deciding - is this name real, is it already installed, which of these
# do I still have to install - is pure logic that can be tested, rather than an
# adapter argument that cannot.
#
# THE REAL ROW ONLY RUNS ON A SERVER. Install-WindowsFeature lives in the
# ServerManager module, which does not exist on a client SKU, and this repository
# is developed on Windows 11. The real adapter is therefore branch-free by rule 1
# and is exercised on a server or not at all - which is precisely why the FAKE
# has to be worth trusting, and why every behavioural assertion below runs
# against it.
#
# The skip goes on a Context INSIDE the Describe, never on the -ForEach Describe
# itself: -Skip: there is bound before -ForEach binds the row's keys, so it does
# not skip (tests/helpers/README.md F9).

$script:HDTServerManager = [bool](Get-Module -ListAvailable -Name ServerManager -ErrorAction SilentlyContinue)

if (-not $script:HDTServerManager) {
    Write-Warning 'IFeatureService: the real adapter row is skipped. Install-WindowsFeature ships in the ServerManager module, which exists only on a Windows Server SKU. The fake carries every behavioural assertion.'
}

$script:HDTImplementation = @(
    @{
        Name        = 'FakeFeatureService'
        Factory     = { New-HDTFakeFeatureService -Feature @{
                'Web-Server'             = 'Available'
                'Web-Mgmt-Console'       = 'Available'
                'NET-Framework-45-Core'  = 'Installed'
                'NET-Framework-Core'     = 'Removed'
            } }
        IsReal      = $false
    }
    @{
        Name        = 'FeatureService'
        Factory     = { New-HDTFeatureService }
        IsReal      = $true
    }
)

Describe 'IFeatureService contract: <Name>' -ForEach $script:HDTImplementation {

    # The imports live in the DESCRIBE's BeforeAll, not in each Context's. A
    # Factory scriptblock was created in the discovery-time script scope, and a
    # module imported inside a Context is not visible to it - the fake comes back
    # CommandNotFound. DiskService.Contract has the same shape for the same
    # reason.
    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    }

    Context 'the shape' {

        BeforeAll {
            $script:service = & $Factory
        }

        It 'exposes GetFeature and InstallFeature' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapter is a pscustomobject carrying one.
            $method = @($script:service | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('GetFeature', 'InstallFeature')) {
                $method | Should -Contain $name -Because "IFeatureService requires $name"
            }
        }

        It 'exposes the operation journal every service carries' {
            $member = @($script:service | Get-Member | ForEach-Object { $_.Name })

            $member | Should -Contain 'Operations'
            $member | Should -Contain 'GetOperationName'
        }

        It 'names itself for the cross-service journal' {
            $script:service.ServiceName | Should -BeExactly 'FeatureService'
        }
    }

    Context 'the behaviour' -Skip:$IsReal {

        BeforeEach {
            $script:fs = & $Factory
        }

        It 'lists every feature with a name and an install state' {
            $feature = @($script:fs.GetFeature())

            $feature.Count | Should -BeGreaterThan 0

            foreach ($row in $feature) {
                $row.Name | Should -Not -BeNullOrEmpty
                @('Installed', 'Available', 'Removed') | Should -Contain $row.InstallState
            }
        }

        It 'lists features it will not install as well as ones it will' {
            # Removed - the payload is gone from the image - is the state that
            # makes source: necessary, and an adapter that filtered it out would
            # make the .NET 3.5 case undiagnosable.
            @($script:fs.GetFeature() | Where-Object { $_.InstallState -eq 'Removed' }).Count |
                Should -BeGreaterThan 0
        }

        It 'returns Success, RestartNeeded and ExitCode from InstallFeature' {
            $result = $script:fs.InstallFeature([string[]] @('Web-Server'), $true, '')

            $result.Success | Should -BeOfType ([bool])
            $result.RestartNeeded | Should -BeOfType ([bool])
            $result.ExitCode | Should -BeOfType ([int])
        }

        It 'records GetFeature' {
            $null = $script:fs.GetFeature()

            $script:fs.GetOperationName() | Should -Be @('GetFeature')
        }

        It 'records InstallFeature with the names it was given' {
            $null = $script:fs.InstallFeature([string[]] @('Web-Server', 'Web-Mgmt-Console'), $false, '')

            $script:fs.GetOperationName() | Should -Be @('InstallFeature')
            @($script:fs.Operations)[0].Arguments[0] | Should -Be @('Web-Server', 'Web-Mgmt-Console')
        }

        It 'records the source it was given' {
            # DESIGN 10.2's side-by-side case. The step resolves it through the
            # content provider; the adapter only passes it on.
            $null = $script:fs.InstallFeature([string[]] @('NET-Framework-Core'), $false, 'X:\Sources\SxS')

            @($script:fs.Operations)[0].Arguments[2] | Should -BeExactly 'X:\Sources\SxS'
        }
    }
}
