# W2's static IP pane, behind the glass (.planning/WPF-FIRST.md).
#
# WMI, NOT NetTCPIP, AND THAT IS THE WHOLE POINT. SPIKES S14 recorded that
# Get-NetIPAddress does not exist in a WinPE image built from the ADK - the
# module is simply not there - and it is what killed the first SMB probe. So the
# pane configures the adapter through Win32_NetworkAdapterConfiguration, which
# WinPE-WMI guarantees:
#
#     EnableStatic(address, mask)   SetGateways(gateway)   SetDNSServerSearchOrder(dns)
#
# WHAT IS ASSERTED HERE IS THE ORDERED OPERATION LIST, which is this engine's
# benchmark shape (CLAUDE.md rule 5). Order is not cosmetic: a gateway set
# before the address exists is a gateway on a subnet the machine is not on yet,
# and WMI refuses it.
#
# AND THE REFUSALS. This command reconfigures the network of the machine it is
# running on - get it wrong in WinPE and the machine is off the network with
# nobody able to reach it - so it declines to guess which adapter it meant
# (CLAUDE.md rule 6) and declines to report success for a ReturnValue that was
# not one.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    function New-HDTTestAdapterInstance {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test object; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)] [string] $Description,
            [Parameter()] [int] $InterfaceIndex = 3,
            [Parameter()] [bool] $IPEnabled = $true
        )

        return [pscustomobject] @{
            Description    = $Description
            InterfaceIndex = $InterfaceIndex
            Index          = $InterfaceIndex
            IPEnabled      = $IPEnabled
            MACAddress     = '00:15:5D:0A:00:01'
        }
    }

    # The WinPE shape: exactly one adapter, which is why nothing has to be
    # chosen there.
    function New-HDTTestWinPeCim {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        param([Parameter()] [object[]] $Adapter)

        if ($null -eq $Adapter) {
            $Adapter = @((New-HDTTestAdapterInstance -Description 'Microsoft Hyper-V Network Adapter'))
        }

        return New-HDTFakeCimProvider -Instance @{ 'Win32_NetworkAdapterConfiguration' = $Adapter }
    }
}

