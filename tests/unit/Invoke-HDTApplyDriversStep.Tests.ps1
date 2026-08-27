# ApplyDrivers: MDT's Inject Drivers step, group match first and PnP behind it.
#
# THE DECISION HAS TO BE IN THE LOG. Not the outcome - the decision. Which group
# was resolved, whether it was there, whether that is why it fell back, how many
# devices the machine reported, and for every driver injected: the id it matched,
# at what rank, off HardwareID or CompatibleID. A deployment whose network card
# does not work at 3 a.m. is diagnosed from this log or it is diagnosed by
# reproducing the whole deployment, and MDT learned that lesson in ZTIDrivers.log
# a long time ago.
#
# GROUP MATCH IS PRIMARY AND STAYS MDT'S. A rule builds HDTDriverGroup out of
# make and model - Win11\%HDTMake%\%HDTModel% - the folder is injected whole, and
# the PnP ranking is never consulted. The fallback is for the model no rule knew
# about.
#
# THE IDS HERE ARE REAL. They are the Realtek GbE off the captured
# Win32_PnPEntity fixture, so a match asserted here is a match against ids a real
# machine actually published.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = 'Z:\Deploy'
    $script:groupPath = 'Z:\Deploy\Drivers\Win11\Dell inc\Dell Pro 3 16 P316265'

    # Through a variable, never @(ConvertFrom-Json ...) - helpers README F12.
    $script:deviceText = [System.IO.File]::ReadAllText(
        (Join-Path -Path $script:repoRoot -ChildPath 'tests\fixtures\cim\Win32_PnPEntity.json'))
    $script:captured = ConvertFrom-Json -InputObject $script:deviceText

    # A minimal .inf claiming the captured Realtek's most specific id.
    $script:matchingInf = @'
[version]
Signature   = "$Windows NT$"
Class       = Net
ClassGUID   = {4d36e972-e325-11ce-bfc1-08002be10318}
Provider    = %Realtek%
DriverVer   = 11/28/2024,10.74.1128.2024

[Manufacturer]
%Realtek% = Realtek, NTamd64.10.0

[Realtek.NTamd64.10.0]
%RTL8168.DeviceDesc% = RTL8168.ndi, PCI\VEN_10EC&DEV_8168&SUBSYS_393917AA&REV_15

[Strings]
Realtek = "Realtek"
RTL8168.DeviceDesc = "Realtek PCIe GbE Family Controller"
'@

    # A driver for a device this machine has not got.
    $script:otherInf = $script:matchingInf -replace 'PCI\\VEN_10EC&DEV_8168&SUBSYS_393917AA&REV_15', 'PCI\VEN_DEAD&DEV_BEEF'

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 5; Name = 'Inject Drivers'; Type = 'ApplyDrivers'; TimeoutMinutes = 30; Log = $null; Property = $bag
        }
    }
}

