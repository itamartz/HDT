# Get-HDTMachineFact is HDT's replacement for ZTIGather.wsf: it produces the
# DESIGN 3.2 fact set from injected services and nothing else.
#
# Every assertion here runs with NO MACHINE ATTACHED. The facts come from
# fixtures captured off a real machine (tests/fixtures/README.md), the registry
# and environment from seeded fakes. That is the whole point of PROJECT
# constraint 4: if the gatherer called Get-CimInstance itself, none of this
# could be proven anywhere but on the machine it was written on.
#
# Expected values are computed FROM the fixture wherever a number or a count is
# involved, never hard-coded, so re-capturing the fixture cannot leave a test
# asserting a stale value that happens to still pass.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:cimFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim'
    $script:tpmFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-microsofttpm'
    $script:vmFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-vm'
    $script:tpmNamespace = 'root/cimv2/security/microsofttpm'

    function Get-HDTFactFixture {
        <#
            .SYNOPSIS
                Reads one captured CIM fixture back as an instance array.
        #>
        [CmdletBinding()]
        [OutputType([object[]])]
        param(
            [Parameter(Mandatory = $true)]
            [string] $Directory,

            [Parameter(Mandatory = $true)]
            [string] $ClassName
        )

        $path = Join-Path -Path $Directory -ChildPath ("{0}.json" -f $ClassName)
        return , ([object[]] @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json))
    }

    function New-HDTFactCimProvider {
        <#
            .SYNOPSIS
                Builds a fake ICimProvider from the captured fixtures, minus any
                class named in -Exclude and plus anything in -Override.

            .DESCRIPTION
                -Exclude is how "this machine has no such class" is expressed: the
                fake throws for an unseeded class exactly as Get-CimInstance does
                for an invalid one, which is what WinPE without the TPM optional
                component actually looks like.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter()]
            [string[]] $Exclude = @(),

            [Parameter()]
            [hashtable] $Override = @{},

            [Parameter()]
            [switch] $WithoutTpmNamespace
        )

        $instance = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $script:cimFixturePath -Filter '*.json' -File)) {
            if ($Exclude -contains $file.BaseName) {
                continue
            }
            $instance[$file.BaseName] = [object[]] @(Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json)
        }

        foreach ($key in @($Override.Keys)) {
            $instance[$key] = [object[]] @($Override[$key])
        }

        if ($WithoutTpmNamespace) {
            return New-HDTFakeCimProvider -Instance $instance
        }

        return New-HDTFakeCimProvider -Instance $instance -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }
    }
}

