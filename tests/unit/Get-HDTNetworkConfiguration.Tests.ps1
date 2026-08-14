# W2's network pane reads the lease through Win32_NetworkAdapterConfiguration
# (.planning/WPF-FIRST.md; SPIKES S14 - Get-NetIPAddress does not exist in a
# WinPE image built from the ADK).
#
# THIS FILE IS A DEBT BEING PAID. Get-HDTNetworkConfiguration was written
# without a failing test in front of it, which inverts CLAUDE.md rule 1, and the
# first thing these tests found was that its headline behaviour - "the adapter
# with a gateway wins" - did not work at all. @($null).Count is 1 in PowerShell,
# so an adapter with NO DefaultIPGateway counted as having one, every adapter
# compared equal, and Sort-Object (not stable in 5.1, and there is no -Stable
# before 6.2) returned them scrambled. Against the captured shape of this build
# host it selected VMware VMnet4 - no gateway, no route to the share - which is
# precisely the machine-says-the-network-is-fine failure the code was written to
# prevent.
#
# So the assertions below are deliberately about SELECTION, not about plumbing:
#   * the adapter with a gateway wins over an earlier one without
#   * ties resolve by enumeration order, the same way every time
#   * APIPA is not a lease, and must never be shown as one
#   * a machine with nothing gets an honest empty answer rather than a throw
#
# The multi-adapter case uses tests/fixtures/cim/Win32_NetworkAdapterConfiguration.json -
# real captured data from this host (sanitised to 10.20.30.x), not an invented
# shape, per CLAUDE.md's fixture convention.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:fixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim'

    # A adapter shaped like Win32_NetworkAdapterConfiguration, with the nulls a
    # real one carries: an adapter with no gateway reports $null, NOT an empty
    # array, and that distinction is what broke the selection.
    function New-HDTTestAdapter {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test object; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string] $Description,

            [Parameter()]
            [bool] $IPEnabled = $true,

            [Parameter()]
            [AllowNull()]
            [string[]] $IPAddress,

            [Parameter()]
            [AllowNull()]
            [string[]] $IPSubnet,

            [Parameter()]
            [AllowNull()]
            [string[]] $DefaultIPGateway,

            [Parameter()]
            [AllowNull()]
            [string[]] $DNSServerSearchOrder
        )

        return [pscustomobject] @{
            Description          = $Description
            IPEnabled            = $IPEnabled
            IPAddress            = $IPAddress
            IPSubnet             = $IPSubnet
            DefaultIPGateway     = $DefaultIPGateway
            DNSServerSearchOrder = $DNSServerSearchOrder
        }
    }

    function New-HDTTestNetworkCim {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowEmptyCollection()]
            [object[]] $Adapter = @()
        )

        return New-HDTFakeCimProvider -Instance @{ 'Win32_NetworkAdapterConfiguration' = $Adapter }
    }
}

