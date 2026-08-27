# PnP match: which drivers in the store are for the machine actually standing
# there, and in what order.
#
# WINDOWS HAS ALREADY DONE THE HARD HALF. A device's HardwareID array arrives
# ordered most specific first - VEN+DEV+SUBSYS+REV, then VEN+DEV+SUBSYS, then
# the class codes - and CompatibleID is the generic tail behind it. So
# specificity is not a score this has to invent by counting ampersands; it is
# the INDEX at which a driver matched. Lower is better, and every CompatibleID
# ranks behind every HardwareID.
#
# WHAT IS LEFT IS THE TIE-BREAK, which is where a wrong answer is expensive: two
# drivers claiming the same id, and the machine gets the older one. Version then
# date, both descending.
#
# A DISABLED DRIVER IS NOT A CANDIDATE. Control\driver-state.yaml is how an
# administrator withdraws a driver that bricks a model without deleting the pack
# it came in, and a match that ignored it would silently reinstate it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # The captured shape, so a rank is computed over ids a real machine
    # published rather than ones convenient to rank.
    #
    # THROUGH A VARIABLE, NOT @(...) - helpers README F12. Under 5.1
    # ConvertFrom-Json writes a top-level array to the pipeline without
    # enumerating it, so @(...) is ONE element holding all 32 devices; the
    # WAN Miniport count came back 1 and read like a filter bug.
    $script:deviceText = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'tests\fixtures\cim\Win32_PnPEntity.json'))
    $script:device = ConvertFrom-Json -InputObject $script:deviceText

    function New-HDTTestDriver {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true)] [string] $Name,
            [Parameter(Mandatory = $true)] [string[]] $HardwareId,
            [Parameter()] [string] $Version = '1.0.0.0',
            [Parameter()] [string] $Date = '01/01/2024',
            [Parameter()] [bool] $Enabled = $true,
            [Parameter()] [string] $Class = 'Net'
        )

        return [pscustomobject] @{
            Name       = $Name
            InfName    = $Name
            Path       = 'Drivers\Win11\Dell\{0}' -f $Name
            FullPath   = 'C:\HDTLab\Share\Drivers\Win11\Dell\{0}' -f $Name
            Class      = $Class
            Provider   = 'Fixture'
            Version    = $Version
            Date       = $Date
            HardwareId = [string[]] $HardwareId
            Enabled    = $Enabled
        }
    }

    # The Realtek GbE off the captured laptop - a real four-deep id ladder.
    $script:nic = @($script:device | Where-Object { $_.Name -eq 'Realtek PCIe GbE Family Controller' })[0]
}