Describe 'Get-HDTMachineFact' {

    BeforeEach {
        $script:cim = New-HDTFakeCimProvider `
            -FixturePath $script:cimFixturePath `
            -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }

        $script:environment = New-HDTFakeEnvironmentProvider -Variable @{
            firmware_type          = 'UEFI'
            PROCESSOR_ARCHITECTURE = 'AMD64'
        }

        $script:registry = New-HDTFakeRegistryService -Value @{
            'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' = @{ UEFISecureBootEnabled = 1 }
        }
    }

    Context 'the captured physical machine' {

        BeforeEach {
            $script:fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment
        }

        It 'returns an ordered dictionary' {
            # Ordered so a facts.json diff stays readable later, and a dictionary
            # rather than a pscustomobject so the rule engine can add keys.
            $script:fact -is [System.Collections.Specialized.OrderedDictionary] | Should -BeTrue
        }

        It 'looks a fact up case-insensitively' {
            # rules.yaml is written by hand; HDTmodel and HDTModel are the same
            # variable.
            $script:fact['hdtmodel'] | Should -BeExactly $script:fact['HDTModel']
        }

        It 'resolves HDTMake from Win32_ComputerSystem.Manufacturer' {
            $expected = (Get-HDTFactFixture -Directory $script:cimFixturePath -ClassName 'Win32_ComputerSystem')[0].Manufacturer

            $script:fact['HDTMake'] | Should -BeExactly $expected
        }

        It 'resolves HDTModel from Win32_ComputerSystem.Model' {
            $expected = (Get-HDTFactFixture -Directory $script:cimFixturePath -ClassName 'Win32_ComputerSystem')[0].Model

            $script:fact['HDTModel'] | Should -BeExactly $expected
        }

        It 'resolves HDTProduct from Win32_BaseBoard.Product' {
            $expected = (Get-HDTFactFixture -Directory $script:cimFixturePath -ClassName 'Win32_BaseBoard')[0].Product

            $script:fact['HDTProduct'] | Should -BeExactly $expected
        }

        It 'resolves HDTSerialNumber from Win32_BIOS' {
            $expected = (Get-HDTFactFixture -Directory $script:cimFixturePath -ClassName 'Win32_BIOS')[0].SerialNumber

            $script:fact['HDTSerialNumber'] | Should -BeExactly $expected
        }

        It 'resolves HDTUUID from Win32_ComputerSystemProduct' {
            $expected = (Get-HDTFactFixture -Directory $script:cimFixturePath -ClassName 'Win32_ComputerSystemProduct')[0].UUID

            $script:fact['HDTUUID'] | Should -BeExactly $expected.ToUpperInvariant()
        }

        It 'resolves HDTSystemSKU from Win32_ComputerSystem.SystemSKUNumber' {
            $expected = (Get-HDTFactFixture -Directory $script:cimFixturePath -ClassName 'Win32_ComputerSystem')[0].SystemSKUNumber

            $script:fact['HDTSystemSKU'] | Should -BeExactly $expected
        }

        It 'reports HDTMemory in whole megabytes, rounded down' {
            # Floor, never a cast: [int] on a double rounds to even, so the number
            # would depend on which machine the fixture came from.
            $bytes = (Get-HDTFactFixture -Directory $script:cimFixturePath -ClassName 'Win32_ComputerSystem')[0].TotalPhysicalMemory
            $expected = [int] [math]::Floor($bytes / 1MB)

            $script:fact['HDTMemory'] | Should -Be $expected
        }

        It 'trims whitespace from every string fact' {
            $cim = New-HDTFactCimProvider -Override @{
                Win32_ComputerSystem = @([pscustomobject] @{
                        Manufacturer        = '  LENOVO  '
                        Model               = "  82RF`t"
                        SystemSKUNumber     = '  SKU-0001 '
                        TotalPhysicalMemory = 1073741824
                    })
            }

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTMake'] | Should -BeExactly 'LENOVO'
            $fact['HDTModel'] | Should -BeExactly '82RF'
            $fact['HDTSystemSKU'] | Should -BeExactly 'SKU-0001'
        }
    }

    Context 'make and model fallbacks' {

        It 'falls back to Win32_BaseBoard.Manufacturer when Manufacturer is empty' {
            $expected = (Get-HDTFactFixture -Directory $script:cimFixturePath -ClassName 'Win32_BaseBoard')[0].Manufacturer
            $cim = New-HDTFactCimProvider -Override @{
                Win32_ComputerSystem = @([pscustomobject] @{
                        Manufacturer        = ''
                        Model               = '82RF'
                        SystemSKUNumber     = 'SKU-0001'
                        TotalPhysicalMemory = 1073741824
                    })
            }

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTMake'] | Should -BeExactly $expected
        }

        It 'falls back to Win32_BaseBoard.Product when Model is empty' {
            $expected = (Get-HDTFactFixture -Directory $script:cimFixturePath -ClassName 'Win32_BaseBoard')[0].Product
            $cim = New-HDTFactCimProvider -Override @{
                Win32_ComputerSystem = @([pscustomobject] @{
                        Manufacturer        = 'LENOVO'
                        Model               = '   '
                        SystemSKUNumber     = 'SKU-0001'
                        TotalPhysicalMemory = 1073741824
                    })
            }

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTModel'] | Should -BeExactly $expected
        }

        It 'does not query Win32_BaseBoard a second time for the fallback' {
            # DESIGN 12.2.1: each class is queried once into a local and derived
            # from. A second query is a second round trip to WMI in WinPE.
            $cim = New-HDTFactCimProvider -Override @{
                Win32_ComputerSystem = @([pscustomobject] @{
                        Manufacturer        = ''
                        Model               = ''
                        SystemSKUNumber     = 'SKU-0001'
                        TotalPhysicalMemory = 1073741824
                    })
            }

            Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment | Out-Null

            @($cim.Operations | Where-Object { $_.Arguments[1] -eq 'Win32_BaseBoard' }).Count | Should -Be 1
        }
    }

    Context 'chassis' {

        It 'reports HDTIsLaptop true for chassis type 10' {
            # The captured machine is a laptop, chassis type 10.
            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsLaptop'] | Should -BeTrue
        }

        It 'reports HDTIsDesktop false for chassis type 10' {
            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsDesktop'] | Should -BeFalse
            $fact['HDTIsServer'] | Should -BeFalse
        }

        It 'reports HDTIsDesktop true for chassis type 3' {
            $cim = New-HDTFactCimProvider -Override @{
                Win32_SystemEnclosure = @([pscustomobject] @{ ChassisTypes = @(3) })
            }

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsDesktop'] | Should -BeTrue
            $fact['HDTIsLaptop'] | Should -BeFalse
        }

        It 'reports HDTIsServer true for chassis type 23' {
            $cim = New-HDTFactCimProvider -Override @{
                Win32_SystemEnclosure = @([pscustomobject] @{ ChassisTypes = @(23) })
            }

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsServer'] | Should -BeTrue
            $fact['HDTIsDesktop'] | Should -BeFalse
            $fact['HDTIsLaptop'] | Should -BeFalse
        }

        It 'reports every chassis flag false when Win32_SystemEnclosure has no instances' {
            $cim = New-HDTFactCimProvider -Override @{ Win32_SystemEnclosure = @() }

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsDesktop'] | Should -BeFalse
            $fact['HDTIsLaptop'] | Should -BeFalse
            $fact['HDTIsServer'] | Should -BeFalse
        }

        It 'reports every chassis flag false when Win32_SystemEnclosure is absent' {
            # "The class is not there at all" is what a VM with no enclosure data
            # looks like, and it must degrade rather than throw.
            $cim = New-HDTFactCimProvider -Exclude 'Win32_SystemEnclosure'

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsDesktop'] | Should -BeFalse
            $fact['HDTIsLaptop'] | Should -BeFalse
            $fact['HDTIsServer'] | Should -BeFalse
        }
    }

    Context 'firmware, architecture and secure boot' {

        It 'reports HDTIsUEFI true when firmware_type is UEFI' {
            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsUEFI'] | Should -BeTrue
        }

        It 'reports HDTIsUEFI false when firmware_type is BIOS' {
            $environment = New-HDTFakeEnvironmentProvider -Variable @{ firmware_type = 'BIOS'; PROCESSOR_ARCHITECTURE = 'AMD64' }

            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $environment

            $fact['HDTIsUEFI'] | Should -BeFalse
        }

        It 'reports HDTIsUEFI false when firmware_type is not set' {
            $environment = New-HDTFakeEnvironmentProvider -Variable @{ PROCESSOR_ARCHITECTURE = 'AMD64' }

            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $environment

            $fact['HDTIsUEFI'] | Should -BeFalse
        }

        It 'reports HDTArchitecture x64 for AMD64' {
            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTArchitecture'] | Should -BeExactly 'x64'
        }

        It 'prefers PROCESSOR_ARCHITEW6432 over PROCESSOR_ARCHITECTURE' {
            # A 32-bit host process on a 64-bit machine reports x86 in
            # PROCESSOR_ARCHITECTURE and the truth in PROCESSOR_ARCHITEW6432.
            $environment = New-HDTFakeEnvironmentProvider -Variable @{
                PROCESSOR_ARCHITECTURE = 'x86'
                PROCESSOR_ARCHITEW6432 = 'AMD64'
                firmware_type          = 'UEFI'
            }

            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $environment

            $fact['HDTArchitecture'] | Should -BeExactly 'x64'
        }

        It 'upper-cases an architecture it does not translate' {
            $environment = New-HDTFakeEnvironmentProvider -Variable @{ PROCESSOR_ARCHITECTURE = 'arm64'; firmware_type = 'UEFI' }

            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $environment

            $fact['HDTArchitecture'] | Should -BeExactly 'ARM64'
        }

        It 'reports HDTSecureBootEnabled true when UEFISecureBootEnabled is 1' {
            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTSecureBootEnabled'] | Should -BeTrue
        }

        It 'reports HDTSecureBootEnabled false when UEFISecureBootEnabled is 0' {
            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' = @{ UEFISecureBootEnabled = 0 }
            }

            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $registry -EnvironmentProvider $script:environment

            $fact['HDTSecureBootEnabled'] | Should -BeFalse
        }

        It 'reports HDTSecureBootEnabled false when the SecureBoot state key is absent' {
            # A BIOS machine has no such key. Absence is a fact, not a failure.
            $registry = New-HDTFakeRegistryService

            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $registry -EnvironmentProvider $script:environment

            $fact['HDTSecureBootEnabled'] | Should -BeFalse
        }
    }

    Context 'TPM' {

        It 'reports HDTTPMVersion 2.0 from the SpecVersion of Win32_Tpm' {
            # SpecVersion is '2.0, 0, 1.38'; only the first component is the spec.
            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTTPMVersion'] | Should -BeExactly '2.0'
        }

        It 'reports HDTTPMVersion null when the microsofttpm namespace is absent' {
            # WinPE without the TPM optional component, and every machine with no
            # TPM at all.
            $cim = New-HDTFactCimProvider -WithoutTpmNamespace

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTTPMVersion'] | Should -BeNullOrEmpty
        }

        It 'does not throw when the microsofttpm namespace is absent' {
            $cim = New-HDTFactCimProvider -WithoutTpmNamespace

            { Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment } |
                Should -Not -Throw
        }
    }

    Context 'network' {

        BeforeEach {
            $script:adapter = @(Get-HDTFactFixture -Directory $script:cimFixturePath -ClassName 'Win32_NetworkAdapterConfiguration')
            $script:enabled = @($script:adapter | Where-Object { $_.IPEnabled } | Sort-Object -Property Index)
            $script:fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment
        }

        It 'collects HDTMacAddress from IP enabled adapters only' {
            $expected = @($script:enabled | ForEach-Object { $_.MACAddress } | Where-Object { $null -ne $_ })

            @($script:fact['HDTMacAddress']).Count | Should -Be $expected.Count
            @($script:fact['HDTMacAddress']).Count | Should -BeLessThan @($script:adapter).Count
        }

        It 'collects every address of every IP enabled adapter into HDTIPAddress' {
            $expected = @($script:enabled | ForEach-Object { $_.IPAddress } | Where-Object { $null -ne $_ })

            @($script:fact['HDTIPAddress']).Count | Should -Be $expected.Count
        }

        It 'collects HDTDefaultGateway, skipping adapters that have none' {
            $expected = @($script:enabled | ForEach-Object { $_.DefaultIPGateway } | Where-Object { $null -ne $_ })

            @($script:fact['HDTDefaultGateway']).Count | Should -Be $expected.Count
            @($script:fact['HDTDefaultGateway']).Count | Should -BeLessThan @($script:enabled).Count
        }

        It 'includes 10.20.30.1 in HDTDefaultGateway' {
            # The value DESIGN 3.3's 'Lab subnet' rule matches. Plan 02-03's
            # end-to-end demonstration depends on it.
            @($script:fact['HDTDefaultGateway']) | Should -Contain '10.20.30.1'
        }

        It 'keeps adapters in Index order' {
            $expected = @($script:enabled | ForEach-Object { $_.MACAddress } | Where-Object { $null -ne $_ })

            @($script:fact['HDTMacAddress']) | Should -Be $expected
        }

        It 'returns empty arrays when no adapter is IP enabled' {
            $cim = New-HDTFactCimProvider -Override @{
                Win32_NetworkAdapterConfiguration = @([pscustomobject] @{
                        Index            = 0
                        IPEnabled        = $false
                        MACAddress       = '00:15:5D:0A:00:00'
                        IPAddress        = @('10.20.30.100')
                        DefaultIPGateway = @('10.20.30.1')
                    })
            }

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            @($fact['HDTMacAddress']).Count | Should -Be 0
            @($fact['HDTIPAddress']).Count | Should -Be 0
            @($fact['HDTDefaultGateway']).Count | Should -Be 0
        }

        It 'returns empty arrays when Win32_NetworkAdapterConfiguration is absent' {
            $cim = New-HDTFactCimProvider -Exclude 'Win32_NetworkAdapterConfiguration'

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            @($fact['HDTMacAddress']).Count | Should -Be 0
            @($fact['HDTIPAddress']).Count | Should -Be 0
            @($fact['HDTDefaultGateway']).Count | Should -Be 0
        }
    }

    Context 'virtual machines' {

        It 'reports HDTIsVM false for the captured physical machine' {
            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsVM'] | Should -BeFalse
        }

        It 'reports HDTIsVM true for a Hyper-V guest' {
            $cim = New-HDTFactCimProvider -Override @{
                Win32_ComputerSystem        = @(Get-HDTFactFixture -Directory $script:vmFixturePath -ClassName 'Win32_ComputerSystem')
                Win32_ComputerSystemProduct = @(Get-HDTFactFixture -Directory $script:vmFixturePath -ClassName 'Win32_ComputerSystemProduct')
            }

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsVM'] | Should -BeTrue
        }

        It 'reports HDTIsVM true for VMware' {
            $cim = New-HDTFactCimProvider -Override @{
                Win32_ComputerSystem = @([pscustomobject] @{
                        Manufacturer        = 'VMware, Inc.'
                        Model               = 'VMware Virtual Platform'
                        SystemSKUNumber     = ''
                        TotalPhysicalMemory = 1073741824
                    })
            }

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsVM'] | Should -BeTrue
        }

        It 'reports HDTIsVM true for VirtualBox' {
            $cim = New-HDTFactCimProvider -Override @{
                Win32_ComputerSystem = @([pscustomobject] @{
                        Manufacturer        = 'innotek GmbH'
                        Model               = 'VirtualBox'
                        SystemSKUNumber     = ''
                        TotalPhysicalMemory = 1073741824
                    })
            }

            $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            $fact['HDTIsVM'] | Should -BeTrue
        }
    }

    Context 'the service contract' {

        It 'queries each CIM class exactly once, in a fixed order' {
            # The DESIGN 12.2.1 assertion in full: not only what came back, but
            # what the code under test asked for and in what order.
            Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment | Out-Null

            @($script:cim.Operations | ForEach-Object { $_.Arguments[1] }) | Should -Be @(
                'Win32_ComputerSystem',
                'Win32_ComputerSystemProduct',
                'Win32_BaseBoard',
                'Win32_BIOS',
                'Win32_SystemEnclosure',
                'Win32_NetworkAdapterConfiguration',
                'Win32_Tpm'
            )
        }

        It 'queries Win32_Tpm in the microsofttpm namespace' {
            Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment | Out-Null

            $tpmQuery = @($script:cim.Operations | Where-Object { $_.Arguments[1] -eq 'Win32_Tpm' })

            $tpmQuery.Count | Should -Be 1
            $tpmQuery[0].Arguments[0] | Should -BeExactly $script:tpmNamespace
        }

        It 'reads the SecureBoot state through the registry service, not the real registry' {
            Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment | Out-Null

            @($script:registry.Operations).Count | Should -BeGreaterThan 0
            @($script:registry.Operations | ForEach-Object { $_.Arguments[0] }) |
                Should -Contain 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
        }

        It 'reads firmware_type through the environment provider' {
            Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment | Out-Null

            @($script:environment.Operations | ForEach-Object { $_.Arguments[0] }) | Should -Contain 'firmware_type'
        }

        It 'does not produce HDTBootMode' {
            # Phase 05 owns it: only the boot path knows whether the machine came
            # from PXE or from media, and it is not a hardware fact.
            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            @($fact.Keys) | Should -Not -Contain 'HDTBootMode'
            @($fact.Keys) | Should -Not -Contain 'HDTComputerName'
            @($fact.Keys) | Should -Not -Contain 'HDTTimeZoneName'
        }

        It 'does not produce any _HDT variable' {
            # DESIGN 3.2: _HDT* is engine-owned. The gatherer must not claim one.
            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            @($fact.Keys | Where-Object { $_.StartsWith('_') }).Count | Should -Be 0
        }

        It 'names every fact with the HDT prefix' {
            $fact = Get-HDTMachineFact -CimProvider $script:cim -RegistryService $script:registry -EnvironmentProvider $script:environment

            @($fact.Keys | Where-Object { -not $_.StartsWith('HDT') }).Count | Should -Be 0
        }

        It 'requires CimProvider, RegistryService and EnvironmentProvider' {
            $parameter = (Get-Command -Name Get-HDTMachineFact).Parameters

            foreach ($name in @('CimProvider', 'RegistryService', 'EnvironmentProvider')) {
                $mandatory = @($parameter[$name].Attributes |
                        Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                        ForEach-Object { $_.Mandatory })

                $mandatory | Should -Contain $true -Because "$name is not optional: a gatherer with no services is a gatherer that touched the machine"
            }
        }

        It 'has comment-based help with a synopsis' {
            (Get-Help -Name Get-HDTMachineFact).Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
