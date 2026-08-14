# Behaviour that belongs to the fake itself rather than to the ICimProvider
# contract: seeding, namespace handling, query recording, and the guarantee that
# no query reaches the real CIM service.
#
# The fake is only ever obtained through New-HDTFakeCimProvider. The class name
# is never written as a type literal here: a type literal binds to whichever
# dynamic assembly loaded first and breaks across a module reload.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:fixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim'
    $script:tpmFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-microsofttpm'
    $script:vmFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-vm'
    $script:tpmNamespace = 'root/cimv2/security/microsofttpm'
}

Describe 'New-HDTFakeCimProvider' {

    It 'returns no classes when given no seed' {
        $cim = New-HDTFakeCimProvider

        { $cim.GetInstance('Win32_ComputerSystem') } | Should -Throw -ExpectedMessage '*Win32_ComputerSystem*'
    }

    It 'seeds instances from the -Instance hashtable' {
        $cim = New-HDTFakeCimProvider -Instance @{
            Win32_ComputerSystem = @([pscustomobject] @{ Manufacturer = 'LENOVO'; Model = '82RF' })
        }

        $instance = @($cim.GetInstance('Win32_ComputerSystem'))
        $instance.Count | Should -Be 1
        $instance[0].Model | Should -BeExactly '82RF'
    }

    It 'seeds into the supplied namespace' {
        $cim = New-HDTFakeCimProvider -Namespace $script:tpmNamespace -Instance @{
            Win32_Tpm = @([pscustomobject] @{ IsEnabled_InitialValue = $true })
        }

        @($cim.GetInstance($script:tpmNamespace, 'Win32_Tpm')).Count | Should -Be 1
        { $cim.GetInstance('Win32_Tpm') } | Should -Throw -ExpectedMessage '*Win32_Tpm*'
    }

    It 'loads every json file under -FixturePath' {
        $cim = New-HDTFakeCimProvider -FixturePath $script:fixturePath

        foreach ($class in @('Win32_ComputerSystem', 'Win32_ComputerSystemProduct', 'Win32_BaseBoard', 'Win32_BIOS')) {
            @($cim.GetInstance($class)).Count | Should -BeGreaterThan 0 -Because "$class.json is a fixture"
        }
    }

    It 'uses the fixture file base name as the class name' {
        $cim = New-HDTFakeCimProvider -FixturePath $script:fixturePath

        # The fixture is sanitised, so this pins the sanitised value, not a real one.
        @($cim.GetInstance('Win32_BIOS'))[0].SerialNumber | Should -BeExactly 'FIXTURE-SERIAL-0001'
    }

    It 'returns an empty array for a class seeded with no instances' {
        # "Class exists, no instances" is a different fact from "no such class",
        # and a fact gatherer has to tell them apart.
        $cim = New-HDTFakeCimProvider -Instance @{ Win32_TapeDrive = @() }

        $result = $cim.GetInstance('Win32_TapeDrive')

        @($result).Count | Should -Be 0
        { $cim.GetInstance('Win32_TapeDrive') } | Should -Not -Throw
    }

    It 'distinguishes namespaces' {
        $cim = New-HDTFakeCimProvider -Instance @{ Win32_Thing = @([pscustomobject] @{ Source = 'default' }) }
        $cim.AddInstance($script:tpmNamespace, 'Win32_Thing', @([pscustomobject] @{ Source = 'tpm' }))

        @($cim.GetInstance('Win32_Thing'))[0].Source | Should -BeExactly 'default'
        @($cim.GetInstance($script:tpmNamespace, 'Win32_Thing'))[0].Source | Should -BeExactly 'tpm'
    }

    It 'treats backslash and forward slash namespace separators as the same namespace' {
        $cim = New-HDTFakeCimProvider
        $cim.AddInstance('root\cimv2', 'Win32_Thing', @([pscustomobject] @{ Source = 'default' }))

        @($cim.GetInstance('root/cimv2', 'Win32_Thing')).Count | Should -Be 1
        @($cim.GetInstance('Win32_Thing')).Count | Should -Be 1
    }

    It 'supports the microsofttpm namespace used by fact gathering' {
        # DESIGN 3.2.1 gathers Win32_Tpm, which lives outside root/cimv2.
        $cim = New-HDTFakeCimProvider
        $cim.AddInstance($script:tpmNamespace, 'Win32_Tpm', @([pscustomobject] @{
                    IsEnabled_InitialValue  = $true
                    IsActivated_InitialValue = $true
                    SpecVersion             = '2.0, 0, 1.38'
                }))

        $tpm = @($cim.GetInstance($script:tpmNamespace, 'Win32_Tpm'))
        $tpm.Count | Should -Be 1
        $tpm[0].SpecVersion | Should -BeExactly '2.0, 0, 1.38'
    }

    It 'records every query in Operations' {
        $cim = New-HDTFakeCimProvider -FixturePath $script:fixturePath
        $cim.GetInstance('Win32_BIOS') | Out-Null
        $cim.GetInstance('root/cimv2', 'Win32_BaseBoard') | Out-Null

        @($cim.Operations).Count | Should -Be 2
        @($cim.Operations | ForEach-Object { $_.Sequence }) | Should -Be @(1, 2)
    }

    It 'records the namespace and class of each query' {
        $cim = New-HDTFakeCimProvider -FixturePath $script:fixturePath
        $cim.GetInstance('Win32_BIOS') | Out-Null

        @($cim.Operations[0].Arguments) | Should -Be @('root/cimv2', 'Win32_BIOS')
    }

    It 'does not record seeding as an operation' {
        $cim = New-HDTFakeCimProvider -FixturePath $script:fixturePath
        $cim.AddInstance('root/cimv2', 'Win32_Thing', @())

        @($cim.Operations).Count | Should -Be 0
    }

    It 'returns query names in order from GetOperationName' {
        $cim = New-HDTFakeCimProvider -FixturePath $script:fixturePath
        $cim.GetInstance('Win32_ComputerSystem') | Out-Null
        $cim.GetInstance('Win32_BIOS') | Out-Null

        $cim.GetOperationName() | Should -Be @('GetInstance', 'GetInstance')
    }

    It 'records a query that threw' {
        # Query order is evidence about what the code under test tried, not only
        # about what succeeded.
        $cim = New-HDTFakeCimProvider
        { $cim.GetInstance('Win32_NoSuchClassHDT') } | Should -Throw

        @($cim.Operations).Count | Should -Be 1
        @($cim.Operations[0].Arguments) | Should -Be @('root/cimv2', 'Win32_NoSuchClassHDT')
    }

    It 'never contacts the real CIM service' {
        # Win32_OperatingSystem certainly exists on this machine. An unseeded fake
        # must still refuse it rather than quietly returning live data.
        $cim = New-HDTFakeCimProvider

        { $cim.GetInstance('Win32_OperatingSystem') } | Should -Throw -ExpectedMessage '*Win32_OperatingSystem*'
        { $cim.GetInstance('Win32_ComputerSystem') } | Should -Throw -ExpectedMessage '*Win32_ComputerSystem*'
    }

    It 'is independent between instances' {
        $first = New-HDTFakeCimProvider -FixturePath $script:fixturePath
        $second = New-HDTFakeCimProvider

        { $second.GetInstance('Win32_BIOS') } | Should -Throw
        @($first.GetInstance('Win32_BIOS')).Count | Should -Be 1
    }

    Context 'namespace fixtures' {
        # -FixturePath seeds root/cimv2 only and ignores subdirectories, so
        # Win32_Tpm - which lives in root/cimv2/security/microsofttpm - needs its
        # own directory and its own parameter rather than a nested folder.

        It 'seeds a namespace directory from -NamespaceFixturePath' {
            $cim = New-HDTFakeCimProvider -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }

            @($cim.GetInstance($script:tpmNamespace, 'Win32_Tpm')).Count | Should -Be 1
        }

        It 'uses the file base name as the class name for a namespace fixture' {
            $cim = New-HDTFakeCimProvider -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }

            @($cim.GetInstance($script:tpmNamespace, 'Win32_Tpm'))[0].SpecVersion | Should -BeExactly '2.0, 0, 1.38'
        }

        It 'seeds root/cimv2 and a second namespace in one call' {
            $cim = New-HDTFakeCimProvider `
                -FixturePath $script:fixturePath `
                -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }

            @($cim.GetInstance('Win32_BIOS')).Count | Should -Be 1
            @($cim.GetInstance($script:tpmNamespace, 'Win32_Tpm')).Count | Should -Be 1
        }

        It 'does not seed a namespace fixture into root/cimv2' {
            $cim = New-HDTFakeCimProvider -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }

            { $cim.GetInstance('Win32_Tpm') } | Should -Throw -ExpectedMessage '*Win32_Tpm*'
        }

        It 'accepts more than one namespace' {
            $cim = New-HDTFakeCimProvider -NamespaceFixturePath @{
                $script:tpmNamespace = $script:tpmFixturePath
                'root/hdtvm'         = $script:vmFixturePath
            }

            @($cim.GetInstance($script:tpmNamespace, 'Win32_Tpm')).Count | Should -Be 1
            @($cim.GetInstance('root/hdtvm', 'Win32_ComputerSystem'))[0].Model | Should -BeExactly 'Virtual Machine'
        }

        It 'throws naming the directory when a -NamespaceFixturePath directory is missing' {
            $missing = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-no-such-directory'

            { New-HDTFakeCimProvider -NamespaceFixturePath @{ $script:tpmNamespace = $missing } } |
                Should -Throw -ExpectedMessage '*cim-no-such-directory*'
        }

        It 'does not record seeding from -NamespaceFixturePath as an operation' {
            $cim = New-HDTFakeCimProvider `
                -FixturePath $script:fixturePath `
                -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }

            @($cim.Operations).Count | Should -Be 0
        }
    }

    Context 'invoking a method on an instance' {

        # WMI IS HOW WinPE CONFIGURES A NETWORK (SPIKES S14), so reading CIM was
        # never enough: Win32_NetworkAdapterConfiguration's EnableStatic,
        # SetGateways and SetDNSServerSearchOrder are the only route to a static
        # address on the one machine that matters.

        BeforeAll {
            $script:adapter = [pscustomobject] @{ Description = 'Microsoft Hyper-V Network Adapter'; InterfaceIndex = 3 }
        }

        It 'answers 0 for a method nobody said anything about' {
            # 0 is what a machine that did what it was told returns.
            $cim = New-HDTFakeCimProvider
            $cim.InvokeMethod($script:adapter, 'EnableStatic', @{ IPAddress = @('192.168.2.50') }) | Should -Be 0
        }

        It 'answers what the test told it to answer' {
            $cim = New-HDTFakeCimProvider
            $cim.SetMethodReturnValue('EnableStatic', 70)

            $cim.InvokeMethod($script:adapter, 'EnableStatic', @{ IPAddress = @('bad') }) | Should -Be 70
        }

        It 'records the method name in the operation, not just that a method ran' {
            # The ordered operation list is the assertion these suites are built
            # on, and "three method calls happened" is not a fact about which
            # three or in what order.
            $cim = New-HDTFakeCimProvider
            $cim.InvokeMethod($script:adapter, 'EnableStatic', @{}) | Out-Null
            $cim.InvokeMethod($script:adapter, 'SetGateways', @{}) | Out-Null

            @($cim.GetOperationName()) | Should -Be @('InvokeMethod(EnableStatic)', 'InvokeMethod(SetGateways)')
        }

        It 'keeps the arguments it was handed, so a test can assert the values' {
            $cim = New-HDTFakeCimProvider
            $cim.InvokeMethod($script:adapter, 'EnableStatic',
                @{ IPAddress = @('192.168.2.50'); SubnetMask = @('255.255.255.0') }) | Out-Null

            @($cim.Operations[0].Arguments[2]['SubnetMask']) | Should -Be @('255.255.255.0')
        }

        It 'flattens the arguments in a stable order, not hashtable order' {
            $cim = New-HDTFakeCimProvider
            $cim.InvokeMethod($script:adapter, 'EnableStatic',
                @{ SubnetMask = @('255.255.255.0'); IPAddress = @('192.168.2.50') }) | Out-Null

            [string] $cim.Operations[0].Arguments[1] |
                Should -BeExactly 'IPAddress=192.168.2.50;SubnetMask=255.255.255.0'
        }

        It 'refuses a method with no name' {
            $cim = New-HDTFakeCimProvider
            { $cim.InvokeMethod($script:adapter, '', @{}) } | Should -Throw
        }
    }
}
