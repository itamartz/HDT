# The HDT variable namespace contract (DESIGN 3.2).
#
# DESIGN 3.2 says the mapping "cannot silently drift". Drift has two directions
# and this file closes both:
#
#   * the map against the design - every documented MDT name has exactly one HDT
#     counterpart, every name obeys the prefix rule, every _HDT* name is
#     read-only, and the engine variables of DESIGN 4.4.1 are all present;
#   * the map against the code - every fact Get-HDTMachineFact actually produces
#     appears in the map, gathered from the captured fixtures exactly as
#     tests/unit/Get-HDTMachineFact.Tests.ps1 gathers them. Without that leg the
#     gatherer could grow a fact the map never hears about.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:map = @(Get-HDTVariableMap)

    # The facts that come out of CIM. Everything else in the gathered set comes
    # from the environment (firmware_type, PROCESSOR_ARCHITECTURE) or from the
    # registry (the Secure Boot state value), so only these carry a
    # Class.Property origin.
    $script:cimSourcedFact = @(
        'HDTMake', 'HDTModel', 'HDTProduct', 'HDTSerialNumber', 'HDTUUID',
        'HDTSystemSKU', 'HDTMemory', 'HDTTPMVersion',
        'HDTIsDesktop', 'HDTIsLaptop', 'HDTIsServer', 'HDTIsVM',
        'HDTMacAddress', 'HDTIPAddress', 'HDTDefaultGateway'
    )
}

