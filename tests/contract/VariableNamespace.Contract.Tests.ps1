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

    # Every variable that carries no underscore and is still not an
    # administrator's to set. One entry today; see the two assertions that
    # read it for why it is written down rather than derived.
    $script:declaredUnsettable = @('HDTDeploymentMethod')

    # The facts that come out of CIM. Everything else in the gathered set comes
    # from the environment (firmware_type, PROCESSOR_ARCHITECTURE) or from the
    # registry (the Secure Boot state value), so only these carry a
    # Class.Property origin.
    $script:cimSourcedFact = @(
        'HDTMake', 'HDTModel', 'HDTProduct', 'HDTSerialNumber', 'HDTUUID',
        'HDTSystemSKU', 'HDTMemory', 'HDTTPMVersion', 'HDTAssetTag',
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

    # THE PREFIX RULE IS A DEFAULT NOW, NOT A LAW. It used to be both, and
    # HDTDeploymentMethod is why it stopped: MDT's name is DeploymentMethod,
    # a step condition reads %HDTDeploymentMethod%, and it is still not
    # something an administrator may set. So the row says so, and the pair of
    # assertions below replace the single one that read the prefix as the
    # whole truth.
    It 'marks a non-underscore variable writable unless its row says otherwise' {
        $wrong = @($script:map |
                Where-Object { -not $_.HDTName.StartsWith('_') } |
                Where-Object { -not $_.Writable } |
                Where-Object { $script:declaredUnsettable -notcontains $_.HDTName })

        ($wrong | ForEach-Object { $_.HDTName }) -join ', ' | Should -BeExactly ''
    }

    # DELIBERATELY A HARD-CODED LIST, AND SET EQUALITY IN BOTH DIRECTIONS.
    # Making a variable unsettable takes something away from an administrator,
    # and it should cost an edit to a test that says out loud which ones. A
    # name added to the map without an edit here fails; a name removed from
    # the map without an edit here fails too.
    It 'names every non-writable non-underscore variable, so the list cannot grow by accident' {
        $actual = @($script:map |
                Where-Object { -not $_.HDTName.StartsWith('_') -and -not $_.Writable } |
                Select-Object -ExpandProperty HDTName |
                Sort-Object)

        ($actual -join ', ') | Should -BeExactly (($script:declaredUnsettable | Sort-Object) -join ', ')
    }

    It 'carries HDTDeploymentMethod, MDT''s DeploymentMethod, exactly once' {
        $row = @($script:map | Where-Object { $_.HDTName -eq 'HDTDeploymentMethod' })

        $row.Count | Should -Be 1
        $row[0].MdtName | Should -BeExactly 'DeploymentMethod'
    }

    It 'marks HDTDeploymentMethod as engine-origin and not writable' {
        $row = @($script:map | Where-Object { $_.HDTName -eq 'HDTDeploymentMethod' })

        $row.Count | Should -Be 1
        $row[0].Origin | Should -BeExactly 'engine'
        $row[0].Writable | Should -BeFalse
    }

    # THE GUARD AGAINST THE MERGE. DeploymentType is WHAT is being done and a
    # media deployment is still NEWCOMPUTER; DeploymentMethod is HOW the
    # machine got its content. Two rows, two MDT names, and neither
    # description claiming to be the other.
    It 'keeps HDTDeploymentType separate, writable, and mapped to MDT''s DeploymentType' {
        $type = @($script:map | Where-Object { $_.HDTName -eq 'HDTDeploymentType' })
        $method = @($script:map | Where-Object { $_.HDTName -eq 'HDTDeploymentMethod' })

        $type.Count | Should -Be 1
        $method.Count | Should -Be 1
        $type[0].MdtName | Should -BeExactly 'DeploymentType'
        $type[0].Writable | Should -BeTrue
        $type[0].Description | Should -Match 'NEWCOMPUTER'

        $method[0].MdtName | Should -Not -BeExactly $type[0].MdtName
        $method[0].Description | Should -Not -Match 'NEWCOMPUTER'
    }

    It 'describes HDTDeploymentMethod as UNC or MEDIA and mentions neither OSD nor SCCM' {
        $row = @($script:map | Where-Object { $_.HDTName -eq 'HDTDeploymentMethod' })

        $row.Count | Should -Be 1
        $row[0].Description | Should -Match 'UNC'
        $row[0].Description | Should -Match 'MEDIA'

        # MDT lists OSD and SCCM because MDT integrates with MECM. HDT does
        # not, so a description that offered them would document a value the
        # engine can never produce.
        $row[0].Description | Should -Not -Match '\bOSD\b'
        $row[0].Description | Should -Not -Match '\bSCCM\b'
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