Describe 'Invoke-HDTApplyDriversStep' {

    BeforeEach {
        $script:file = @{
            ('{0}\net-realtek.inf' -f $script:groupPath)     = $script:matchingInf
            ('{0}\net-other.inf' -f $script:groupPath)       = $script:otherInf

            # A SECOND FOLDER HOLDING ONLY A DRIVER THIS MACHINE DOES NOT WANT,
            # so a selection profile scoped to it can be shown to exclude the
            # one that DOES match - which a single-folder store cannot show.
            'Z:\Deploy\Drivers\Win11\Acme\Elsewhere\net-elsewhere.inf' = $script:otherInf

            'Z:\Deploy\Control\selection-profiles.yaml' = @(
                'schemaVersion: 1'
                'profiles:'
                '  - id: dell-only'
                '    name: The Dell pack'
                '    include:'
                '      - Drivers\Win11\Dell inc\Dell Pro 3 16 P316265'
                '  - id: elsewhere-only'
                '    name: Somewhere with nothing this machine needs'
                '    include:'
                '      - Drivers\Win11\Acme\Elsewhere'
                '  - id: absent'
                '    name: Points at a folder nobody created'
                '    include:'
                '      - Drivers\Win11\Nobody\Here'
            ) -join "`r`n"
        }

        $script:fileSystem = New-HDTFakeFileSystem -File $script:file
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 27, 9, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 250
        $script:image = New-HDTFakeImageService -Driver @(
            [pscustomobject] @{ Inf = 'oem12.inf'; Provider = 'Realtek'; Version = '10.74.1128.2024'; Date = '11/28/2024' })
        $script:cim = New-HDTFakeCimProvider -Instance @{ Win32_PnPEntity = [object[]] @($script:captured) }

        $script:newContext = {
            param([System.Collections.IDictionary] $Variable)

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Image $script:image -Cim $script:cim

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTMake'] = 'Dell inc'
            $live['HDTModel'] = 'Dell Pro 3 16 P316265'
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:workspaceRoot `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:context = & $script:newContext $null

        $script:record = {
            param([string] $Event)

            return @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event $Event)
        }
    }

    Context 'group match, which is the primary path' {

        It 'injects the group folder whole' {
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $result.Status | Should -Be 'Completed'

            $call = @($script:image.Operations | Where-Object { $_.Operation -eq 'AddDriver' })
            $call.Count | Should -Be 1
            $call[0].Arguments[0] | Should -Be 'W:\'
            $call[0].Arguments[1] | Should -Be $script:groupPath
            $call[0].Arguments[2] | Should -BeTrue
        }

        It 'expands the make and model a rule put in the group path' {
            # THE WHOLE OF MDT'S TOTAL CONTROL METHOD. The path is authored once
            # with variables in it and resolves per machine; nothing here knows
            # or imposes a Make\Model shape.
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            @(& $script:record 'driver.group')[0].data.group | Should -Be $script:groupPath
        }

        It 'never consults the PnP ranking when the group resolved' {
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            @(& $script:record 'driver.fallback').Count | Should -Be 0
        }
    }

    Context 'the fallback' {

        It 'falls back to PnP when the group folder is not on the share' {
            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $result.Status | Should -Be 'Completed'
            @(& $script:record 'driver.fallback').Count | Should -Be 1
        }

        It 'says in the log that the group was missing, not merely that it fell back' {
            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $group = @(& $script:record 'driver.group')[0]

            $group.data.found | Should -BeFalse
            $group.data.group | Should -Match 'Nonesuch'
        }

        It 'injects only the drivers that matched' {
            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $call = @($script:image.Operations | Where-Object { $_.Operation -eq 'AddDriver' })

            # net-realtek.inf matched the captured Realtek; net-other.inf claims
            # a device this machine has not got.
            $call.Count | Should -Be 1
            $call[0].Arguments[1] | Should -Match 'net-realtek\.inf$'
        }
    }

    Context 'the selection profile, which scopes the fallback' {

        It 'considers only the folders the profile includes' {
            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch'; profile = 'elsewhere-only' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            # The Realtek driver is on the share and matches this machine, but it
            # is not in the profile, so it is not a candidate.
            $result.Status | Should -Be 'Completed'
            [int] $result.Data['matched'] | Should -Be 0
            @($script:image.Operations | Where-Object { $_.Operation -eq 'AddDriver' }).Count | Should -Be 0
        }

        It 'still finds the match when the profile includes the folder holding it' {
            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch'; profile = 'dell-only' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            [int] $result.Data['matched'] | Should -Be 1
        }

        It 'ignores a profile whose folders are not on the share, rather than obeying it' {
            # AN EMPTY SCOPE MATCHES NOTHING AND LOOKS LIKE SUCCESS. A profile
            # naming a folder nobody created would otherwise silently turn the
            # fallback off - a deployment that injects no drivers and reports
            # a completed step, which is the exact failure this whole feature
            # exists to remove.
            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch'; profile = 'absent' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            [int] $result.Data['matched'] | Should -Be 1
        }
    }

    Context 'the decision, in the log' {

        It 'records how many devices the machine reported' {
            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            [int] @(& $script:record 'driver.enumerate')[0].data.deviceCount | Should -Be @($script:captured).Count
        }

        It 'records the id, rank and source behind every driver it chose' {
            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $match = @(& $script:record 'driver.match')

            $match.Count | Should -Be 1
            $match[0].data.inf | Should -Match 'net-realtek\.inf$'
            $match[0].data.matchedId | Should -Be 'PCI\VEN_10EC&DEV_8168&SUBSYS_393917AA&REV_15'
            [int] $match[0].data.rank | Should -Be 0
            $match[0].data.source | Should -Be 'HardwareID'
            $match[0].data.deviceName | Should -Be 'Realtek PCIe GbE Family Controller'
        }

        It 'records what DISM reported back, not merely what was asked of it' {
            # The step asked for one .inf; Add-WindowsDriver answers with the
            # published name it got - oem12.inf - and that is the name on the
            # machine afterwards. A log carrying only the request cannot be
            # matched against the installed driver store later.
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            @(& $script:record 'driver.injected')[0].data.inf | Should -Be 'oem12.inf'
        }
    }

    Context 'when it cannot' {

        It 'refuses rather than guessing a volume to inject into' {
            $context = & $script:newContext ([ordered] @{ HDTOSVolume = '' })
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $context

            $result.Status | Should -Be 'Failed'
            $result.Message | Should -Match 'HDTOSVolume'
            @($script:image.Operations | Where-Object { $_.Operation -eq 'AddDriver' }).Count | Should -Be 0
        }

        It 'completes with nothing injected when no driver matches at all' {
            # A MACHINE WITH INBOX DRIVERS STILL BOOTS, and MDT continues here
            # too. It is a warning with a count, not a failed deployment.
            $empty = New-HDTFakeFileSystem -File @{}
            $catalog = New-HDTServiceCatalog -FileSystem $empty -Clock $script:clock `
                -Image $script:image -Cim $script:cim
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $empty -Clock $script:clock -Level Debug
            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:workspaceRoot `
                -Variable $live -Service $catalog -Log $log

            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $context

            $result.Status | Should -Be 'Completed'
            [int] $result.Data['injected'] | Should -Be 0
        }
    }
}