Describe 'Get-HDTNetworkConfiguration' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTNetworkConfiguration' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'takes an injected CIM provider, so it can run with no machine attached' {
            (Get-Command -Name 'Get-HDTNetworkConfiguration').Parameters.ContainsKey('CimProvider') | Should -BeTrue
        }

        It 'reads Win32_NetworkAdapterConfiguration and nothing else' {
            # SPIKES S14: NetTCPIP is not in a WinPE image built from the ADK, so
            # a second class - or a cmdlet - would be a class that is not there
            # on the one machine that matters.
            $cim = New-HDTTestNetworkCim
            Get-HDTNetworkConfiguration -CimProvider $cim | Out-Null

            @($cim.Operations | ForEach-Object { @($_.Arguments)[1] }) |
                Should -Be @('Win32_NetworkAdapterConfiguration')
        }
    }

    Context 'the multi-adapter machine that bit us' {

        BeforeAll {
            # THE REAL CAPTURED SHAPE OF THIS BUILD HOST: five VMware VMnets, a
            # Tailscale tunnel, three Hyper-V vEthernets and one Realtek NIC that
            # is the only thing with a route to the lab. The first IPEnabled
            # adapter in enumeration order is VMware VMnet1, with an address and
            # no gateway.
            $script:hostCim = New-HDTFakeCimProvider -FixturePath $script:fixturePath
            $script:hostNetwork = Get-HDTNetworkConfiguration -CimProvider $script:hostCim
        }

        It 'picks the adapter that has a gateway, not the first one with an address' {
            # THE ONE THAT MATTERS. VMnet1 (10.20.30.101) and VMnet4
            # (10.20.30.123) both have addresses and no route to anywhere.
            # Showing either in a deployment wizard tells a technician the
            # network is fine while the share is unreachable.
            [string] $script:hostNetwork.IPAddress | Should -BeExactly '10.20.30.105' -Because (
                'the Realtek NIC is the first IPEnabled adapter carrying a default gateway')
        }

        It 'names the adapter it chose' {
            [string] $script:hostNetwork.AdapterDescription | Should -BeExactly 'Realtek PCIe GbE Family Controller'
        }

        It 'reports the mask, gateway and DNS of that same adapter' {
            [string] $script:hostNetwork.SubnetMask | Should -BeExactly '255.255.255.0'
            [string] $script:hostNetwork.Gateway | Should -BeExactly '10.20.30.1'
            @($script:hostNetwork.DnsServer) | Should -Be @('10.20.30.2')
        }

        It 'says there is a lease' {
            [bool] $script:hostNetwork.HasLease | Should -BeTrue
        }

        It 'never reports an IPv6 address, even though the chosen adapter has nine' {
            [string] $script:hostNetwork.IPAddress | Should -Not -BeLike '*:*'
        }

        It 'answers the same way every time it is asked' {
            # Sort-Object is NOT STABLE in Windows PowerShell 5.1 and has no
            # -Stable before 6.2, so a selection that leans on sort order alone
            # is a selection that can change between two runs on one machine.
            $answer = @(1..5 | ForEach-Object {
                    [string] (Get-HDTNetworkConfiguration -CimProvider (New-HDTFakeCimProvider -FixturePath $script:fixturePath)).IPAddress
                })

            @($answer | Sort-Object -Unique).Count | Should -Be 1 -Because (
                'which adapter the wizard shows must not depend on sort order')
        }
    }

    Context 'ties, and the gateway-less lab' {

        It 'keeps enumeration order among adapters that all have gateways' {
            $cim = New-HDTTestNetworkCim -Adapter @(
                (New-HDTTestAdapter -Description 'First routed' -IPAddress @('192.168.2.108') `
                        -IPSubnet @('255.255.255.0') -DefaultIPGateway @('192.168.2.1')),
                (New-HDTTestAdapter -Description 'Second routed' -IPAddress @('192.168.99.5') `
                        -IPSubnet @('255.255.255.0') -DefaultIPGateway @('192.168.99.1')))

            [string] (Get-HDTNetworkConfiguration -CimProvider $cim).IPAddress | Should -BeExactly '192.168.2.108'
        }

        It 'still shows an address when nothing on the machine has a gateway' {
            # A genuinely gateway-less lab must see its address rather than
            # nothing: adapters without a gateway are considered last, not
            # discarded.
            $cim = New-HDTTestNetworkCim -Adapter @(
                (New-HDTTestAdapter -Description 'Isolated segment' -IPAddress @('172.30.30.50') `
                        -IPSubnet @('255.255.255.0') -DefaultIPGateway $null))

            $network = Get-HDTNetworkConfiguration -CimProvider $cim

            [bool] $network.HasLease | Should -BeTrue
            [string] $network.IPAddress | Should -BeExactly '172.30.30.50'
            [string] $network.Gateway | Should -BeExactly ''
        }

        It 'treats an empty gateway string as no gateway at all' {
            # WMI reports an absent gateway as $null, but a machine mid-release
            # can report an empty entry, and an empty string is not a route.
            $cim = New-HDTTestNetworkCim -Adapter @(
                (New-HDTTestAdapter -Description 'Blank gateway' -IPAddress @('10.9.9.9') `
                        -IPSubnet @('255.255.255.0') -DefaultIPGateway @('')),
                (New-HDTTestAdapter -Description 'Real gateway' -IPAddress @('192.168.2.108') `
                        -IPSubnet @('255.255.255.0') -DefaultIPGateway @('192.168.2.1')))

            [string] (Get-HDTNetworkConfiguration -CimProvider $cim).IPAddress | Should -BeExactly '192.168.2.108'
        }

        It 'takes the mask that belongs to the address it chose, not the first one listed' {
            # IPAddress and IPSubnet are PARALLEL ARRAYS. An adapter that lists
            # its IPv6 address first would otherwise report a prefix length -
            # '64' - in the subnet mask box.
            $cim = New-HDTTestNetworkCim -Adapter @(
                (New-HDTTestAdapter -Description 'IPv6 listed first' `
                        -IPAddress @('fe80::1', '192.168.2.108') `
                        -IPSubnet @('64', '255.255.255.0') `
                        -DefaultIPGateway @('192.168.2.1')))

            $network = Get-HDTNetworkConfiguration -CimProvider $cim

            [string] $network.IPAddress | Should -BeExactly '192.168.2.108'
            [string] $network.SubnetMask | Should -BeExactly '255.255.255.0'
        }
    }

    Context 'APIPA, which is the failure case and not a lease' {

        It 'reports no lease when the only address is 169.254.x.x' {
            # THE ISOLATED-SWITCH CASE (SPIKES S6/S14): a VM on HDT Lab gets no
            # DHCP answer and lands here. Showing 169.254.12.34 in the IP box
            # would tell a technician the opposite of the truth.
            $cim = New-HDTTestNetworkCim -Adapter @(
                (New-HDTTestAdapter -Description 'Hyper-V Network Adapter' -IPAddress @('169.254.12.34', 'fe80::1') `
                        -IPSubnet @('255.255.0.0', '64') -DefaultIPGateway $null))

            $network = Get-HDTNetworkConfiguration -CimProvider $cim

            [bool] $network.HasLease | Should -BeFalse -Because 'APIPA means DHCP did not answer'
            [string] $network.IPAddress | Should -BeExactly ''
            [string] $network.SubnetMask | Should -BeExactly ''
            [string] $network.AdapterDescription | Should -BeExactly ''
        }

        It 'prefers a real lease over an APIPA adapter that carries a gateway' {
            $cim = New-HDTTestNetworkCim -Adapter @(
                (New-HDTTestAdapter -Description 'APIPA with a stale gateway' -IPAddress @('169.254.12.34') `
                        -IPSubnet @('255.255.0.0') -DefaultIPGateway @('169.254.0.1')),
                (New-HDTTestAdapter -Description 'Hyper-V Network Adapter' -IPAddress @('192.168.2.118') `
                        -IPSubnet @('255.255.255.0') -DefaultIPGateway @('192.168.2.1')))

            [string] (Get-HDTNetworkConfiguration -CimProvider $cim).IPAddress | Should -BeExactly '192.168.2.118'
        }

        It 'ignores loopback' {
            $cim = New-HDTTestNetworkCim -Adapter @(
                (New-HDTTestAdapter -Description 'Loopback' -IPAddress @('127.0.0.1') `
                        -IPSubnet @('255.0.0.0') -DefaultIPGateway $null))

            [bool] (Get-HDTNetworkConfiguration -CimProvider $cim).HasLease | Should -BeFalse
        }
    }

    Context 'a machine with nothing' {

        It 'answers honestly rather than throwing when there is no adapter at all' {
            # A NETWORK READ IS DIAGNOSIS, NOT A PRECONDITION. Nothing here may
            # be the reason the Welcome screen fails to open.
            $network = $null
            { $script:noAdapter = Get-HDTNetworkConfiguration -CimProvider (New-HDTTestNetworkCim) } | Should -Not -Throw
            $network = $script:noAdapter

            [bool] $network.HasLease | Should -BeFalse
            [string] $network.IPAddress | Should -BeExactly ''
            @($network.DnsServer) | Should -BeNullOrEmpty
            [string] $network.DnsServerText | Should -BeExactly ''
        }

        It 'ignores adapters that are not IP enabled' {
            $cim = New-HDTTestNetworkCim -Adapter @(
                (New-HDTTestAdapter -Description 'WAN Miniport (PPTP)' -IPEnabled $false -IPAddress $null `
                        -IPSubnet $null -DefaultIPGateway $null))

            [bool] (Get-HDTNetworkConfiguration -CimProvider $cim).HasLease | Should -BeFalse
        }
    }

    Context 'what the pane puts on screen' {

        It 'joins multiple DNS servers with a comma, matching the hint under the box' {
            # HDTWelcome.xaml says "Separate multiple DNS servers with a comma",
            # so what is shown must be re-typeable in the same format.
            $cim = New-HDTTestNetworkCim -Adapter @(
                (New-HDTTestAdapter -Description 'Hyper-V Network Adapter' -IPAddress @('192.168.2.118') `
                        -IPSubnet @('255.255.255.0') -DefaultIPGateway @('192.168.2.1') `
                        -DNSServerSearchOrder @('192.168.2.1', '1.1.1.1')))

            $network = Get-HDTNetworkConfiguration -CimProvider $cim

            [string] $network.DnsServerText | Should -BeExactly '192.168.2.1, 1.1.1.1'
            @($network.DnsServer) | Should -Be @('192.168.2.1', '1.1.1.1')
        }

        It 'returns an empty DNS list rather than a null when the adapter has none' {
            $cim = New-HDTTestNetworkCim -Adapter @(
                (New-HDTTestAdapter -Description 'Hyper-V Network Adapter' -IPAddress @('192.168.2.118') `
                        -IPSubnet @('255.255.255.0') -DefaultIPGateway @('192.168.2.1') `
                        -DNSServerSearchOrder $null))

            @((Get-HDTNetworkConfiguration -CimProvider $cim).DnsServer).Count | Should -Be 0
        }
    }
}