Describe 'Set-HDTStaticAddress' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Set-HDTStaticAddress' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'supports ShouldProcess, because it reconfigures the machine it runs on' {
            # CLAUDE.md rule 6. Getting this wrong in WinPE takes the machine off
            # the network with nobody able to reach it.
            (Get-Command -Name 'Set-HDTStaticAddress').Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }

        It 'takes an injected CIM provider' {
            (Get-Command -Name 'Set-HDTStaticAddress').Parameters.ContainsKey('CimProvider') | Should -BeTrue
        }
    }

    Context 'the three calls, in the order WMI needs them' {

        It 'calls EnableStatic, then SetGateways, then SetDNSServerSearchOrder' {
            # THE BENCHMARK ASSERTION. A gateway set before the address exists is
            # a gateway on a subnet the machine is not on yet.
            $cim = New-HDTTestWinPeCim

            Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                -Gateway '192.168.2.1' -DnsServer '192.168.2.1' -CimProvider $cim | Out-Null

            @($cim.GetOperationName()) | Should -Be @(
                'GetInstance',
                'InvokeMethod(EnableStatic)',
                'InvokeMethod(SetGateways)',
                'InvokeMethod(SetDNSServerSearchOrder)')
        }

        It 'hands EnableStatic the address and mask, as the arrays WMI wants' {
            $cim = New-HDTTestWinPeCim

            Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' -CimProvider $cim | Out-Null

            $call = @($cim.Operations | Where-Object { $_.Operation -eq 'InvokeMethod(EnableStatic)' })[0]
            @($call.Arguments[2]['IPAddress']) | Should -Be @('192.168.2.50')
            @($call.Arguments[2]['SubnetMask']) | Should -Be @('255.255.255.0')
        }

        It 'hands SetGateways a cost metric alongside the gateway' {
            # SetGateways takes two parallel arrays; a gateway with no metric is
            # how the call fails on a machine with more than one route.
            $cim = New-HDTTestWinPeCim

            Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                -Gateway '192.168.2.1' -CimProvider $cim | Out-Null

            $call = @($cim.Operations | Where-Object { $_.Operation -eq 'InvokeMethod(SetGateways)' })[0]
            @($call.Arguments[2]['DefaultIPGateway']) | Should -Be @('192.168.2.1')
            @($call.Arguments[2]['GatewayCostMetric']).Count | Should -Be 1
        }

        It 'does not call SetGateways at all when no gateway was given' {
            # An isolated segment has no gateway, and calling SetGateways with
            # nothing is not the same as not calling it.
            $cim = New-HDTTestWinPeCim

            Set-HDTStaticAddress -IPAddress '172.30.30.50' -SubnetMask '255.255.255.0' -CimProvider $cim | Out-Null

            @($cim.GetOperationName()) | Should -Not -Contain 'InvokeMethod(SetGateways)'
        }

        It 'does not call SetDNSServerSearchOrder when no DNS server was given' {
            $cim = New-HDTTestWinPeCim

            Set-HDTStaticAddress -IPAddress '172.30.30.50' -SubnetMask '255.255.255.0' -CimProvider $cim | Out-Null

            @($cim.GetOperationName()) | Should -Not -Contain 'InvokeMethod(SetDNSServerSearchOrder)'
        }

        It 'passes every DNS server, in the order they were typed' {
            $cim = New-HDTTestWinPeCim

            Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                -DnsServer @('192.168.2.1', '1.1.1.1') -CimProvider $cim | Out-Null

            $call = @($cim.Operations | Where-Object { $_.Operation -eq 'InvokeMethod(SetDNSServerSearchOrder)' })[0]
            @($call.Arguments[2]['DNSServerSearchOrder']) | Should -Be @('192.168.2.1', '1.1.1.1')
        }

        It 'splits the comma-separated list the DNS box asks a technician to type' {
            # The hint under the DNS box says "Separate several with a comma",
            # so what the box produces has to be what this accepts. Otherwise the
            # hint on screen is an instruction to break it.
            $cim = New-HDTTestWinPeCim

            Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                -DnsServer '192.168.2.1, 1.1.1.1' -CimProvider $cim | Out-Null

            $call = @($cim.Operations | Where-Object { $_.Operation -eq 'InvokeMethod(SetDNSServerSearchOrder)' })[0]
            @($call.Arguments[2]['DNSServerSearchOrder']) | Should -Be @('192.168.2.1', '1.1.1.1')
        }
    }

    Context 'which adapter, and the refusal to guess' {

        It 'uses the only IP-enabled adapter without being told, which is the WinPE case' {
            $cim = New-HDTTestWinPeCim
            $result = Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' -CimProvider $cim

            [string] $result.AdapterDescription | Should -BeExactly 'Microsoft Hyper-V Network Adapter'
        }

        It 'refuses to choose between two adapters, naming both' {
            # CLAUDE.md rule 6: refuse ambiguous targets. Picking one would
            # reconfigure whichever adapter happened to be first, and on a
            # machine with two NICs that is a coin toss with the network on it.
            $cim = New-HDTTestWinPeCim -Adapter @(
                (New-HDTTestAdapterInstance -Description 'Intel I219-LM' -InterfaceIndex 3),
                (New-HDTTestAdapterInstance -Description 'Realtek USB GbE' -InterfaceIndex 9))

            $record = $null
            try {
                Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' -CimProvider $cim
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            [string] $record.Exception.Message | Should -BeLike '*Intel I219-LM*'
            [string] $record.Exception.Message | Should -BeLike '*Realtek USB GbE*'
        }

        It 'configures nothing at all when it refused to choose' {
            $cim = New-HDTTestWinPeCim -Adapter @(
                (New-HDTTestAdapterInstance -Description 'Intel I219-LM' -InterfaceIndex 3),
                (New-HDTTestAdapterInstance -Description 'Realtek USB GbE' -InterfaceIndex 9))

            try {
                Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' -CimProvider $cim
            } catch {
                $null = $_
            }

            @($cim.GetOperationName() | Where-Object { $_ -like 'InvokeMethod*' }) | Should -BeNullOrEmpty
        }

        It 'takes the adapter it was told to take, even when there are several' {
            $cim = New-HDTTestWinPeCim -Adapter @(
                (New-HDTTestAdapterInstance -Description 'Intel I219-LM' -InterfaceIndex 3),
                (New-HDTTestAdapterInstance -Description 'Realtek USB GbE' -InterfaceIndex 9))

            $result = Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                -InterfaceIndex 9 -CimProvider $cim

            [string] $result.AdapterDescription | Should -BeExactly 'Realtek USB GbE'
        }

        It 'refuses an interface index the machine does not have, naming it' {
            $cim = New-HDTTestWinPeCim

            { Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                    -InterfaceIndex 77 -CimProvider $cim } | Should -Throw -ExpectedMessage '*77*'
        }

        It 'refuses when the machine has no IP-enabled adapter at all' {
            $cim = New-HDTTestWinPeCim -Adapter @(
                (New-HDTTestAdapterInstance -Description 'WAN Miniport (PPTP)' -IPEnabled $false))

            { Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' -CimProvider $cim } |
                Should -Throw
        }
    }

    Context 'what it refuses to be told' {

        It 'refuses <_> as an address, naming it' -ForEach @('192.168.2', 'not-an-address', '999.1.1.1', '::1') {
            $cim = New-HDTTestWinPeCim

            { Set-HDTStaticAddress -IPAddress $PSItem -SubnetMask '255.255.255.0' -CimProvider $cim } |
                Should -Throw -ExpectedMessage ('*{0}*' -f $PSItem)
        }

        It 'refuses <_> as a subnet mask, naming it' -ForEach @('255.255.255', 'nonsense', '255.0.255.0') {
            # A NON-CONTIGUOUS MASK IS THE INTERESTING ONE. 255.0.255.0 is four
            # legal octets and not a mask; WMI accepts it and the machine ends up
            # on a subnet that cannot be reasoned about.
            $cim = New-HDTTestWinPeCim

            { Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask $PSItem -CimProvider $cim } |
                Should -Throw -ExpectedMessage ('*{0}*' -f $PSItem)
        }

        It 'refuses a gateway that is not an IPv4 address' {
            $cim = New-HDTTestWinPeCim

            { Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                    -Gateway 'router.local' -CimProvider $cim } | Should -Throw -ExpectedMessage '*router.local*'
        }

        It 'refuses a DNS server that is not an IPv4 address' {
            $cim = New-HDTTestWinPeCim

            { Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                    -DnsServer @('192.168.2.1', 'dns.local') -CimProvider $cim } |
                Should -Throw -ExpectedMessage '*dns.local*'
        }

        It 'checks everything before it changes anything' {
            # A COMMAND THAT HALF-CONFIGURES A NETWORK IS WORSE THAN ONE THAT
            # REFUSES. EnableStatic must not have run when the DNS list turns out
            # to be unusable.
            $cim = New-HDTTestWinPeCim

            try {
                Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                    -DnsServer @('dns.local') -CimProvider $cim
            } catch {
                $null = $_
            }

            @($cim.GetOperationName() | Where-Object { $_ -like 'InvokeMethod*' }) | Should -BeNullOrEmpty
        }
    }

    Context 'what the machine answered' {

        It 'reports what it applied' {
            $cim = New-HDTTestWinPeCim

            $result = Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                -Gateway '192.168.2.1' -DnsServer '192.168.2.1' -CimProvider $cim

            [bool] $result.Applied | Should -BeTrue
            [string] $result.IPAddress | Should -BeExactly '192.168.2.50'
            [string] $result.SubnetMask | Should -BeExactly '255.255.255.0'
            [string] $result.Gateway | Should -BeExactly '192.168.2.1'
            @($result.DnsServer) | Should -Be @('192.168.2.1')
        }

        It 'accepts 1, which is WMI for "done, but reboot"' {
            $cim = New-HDTTestWinPeCim
            $cim.SetMethodReturnValue('EnableStatic', 1)

            $result = Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' -CimProvider $cim

            [bool] $result.Applied | Should -BeTrue
            [bool] $result.RebootRequired | Should -BeTrue
        }

        It 'refuses to report success for a ReturnValue that was not one' {
            # 70 is "invalid IP address" and 91 is "access denied". Reporting a
            # configured network that was not configured sends a technician
            # looking at the share instead of at the address they typed.
            $cim = New-HDTTestWinPeCim
            $cim.SetMethodReturnValue('EnableStatic', 70)

            { Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' -CimProvider $cim } |
                Should -Throw -ExpectedMessage '*70*'
        }

        It 'names the method that failed, not just the code' {
            $cim = New-HDTTestWinPeCim
            $cim.SetMethodReturnValue('SetGateways', 82)

            { Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                    -Gateway '192.168.2.1' -CimProvider $cim } | Should -Throw -ExpectedMessage '*SetGateways*'
        }
    }

    Context 'WhatIf' {

        It 'changes nothing at all under -WhatIf' {
            $cim = New-HDTTestWinPeCim

            Set-HDTStaticAddress -IPAddress '192.168.2.50' -SubnetMask '255.255.255.0' `
                -Gateway '192.168.2.1' -CimProvider $cim -WhatIf | Out-Null

            @($cim.GetOperationName() | Where-Object { $_ -like 'InvokeMethod*' }) | Should -BeNullOrEmpty
        }
    }
}