Describe 'HDT variable namespace contract' {

    It 'gives every HDT name exactly once' {
        $duplicate = @($script:map | Group-Object -Property HDTName | Where-Object { $_.Count -gt 1 })

        ($duplicate | ForEach-Object { $_.Name }) -join ', ' | Should -BeExactly ''
    }

    It 'maps every documented MDT name to exactly one HDT name' {
        $duplicate = @($script:map |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.MdtName) } |
                Group-Object -Property MdtName |
                Where-Object { $_.Count -gt 1 })

        ($duplicate | ForEach-Object { $_.Name }) -join ', ' | Should -BeExactly ''
    }

    It 'never puts an HDT name in the MDT column' {
        # DESIGN 3.2's table carried '| HDTComputerName | HDTComputerName |',
        # where the left column is the MDT name. MDT's name is OSDComputerName.
        # This assertion is what would have caught it.
        $wrong = @($script:map |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.MdtName) } |
                Where-Object { $_.MdtName -like 'HDT*' -or $_.MdtName -like '_HDT*' })

        ($wrong | ForEach-Object { $_.HDTName }) -join ', ' | Should -BeExactly ''
    }

    It 'names every variable to match ^_?HDT[A-Z]' {
        $wrong = @($script:map | Where-Object { $_.HDTName -cnotmatch '^_?HDT[A-Z]' })

        ($wrong | ForEach-Object { $_.HDTName }) -join ', ' | Should -BeExactly ''
    }

    It 'marks every _HDT variable as not writable' {
        $wrong = @($script:map | Where-Object { $_.HDTName.StartsWith('_') -and $_.Writable })

        ($wrong | ForEach-Object { $_.HDTName }) -join ', ' | Should -BeExactly ''
    }

    It 'marks every non-underscore HDT variable as writable' {
        $wrong = @($script:map | Where-Object { -not $_.HDTName.StartsWith('_') -and -not $_.Writable })

        ($wrong | ForEach-Object { $_.HDTName }) -join ', ' | Should -BeExactly ''
    }

    It 'includes every engine variable DESIGN 4.4.1 declares' {
        $name = @($script:map | Select-Object -ExpandProperty HDTName)

        foreach ($engine in @('_HDTLogPath', '_HDTRunId', '_HDTPhase', '_HDTStepName', '_HDTStepType', '_HDTDeployRoot', '_HDTVersion')) {
            $name | Should -Contain $engine
        }
    }

    It 'marks every engine variable of DESIGN 4.4.1 as engine-owned' {
        foreach ($engine in @('_HDTLogPath', '_HDTRunId', '_HDTPhase', '_HDTStepName', '_HDTStepType', '_HDTDeployRoot', '_HDTVersion')) {
            $row = @($script:map | Where-Object { $_.HDTName -eq $engine })

            $row.Count | Should -Be 1
            $row[0].Origin | Should -BeExactly 'engine'
            $row[0].Writable | Should -BeFalse
        }
    }

    It 'includes every HDT-specific addition DESIGN 3.2 declares' {
        $name = @($script:map | Select-Object -ExpandProperty HDTName)

        foreach ($addition in @('HDTSecureBootEnabled', 'HDTTPMVersion', 'HDTBootMode', 'HDTDiskLayout')) {
            $name | Should -Contain $addition
        }
    }

    It 'gives an HDT-specific addition no MDT counterpart' {
        foreach ($addition in @('HDTSecureBootEnabled', 'HDTTPMVersion', 'HDTBootMode', 'HDTDiskLayout')) {
            $row = @($script:map | Where-Object { $_.HDTName -eq $addition })

            $row.Count | Should -Be 1
            $row[0].MdtName | Should -BeNullOrEmpty
        }
    }

    It 'includes every fact Get-HDTMachineFact produces' {
        $cim = New-HDTFakeCimProvider `
            -FixturePath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim') `
            -NamespaceFixturePath @{ 'root/cimv2/security/microsofttpm' = (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-microsofttpm') }
        $registry = New-HDTFakeRegistryService -Value @{
            'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' = @{ UEFISecureBootEnabled = 1 }
        }
        $environment = New-HDTFakeEnvironmentProvider -Variable @{
            firmware_type          = 'UEFI'
            PROCESSOR_ARCHITECTURE = 'AMD64'
        }

        $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $registry -EnvironmentProvider $environment
        $name = @($script:map | Select-Object -ExpandProperty HDTName)

        @($fact.Keys).Count | Should -BeGreaterThan 0
        foreach ($key in @($fact.Keys)) {
            $name | Should -Contain $key
        }
    }

    It 'records a CIM class and property as the Origin of every gathered fact' {
        foreach ($fact in $script:cimSourcedFact) {
            $row = @($script:map | Where-Object { $_.HDTName -eq $fact })

            $row.Count | Should -Be 1
            $row[0].Origin | Should -Match '^Win32_[A-Za-z]+\.[A-Za-z]+'
        }
    }

    It 'gives every variable a description' {
        $wrong = @($script:map | Where-Object { [string]::IsNullOrWhiteSpace($_.Description) })

        ($wrong | ForEach-Object { $_.HDTName }) -join ', ' | Should -BeExactly ''
    }

    It 'describes the HDTSkip family rather than enumerating it' {
        $row = @($script:map | Where-Object { $_.HDTName -eq 'HDTSkipWizard' })

        $row.Count | Should -Be 1
        $row[0].MdtName | Should -BeExactly 'SkipWizard'
        $row[0].Description | Should -Match 'HDTSkip'
    }

    It 'covers every MDT name DESIGN 3.2 documents' {
        $mdt = @($script:map | Select-Object -ExpandProperty MdtName)

        foreach ($documented in @(
                'OSDComputerName', 'TaskSequenceID', 'JoinDomain', 'DomainAdmin',
                'DomainAdminPassword', 'MachineObjectOU', 'JoinWorkgroup',
                'AdminPassword', 'Applications', 'SkipWizard', 'DeployRoot',
                'WSUSServer', 'DriverGroup', '_SMSTSLogPath', 'Make', 'Model',
                'SerialNumber', 'UUID', 'Product', 'SystemSKU', 'IsDesktop',
                'IsLaptop', 'IsServer', 'IsVM', 'Architecture', 'IsUEFI',
                'Memory', 'MacAddress', 'IPAddress', 'DefaultGateway',
                'TimeZoneName')) {
            $mdt | Should -Contain $documented
        }
    }
}