Describe 'Get-HDTDriverMatch' {

    Context 'specificity' {

        It 'ranks a driver matching the most specific id above one matching a later id' {
            $specific = New-HDTTestDriver -Name 'specific.inf' -HardwareId @($script:nic.HardwareID[0])
            $general = New-HDTTestDriver -Name 'general.inf' -HardwareId @($script:nic.HardwareID[-1])

            $match = @(Get-HDTDriverMatch -Device @($script:nic) -Driver @($general, $specific))

            $match.Count | Should -Be 2
            $match[0].Driver.InfName | Should -Be 'specific.inf'
            $match[0].Rank | Should -BeLessThan $match[1].Rank
        }

        It 'ranks every HardwareID match above every CompatibleID match' {
            $nvme = @($script:device | Where-Object { $_.Name -eq 'Standard NVM Express Controller' })[0]

            $hardware = New-HDTTestDriver -Name 'hardware.inf' -HardwareId @($nvme.HardwareID[-1]) -Class 'SCSIAdapter'
            $compatible = New-HDTTestDriver -Name 'compatible.inf' -HardwareId @($nvme.CompatibleID[0]) -Class 'SCSIAdapter'

            $match = @(Get-HDTDriverMatch -Device @($nvme) -Driver @($compatible, $hardware))

            $match[0].Driver.InfName | Should -Be 'hardware.inf'
            $match[0].Source | Should -Be 'HardwareID'
            $match[1].Source | Should -Be 'CompatibleID'
        }

        It 'matches without regard to case' {
            $lower = New-HDTTestDriver -Name 'lower.inf' -HardwareId @($script:nic.HardwareID[0].ToLowerInvariant())

            @(Get-HDTDriverMatch -Device @($script:nic) -Driver @($lower)).Count | Should -Be 1
        }
    }

    Context 'the tie-break' {

        It 'prefers the higher version when two drivers match the same id' {
            $old = New-HDTTestDriver -Name 'old.inf' -HardwareId @($script:nic.HardwareID[0]) -Version '10.2.0.1'
            $new = New-HDTTestDriver -Name 'new.inf' -HardwareId @($script:nic.HardwareID[0]) -Version '10.10.0.1'

            $match = @(Get-HDTDriverMatch -Device @($script:nic) -Driver @($old, $new))

            # AND 10.10 IS NEWER THAN 10.2, which a string comparison gets
            # backwards - the reason a driver version is compared as a version.
            $match[0].Driver.InfName | Should -Be 'new.inf'
        }

        It 'prefers the newer date when version ties' {
            $old = New-HDTTestDriver -Name 'old.inf' -HardwareId @($script:nic.HardwareID[0]) -Date '01/04/2023'
            $new = New-HDTTestDriver -Name 'new.inf' -HardwareId @($script:nic.HardwareID[0]) -Date '06/11/2025'

            $match = @(Get-HDTDriverMatch -Device @($script:nic) -Driver @($old, $new))

            $match[0].Driver.InfName | Should -Be 'new.inf'
        }
    }

    Context 'what is not a candidate' {

        It 'never returns a driver that is turned off' {
            $off = New-HDTTestDriver -Name 'off.inf' -HardwareId @($script:nic.HardwareID[0]) -Enabled $false

            @(Get-HDTDriverMatch -Device @($script:nic) -Driver @($off)).Count | Should -Be 0
        }

        It 'answers nothing rather than throwing when no driver matches' {
            $other = New-HDTTestDriver -Name 'other.inf' -HardwareId @('PCI\VEN_DEAD&DEV_BEEF')

            $match = @(Get-HDTDriverMatch -Device @($script:nic) -Driver @($other))

            $match.Count | Should -Be 0
        }

        It 'answers nothing for a store with no drivers in it at all' {
            @(Get-HDTDriverMatch -Device @($script:nic) -Driver @()).Count | Should -Be 0
        }

        It 'leaves the virtual adapters on this host unmatched by a physical driver' {
            # THE CASE A FLEET ACTUALLY HITS. This laptop publishes eleven
            # virtual NICs - Hyper-V, VMware, Tailscale, WAN miniports - and a
            # match that chased them would inject a physical NIC driver against
            # a switch extension.
            $virtual = @($script:device | Where-Object { $_.Name -like 'Hyper-V Virtual*' })
            $physical = New-HDTTestDriver -Name 'realtek.inf' -HardwareId @($script:nic.HardwareID[0])

            @(Get-HDTDriverMatch -Device $virtual -Driver @($physical)).Count | Should -Be 0
        }
    }

    Context 'the set it hands the step' {

        It 'reports one row per driver when it serves more than one device' {
            $shared = @($script:device | Where-Object { $_.Name -like 'WAN Miniport*' })
            $shared.Count | Should -BeGreaterThan 1

            $driver = New-HDTTestDriver -Name 'wan.inf' -HardwareId @($shared[0].HardwareID[0], $shared[1].HardwareID[0])

            # ONE ROW, NOT ONE PER DEVICE. What the step needs is the SET of
            # .inf files to inject; a driver listed twice is injected twice.
            @(Get-HDTDriverMatch -Device $shared -Driver @($driver)).Count | Should -Be 1
        }
    }
}
