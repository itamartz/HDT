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
            # NOT $Event: it is a PowerShell automatic variable, and assigning
            # to it is a warning the analyzer raises for good reason - the
            # engine's own log writer carries a suppression for the same name
            # where it cannot rename. Here it can.
            param([string] $EventName)

            return @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event $EventName)
        }
    }

    Context 'group match, which is the primary path' {

        It 'stages the group folder whole' {
            # COPIED, NOT INJECTED. The step called Add-WindowsDriver per driver
            # until a Latitude spent 649 seconds on 82 of them - nine seconds
            # each, nearly all of it the offline image being opened and
            # committed once per package. It now copies to <OSVolume>\Drivers
            # and the answer file's DriverPaths points Windows at the result,
            # which is what MDT's ZTIDrivers does.
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $result.Status | Should -Be 'Completed'

            $script:fileSystem.TestPath('W:\Drivers\Win11\Dell inc\Dell Pro 3 16 P316265\net-realtek.inf') |
                Should -BeTrue -Because 'the package lands under the OS volume for PnP to find at first boot'
        }

        It 'calls no image service at all' {
            # THE DISM DEPENDENCY IS GONE, and this is what says so. A step that
            # still opened the offline image would still cost nine seconds a
            # driver whatever the log claimed.
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            @($script:image.Operations | Where-Object { $_.Operation -eq 'AddDriver' }).Count |
                Should -Be 0
        }

        It 'expands the make and model a rule put in the group path' {
            # THE WHOLE OF MDT'S TOTAL CONTROL METHOD. The path is authored once
            # with variables in it and resolves per machine; nothing here knows
            # or imposes a Make\Model shape.
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            @(& $script:record 'driver.group')[0].data.group | Should -Be $script:groupPath
        }

        # EVERY DELL REPORTS A MANUFACTURER ENDING IN A DOT - 'Dell Inc.' - AND
        # WINDOWS CANNOT STORE A FOLDER NAMED THAT. Create 'Dell Inc.' and the
        # file system silently gives you 'Dell Inc'. So the Total Control
        # pattern the template ships, Win11\%HDTMake%\%HDTModel%, expands to a
        # path whose middle segment cannot exist as typed.
        #
        # IT WORKS ANYWAY, and only because path normalisation strips the dot
        # before anything looks: [IO.Path]::GetFullPath('...\Dell Inc.') is
        # '...\Dell Inc'. The fake normalises through the same .NET call, so
        # tests and production agree rather than diverging - which is the part
        # worth pinning, because a future "tidy up path handling" that compared
        # strings instead would break group match for every Dell in the fleet
        # and pass every test that did not try the dot.
        It 'finds the folder when the make ends in a dot, as every Dell''s does' {
            $fs = New-HDTFakeFileSystem -File @{
                'Z:\Deploy\Drivers\Win11\Dell Inc\Latitude 5420\net.inf' = $script:matchingInf
            }

            $catalog = New-HDTServiceCatalog -FileSystem $fs -Clock $script:clock `
                -Image $script:image -Cim $script:cim
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $fs -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTMake'] = 'Dell Inc.'
            $live['HDTModel'] = 'Latitude 5420'

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot $script:workspaceRoot -Variable $live -Service $catalog -Log $log

            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $context

            # THE GROUP RESOLVED, so no fallback happened - which is the whole
            # assertion: a Dell finds its own folder.
            $result.Status | Should -Be 'Completed'
            [bool] $result.Data['groupFound'] | Should -BeTrue

            # THIS TEST'S OWN FAKE, not the outer one. It seeds its own store for
            # the Dell-with-a-dot fixture, so asserting against $script:fileSystem
            # asks a file system that never saw this deployment about a path from
            # a different test - which is false for a reason that has nothing to
            # do with the dot this test exists for.
            $fs.TestPath('W:\Drivers\Win11\Dell Inc\Latitude 5420\net.inf') |
                Should -BeTrue -Because 'a Dell whose make ends in a dot still finds its own folder and stages it'
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

        It 'stages only the packages that matched' {
            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            # net-realtek.inf matched the captured Realtek; net-other.inf claims
            # a device this machine has not got. Both live in the SAME folder,
            # so the package is copied once and carries both - which is what a
            # driver folder is, and why the count is packages rather than infs.
            [int] $result.Data['staged'] | Should -Be 1

            $script:fileSystem.TestPath('W:\Drivers\Win11\Dell inc\Dell Pro 3 16 P316265\net-realtek.inf') | Should -BeTrue
            $script:fileSystem.TestPath('W:\Drivers\Win11\Acme\Elsewhere\net-elsewhere.inf') |
                Should -BeFalse -Because 'nothing in that folder matched this machine'
        }

        # TWO MATCHES IN ONE FOLDER ARE ONE COPY, and the count says packages.
        #
        # This assertion used to be about DISM: Add-WindowsDriver answers with
        # the drivers in the IMAGE rather than the one just added, so every call
        # after the first re-reported what was already in, and on LT-7FJ45S2 on
        # 2026-08-28 that turned 53 matched packages into 'injected 82
        # driver(s)'. Copying has the same hazard from the other end - two .inf
        # files in one folder are one package - so the dedupe moved rather than
        # disappeared, and this is what holds it.
        It 'copies a folder holding two matches only once' {
            $script:fileSystem.SeedFile(('{0}\net-realtek-too.inf' -f $script:groupPath), $script:matchingInf)

            $context = & $script:newContext $null
            $step = & $script:newStep @{ group = 'Win11\Acme\Nonesuch' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $context

            [int] $result.Data['staged'] | Should -Be 1
            @(& $script:record 'driver.staged').Count | Should -Be 1
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

        It 'records where the package landed and how much of it went' {
            # WHERE, NOT JUST WHETHER. This used to assert the published name
            # DISM answered with - oem12.inf - which was the right question when
            # the step injected. Now the machine has a folder, and the two facts
            # a technician needs from the log are where it is and whether
            # anything actually arrived in it: a package logged as staged with
            # zero files is one Windows will never install.
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $staged = @(& $script:record 'driver.staged')

            $staged.Count | Should -BeGreaterThan 0
            [string] $staged[0].data.target | Should -Match 'W:\\Drivers'
            [int] $staged[0].data.fileCount | Should -BeGreaterThan 0
        }
    }

    Context 'the log a technician actually reads' {

        BeforeEach {
            $script:groupStep = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }
        }

        It 'says both what the rule produced and where it resolved to, in one line' {
            # IT TOOK TWO LINES TO SAY THIS AND NEITHER SAID THE HALF THAT
            # MATTERS. The step logged the full resolved path and then, a moment
            # later, "staged <leaf> to <target>" - while the value the rule
            # actually produced sat in the data payload and appeared nowhere in
            # the text. "What did my rule expand to?" is the only question worth
            # asking when the folder is missing.
            $null = Invoke-HDTApplyDriversStep -Step $script:groupStep -Context $script:context

            $group = @(& $script:record 'driver.group' | Where-Object { $_.level -eq 'Info' })

            $group[0].message | Should -Match 'Win11\\Dell inc\\Dell Pro 3 16 P316265'
            $group[0].message | Should -Match 'Z:\\Deploy\\Drivers'
            $group[0].data.written | Should -Be 'Win11\Dell inc\Dell Pro 3 16 P316265'
        }

        It 'warns in words when the group folder is not on the share' {
            # `found:false` IN A DATA PAYLOAD IS INVISIBLE TO A PERSON, and this
            # is the single most important line in the file when it happens. It
            # was Info - the same severity as success - so a log filtered to
            # problems showed nothing at all for the case that produces a machine
            # with no network card.
            $step = & $script:newStep @{ group = 'Win11\Dell inc\Latitude 9999' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $warned = @(& $script:record 'driver.group' | Where-Object { $_.level -eq 'Warning' })

            $warned.Count | Should -BeGreaterThan 0
            $warned[0].message | Should -Match 'Latitude 9999'
            $warned[0].message | Should -Match 'not found under'
        }

        It 'counts the .inf files, not only the files' {
            # 1302 FILES IS .sys, .cat, .dll AND THE VENDOR'S RELEASE NOTES. The
            # Latitude 5490 pack is 126 .inf files inside those 1302, and 126 is
            # the number that maps to devices.
            $null = Invoke-HDTApplyDriversStep -Step $script:groupStep -Context $script:context

            $staged = @(& $script:record 'driver.staged')

            [int] $staged[0].data.infCount | Should -Be 2
            [long] $staged[0].data.byteCount | Should -BeGreaterThan 0
            $staged[0].message | Should -Match '\.inf'
        }

        It 'reports progress while it copies, which the group path never did' {
            # 48 SECONDS OF SILENCE ON A REAL DEPLOYMENT. Only the PnP fallback
            # reported progress, and the fallback almost never runs - so the
            # path nearly every deployment takes copied a folder whole and said
            # nothing until it was finished. Worse than a still bar: the progress
            # card's elapsed clock comes from the first and last record in the
            # log, so silence stops the clock for the whole deployment.
            $null = Invoke-HDTApplyDriversStep -Step $script:groupStep -Context $script:context

            $progress = @(& $script:record 'step.progress')

            $progress.Count | Should -BeGreaterThan 0
            [int] $progress[-1].data.percent | Should -Be 100
            $progress[0].data.package | Should -Not -BeNullOrEmpty
            [int] $progress[0].data.total | Should -BeGreaterThan 0
        }

        It 'never reports a percent above a hundred' {
            $null = Invoke-HDTApplyDriversStep -Step $script:groupStep -Context $script:context

            @(& $script:record 'step.progress' | Where-Object { [int] $_.data.percent -gt 100 }) |
                Should -HaveCount 0
        }

        It 'names what installs the drivers, rather than stopping at "staged"' {
            # THE LOG USED TO END AT "staged", WHICH LEFT NO THREAD TO PULL.
            # Staging only copies; the answer file's DriverPaths is what installs
            # them - and that is exactly what was broken here until the step
            # order changed.
            $null = Invoke-HDTApplyDriversStep -Step $script:groupStep -Context $script:context

            $done = @(& $script:record 'native.exec')

            $done[0].message | Should -Match 'offlineServicing'
            $done[0].message | Should -Match 'DriverPaths'
        }
    }

    Context 'the payload, which said two things that were not true' {

        It 'calls the count staged rather than injected' {
            # NOTHING IS INJECTED ANY MORE. The message beside it says "staged N
            # driver package(s)" while the payload called the same number
            # injected, which is what this step did through DISM until the
            # per-driver commit cost eleven minutes on a Latitude.
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $result.Data.Contains('staged') | Should -BeTrue
            $result.Data.Contains('injected') | Should -BeFalse
        }

        It 'omits matched entirely on the group path, where nothing is ever ranked' {
            # IT WAS PERMANENTLY 0 THERE, sitting beside a successful staging.
            # An administrator reading it concluded their hardware matched none
            # of the drivers they had just shipped, and went debugging a problem
            # that did not exist. A number that is only ever zero is not a
            # measurement.
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $result.Data.Contains('matched') | Should -BeFalse
        }

        It 'keeps matched on the fallback path, where it is a real count' {
            # THE FIX IS NOT TO DELETE THE NUMBER. When the PnP ranking actually
            # runs, how many drivers matched is the whole story of the step.
            $step = & $script:newStep @{ group = 'Win11\Dell inc\Latitude 9999' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $result.Data.Contains('matched') | Should -BeTrue
            [int] $result.Data['matched'] | Should -BeGreaterThan 0
        }

        It 'carries the .inf and byte counts it now reports' {
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            [int] $result.Data['infCount'] | Should -Be 2
            [long] $result.Data['byteCount'] | Should -BeGreaterThan 0
        }

        It 'keeps the rule''s raw value beside the resolved path' {
            # Provenance done properly, and no other step here has an equivalent.
            $step = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }

            $result = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            $result.Data['written'] | Should -Be 'Win11\Dell inc\Dell Pro 3 16 P316265'
            [string] $result.Data['group'] | Should -Match 'Z:\\Deploy\\Drivers'
        }
    }

    Context 'whether the pack was the right one for this machine' {

        # THE GROUP PATH COPIES A FOLDER WHOLE BECAUSE SOMEBODY'S RULE NAMED IT,
        # and until now nothing ever checked that folder against the machine in
        # front of it. A pack for the wrong model stages just as successfully as
        # the right one.
        #
        # AND THE FRAMING IS THE POINT. "118 devices, 112 not covered" is true
        # and useless - most devices are served by Windows in-box drivers, so
        # that number is both normal and alarming, and an administrator who reads
        # it twice learns to ignore the line.

        BeforeEach {
            $script:groupStep = & $script:newStep @{ group = 'Win11\%HDTMake%\%HDTModel%' }
        }

        It 'says how many staged .inf files are relevant to this machine' {
            $null = Invoke-HDTApplyDriversStep -Step $script:groupStep -Context $script:context

            $report = @(& $script:record 'driver.match' | Where-Object { $null -ne $_.data.PSObject.Properties['relevant'] })

            $report.Count | Should -Be 1
            [int] $report[0].data.staged | Should -Be 2
            [int] $report[0].data.relevant | Should -Be 1
        }

        It 'words it so it cannot be read as a prediction of failure' {
            # A CONFIDENT FALSE NEGATIVE SENDS AN ADMINISTRATOR HUNTING A DRIVER
            # THEY DO NOT NEED. This does not rank drivers, read signatures,
            # dates or versions, and knows nothing about the in-box drivers in
            # the image being applied - which are what serve most of these
            # devices. The log has to say so.
            $null = Invoke-HDTApplyDriversStep -Step $script:groupStep -Context $script:context

            $report = @(& $script:record 'driver.match' | Where-Object { $null -ne $_.data.PSObject.Properties['relevant'] })

            $report[0].message | Should -Match 'in-box'
            $report[0].message | Should -Match 'not a prediction'
        }

        It 'names the devices that would strand a machine and have nothing staged' {
            $null = Invoke-HDTApplyDriversStep -Step $script:groupStep -Context $script:context

            $warned = @(& $script:record 'driver.match' |
                    Where-Object { $_.level -eq 'Warning' -and $null -ne $_.data.PSObject.Properties['unmatched'] })

            $warned.Count | Should -Be 1
            [int] $warned[0].data.unmatched | Should -BeGreaterThan 0
            $warned[0].message | Should -Match 'may still serve'
        }

        It 'does not run the report on the fallback path, where it would say nothing' {
            # The fallback CHOSE its packages by matching them against this
            # machine, so every .inf it staged is relevant by construction - and
            # a report restating that would double the driver.match records the
            # fallback has already written.
            $step = & $script:newStep @{ group = 'Win11\Dell inc\Latitude 9999' }

            $null = Invoke-HDTApplyDriversStep -Step $step -Context $script:context

            @(& $script:record 'driver.match' | Where-Object { $null -ne $_.data.PSObject.Properties['relevant'] }) |
                Should -HaveCount 0
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
            [int] $result.Data['staged'] | Should -Be 0
        }
    }
}
