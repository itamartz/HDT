function Invoke-HDTApplyDriversStep {
    <#
        .SYNOPSIS
            Stages drivers onto the applied operating system.

        .DESCRIPTION
            Copies matched driver packages onto an operating system already
            applied to disk, for Windows to install at first boot.
            Group match is the primary path and the PnP ranking is the fallback,
            which is the order DESIGN 7 keeps.

            THE GROUP IS A PATH AN ADMINISTRATOR WROTE, NOT A SHAPE HDT IMPOSES.
            A rule sets HDTDriverGroup - 'Win11\%HDTMake%\%HDTModel%' is the
            Total Control layout, and the one New-HDTWorkspace seeds as a
            comment - and this expands it against the live variables. Any
            depth, any folder names. Nothing here discovers, requires or
            creates a Make\Model tree; the store under Drivers\ is whatever
            the administrator built.

            WHEN THE GROUP RESOLVES, THE FOLDER GOES IN WHOLE and the ranking is
            never consulted. That is the point of Total Control: somebody has
            already decided what this model gets, and a ranking that second-
            guessed them would be a worse answer arrived at more slowly.

            THE FALLBACK IS FOR THE MODEL NOBODY WROTE A RULE FOR. It asks the
            machine what it has, ranks the store against those ids, and injects
            the matches. Without it an unrecognised model deploys with whatever
            was inbox in the image - which for a machine needing an OEM NIC or
            storage driver means a computer that cannot see its network or its
            disk.

            THE PACKAGES ARE COPIED TO THE MACHINE, NOT INJECTED INTO IT. Each
            matched folder is copied to <OSVolume>\Drivers and the answer file's
            DriverPaths points Windows at it, so PnP installs what it needs on
            the first boot - which is what MDT's ZTIDrivers has always done.

            IT USED TO CALL Add-WindowsDriver ONCE PER DRIVER, and every one of
            those opens the offline image, adds one package and COMMITS it. On a
            Latitude 5490 that was 82 drivers in 649 seconds, a median of nine
            seconds each, almost all of it the servicing session rather than the
            driver - eleven minutes a technician watched as the same dismount
            running over and over. A file copy of the same packages is seconds.

            The step still runs AFTER ApplyImage and BEFORE the first reboot:
            the volume has to exist to copy onto, and the answer file has to be
            staged before Windows reads it.

            EVERY DECISION GOES IN THE LOG, AND THAT IS A REQUIREMENT RATHER
            THAN A COURTESY. The group that was resolved and whether it existed;
            that a fallback happened AND that a missing folder is why; how many
            devices the machine reported; per driver the id it matched, at what
            rank, off HardwareID or CompatibleID, and which device earned it;
            and what DISM said came back, which is the name the driver has on
            the machine afterwards. A deployment whose network card does not
            work is diagnosed from this log or it is diagnosed by rebuilding the
            whole deployment.

            NOTHING MATCHING IS NOT A FAILED DEPLOYMENT. A machine with inbox
            drivers still boots, so the step completes with a count of zero and
            says so loudly.

        .PARAMETER Step
            The step, with its type-specific properties: group, profile, mode
            and target.

        .PARAMETER Context
            The execution context, carrying the services and the live variables.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            A New-HDTStepResult. Data carries group, written, groupFound, mode,
            target, staged, infCount, byteCount and durationMs - and `matched`
            ONLY when the PnP ranking actually ran, or errorId on a refusal.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock `
                -Image (New-HDTImageService) -Cim (New-HDTCimProvider)
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{ HDTOSVolume = 'W' }) `
                -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-M4\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ApplyDrivers' })[0]

            Invoke-HDTApplyDriversStep -Step $step -Context $context

            Runs one step out of a real sequence. Building the context is what the
            engine does before the first step; a step cannot be run without one.

        .EXAMPLE
            $result = Invoke-HDTApplyDriversStep -Step $step -Context $context
            $result.Data['staged']
            $result.Data['infCount']

            How many packages went onto the machine, and how many .inf files came
            with them. The .inf count is the one that maps to devices: the
            Latitude 5490 pack is 126 .inf files inside 1302 files, and a step
            reporting only the 1302 is reporting .sys, .cat, .dll and the
            vendor's release notes.

            `staged` BEING ZERO IS A COMPLETED STEP THAT DEPLOYED NOTHING, which
            is why it is a warning in the log rather than a silent success.

        .EXAMPLE
            $result = Invoke-HDTApplyDriversStep -Step $step -Context $context
            $result.Data.Contains('matched')

            WHETHER THE PnP RANKING WAS CONSULTED AT ALL. It is absent on the
            group path, because that path never ranks anything - it copies the
            folder somebody nominated. The key used to be present and permanently
            0 there, which read as "none of your drivers match this machine" on
            every successful deployment.

        .LINK
            Get-HDTDriverMatch

        .LINK
            Get-HDTPresentDevice
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Context
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $fail = {
        param([string] $Message, [string] $ErrorId)

        $data = [ordered] @{}
        if (-not [string]::IsNullOrWhiteSpace($ErrorId)) { $data['errorId'] = $ErrorId }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component 'ApplyDrivers' -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    try {
        $group = Get-HDTStepProperty -Step $Step -Name 'group' -Default '' -Context $Context -Expand -As String
        $profileName = Get-HDTStepProperty -Step $Step -Name 'profile' -Default '' -Context $Context -Expand -As String
        $mode = Get-HDTStepProperty -Step $Step -Name 'mode' -Default 'all' -Context $Context -Expand -As String
        $target = Get-HDTStepProperty -Step $Step -Name 'target' -Default 'primary' -Context $Context -Expand -As String

        # What the author wrote, unexpanded, so a refusal can name the variable
        # that was meant to fill an empty target.
        $targetWritten = Get-HDTStepProperty -Step $Step -Name 'target' -Default 'primary' -As String

        # THE SAME, FOR THE GROUP - '%HDTDriverGroup%' rather than what it
        # became. When the folder is not there the question is which rule built
        # that path, and the expanded value alone cannot answer it.
        $groupWritten = Get-HDTStepProperty -Step $Step -Name 'group' -Default '' -As String
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    if ($mode -notin @('all', 'matching')) {
        return (& $fail ("step '{0}': mode '{1}' is not 'all' or 'matching'. MDT's two choices are to install every driver in the selection, or only the ones that match this machine." -f
                $Step.Name, $mode) 'HDTConfigurationError')
    }

    try {
        # NO IMAGE SERVICE ANY MORE. This step copied through DISM until the
        # per-driver commit cost eleven minutes on a real machine; it now copies
        # files, so the only service it needs is the file system. Asking for one
        # it does not use would refuse a deployment for the want of something
        # nothing here touches.
        $fileSystem = $Context.Service.GetRequired('FileSystem', 'ApplyDrivers')
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    # -- where ------------------------------------------------------------

    $letter = $target

    if ($target -eq 'primary') { $letter = [string] $Context.Variable['HDTOSVolume'] }

    if ($null -eq $letter) { $letter = '' }
    $letter = $letter.Trim().TrimEnd('\').TrimEnd(':')

    if ($letter.Length -eq 0) {
        $said = "step '{0}' injects into the primary volume and HDTOSVolume is not set. The partition step publishes it; HDT will not guess a drive letter to write drivers into." -f $Step.Name

        if ($targetWritten -match '^\s*%([^%]+)%\s*$') {
            $said = "step '{0}' injects into %{1}%, which is not set. The partition step publishes it; HDT will not guess a drive letter to write drivers into." -f
                $Step.Name, [string] $Matches[1]
        }

        return (& $fail $said 'HDTConfigurationError')
    }

    if ($letter -notmatch '^[A-Za-z]$') {
        return (& $fail ("step '{0}': target '{1}' is not a drive letter." -f $Step.Name, $target) 'HDTConfigurationError')
    }

    $applyPath = '{0}:\' -f $letter.Substring(0, 1).ToUpperInvariant()

    # -- which folder -----------------------------------------------------

    $driverRoot = Get-HDTWorkspacePath -Root ([string] $Context.WorkspaceRoot) -Kind Drivers

    $groupPath = ''
    $groupFound = $false

    if (-not [string]::IsNullOrWhiteSpace($group)) {
        # [IO.Path]::Combine, not Join-Path, for the reason Get-HDTWorkspacePath
        # records: Join-Path resolves the drive qualifier, so a share on a drive
        # this process has not got - which is every share under a fake, and a
        # mapped Z: that WinPE has not connected yet - throws DriveNotFound
        # instead of composing a string.
        #
        # AND THE GROUP IS TRIMMED OF ITS LEADING SLASH, because a rooted second
        # segment makes Combine discard everything to its left: a rule that set
        # HDTDriverGroup to '\Win11\Dell' would otherwise resolve to \Win11\Dell
        # on the system drive rather than under the share.
        $groupPath = [System.IO.Path]::Combine($driverRoot, $group.TrimStart('\', '/'))
        $groupFound = [bool] $fileSystem.TestPath($groupPath)
    }

    # THE GROUP IS LOGGED WHETHER OR NOT IT RESOLVED, because "which folder did
    # it look in" is the first question asked of a deployment that got no
    # drivers, and a log that only records successes cannot answer it.
    #
    # ONE RECORD CARRYING BOTH SPELLINGS, WHICH IT USED TO TAKE TWO TO SAY. The
    # step wrote "driver group '<full resolved path>' resolved" and then, a
    # moment later, "staged <leaf> ... to <target>" - two lines saying almost the
    # same thing, and NEITHER of them showed the value the rule actually
    # produced. That value was in the data payload as `written` and nowhere in
    # the text, so a log a human reads could not answer "what did my rule
    # expand to?" - which is the only question worth asking when the folder is
    # not there.
    #
    # THE RULE'S VALUE FIRST, THE RESOLVED PATH AFTER IT. 'Win11\Dell Inc.\
    # Latitude 5490' is what somebody wrote and what they will go and edit;
    # the UNC is where it landed.
    $groupSeverity = 'Info'

    if ($groupFound) {
        $groupSaid = "driver group '{0}' resolved to {1}" -f $group, $groupPath
    } elseif (-not [string]::IsNullOrWhiteSpace($group)) {
        # THE SENTENCE THAT DID NOT EXIST. `found:false` in a data payload is
        # invisible to a person reading the log, and this is the single most
        # important line in the file when it happens: a technician standing in
        # front of a machine with no network card needs to be told, in words,
        # that the folder their rule named is not on the share.
        #
        # AND IT IS A WARNING. It was Info - the same severity as success - so a
        # log filtered to problems showed nothing at all for the case that
        # produces a broken machine.
        $groupSaid = ("driver group '{0}' not found under {1}. No drivers will be staged from a group; " +
            "this machine is matched against the store by its hardware ids instead.") -f $group, $driverRoot
        $groupSeverity = 'Warning'
    } else {
        $groupSaid = 'no driver group was named, so this machine is matched against the store by its hardware ids.'
    }

    Write-HDTLog -Context $Context.Log -Event 'driver.group' -Component 'ApplyDrivers' `
        -Severity $groupSeverity -Message $groupSaid `
        -Data ([ordered] @{
            # WRITTEN BESIDE GROUP, AND BOTH STAY. The rule's raw value next to
            # the path it resolved to is provenance done properly, and no other
            # step here has an equivalent.
            group   = [string] $groupPath
            written = [string] $group
            found   = [bool] $groupFound
            mode    = [string] $mode
        })

    $clock = $Context.Service.Clock
    $startedUtc = $clock.GetUtcNow()

    $injected = New-Object -TypeName System.Collections.ArrayList
    $matchedCount = 0

    # WHETHER THE PnP RANKING WAS CONSULTED AT ALL, which decides whether a
    # `matched` count is a fact or a lie. See the payload at the end of this
    # function: on the group path nothing is ever ranked, so reporting matched:0
    # there told administrators their hardware matched nothing.
    $pnpRan = $false

    # The published names already reported, so a cumulative answer from DISM is
    # counted once. Ordinal-ignore-case because oem12.inf is a filename.
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList (
        [System.StringComparer]::OrdinalIgnoreCase)

    # RESOLVED HERE, WHERE THIS FUNCTION IS. Invoke-HDTApplyImageStep resolves
    # its own the same way and says why: a CommandInfo invoked with & does not
    # care whose scope it is called from, and a private command looked up from
    # inside a closure later can fail to resolve while every other assertion
    # still passes.
    $updateDisplay = Get-Command -Name 'Update-HDTProgressDisplay'

    # WHERE THE DRIVERS LAND ON THE MACHINE. MDT's ZTIDrivers puts them under
    # the OS volume and points the answer file's DriverPaths at the folder;
    # Windows installs them from there at first boot, from the machine's own
    # disk. <OSVolume>\Drivers is the path MDT has always used.
    $stageRoot = '{0}Drivers' -f $applyPath

    # ONE PACKAGE, COPIED. It used to be one Add-WindowsDriver per driver, and
    # every one of those opens the offline image, adds a package and COMMITS
    # it: 82 drivers took 649 seconds on a Latitude 5490, a median of nine
    # seconds each, nearly all of it the servicing session rather than the
    # driver. That commit is what a technician watched as "the dismount running
    # over and over" for eleven minutes.
    $stage = {
        param([string] $Source, [string] $Relative)

        if ($seen.Contains($Source)) { return }
        [void] $seen.Add($Source)

        $target = $stageRoot
        if (-not [string]::IsNullOrWhiteSpace($Relative)) {
            $target = [System.IO.Path]::Combine($stageRoot, $Relative.TrimStart('\', '/'))
        }

        $name = Split-Path -Path $Source -Leaf
        $startedPackage = $clock.GetUtcNow()

        # 48 SECONDS OF SILENCE, ON A REAL DEPLOYMENT. Staging the Latitude 5490
        # pack took 48078 ms and wrote ONE line, at the end. The group path -
        # which is the normal path, the one nearly every deployment takes -
        # copied a folder whole and reported nothing until it was done. Only the
        # PnP fallback reported progress, and the fallback almost never runs.
        #
        # AND IT IS WORSE THAN A STILL BAR. The progress card's elapsed clock is
        # derived from the FIRST AND LAST record in the log
        # (Get-HDTDeploymentProgress), so a step that says nothing does not
        # merely fail to move its own bar - it stops the clock for the whole
        # deployment. Somebody watching had no way to tell a working machine
        # from a hung one.
        #
        # THE DENOMINATOR IS EXACT, so this percentage is counted rather than
        # guessed from elapsed time: Copy-HDTDriverPackage walks the package
        # before it copies a byte, so it knows the file count up front.
        #
        # EVERY FIVE PERCENT, WHICH IS A MEASURED STRIDE AND NOT A GUESS. 1302
        # files would be 1302 records, and the JSONL is read back and re-parsed
        # on every nudge. Every whole percent is a hundred records - still enough
        # to bury the five Info lines a technician is meant to read at a glance.
        # ApplyImage wrote 22 progress records for the whole OS apply on
        # LT-7FJ45S2, so a five percent stride puts this at the same order: about
        # twenty records over 48 seconds, a bar that moves every two or three
        # seconds, which is all "it is not hung" requires.
        #
        # AND 100 ALWAYS REPORTS. A package whose file count does not divide into
        # the stride would otherwise finish on 96% and stay there.
        # A HASHTABLE AND NOT AN [int], and this is the same trap Get-HDTDriver's
        # walk carries a note about: Copy-HDTDriverPackage invokes this block
        # with '&', which gives it its own scope, so `$last = 5` inside would
        # create a local and throw it away - and the throttle would silently do
        # nothing, writing all 1302 records. Mutating a hashtable every scope can
        # see is what actually carries the value out.
        $percentState = @{ Last = -1 }

        $copied = Copy-HDTDriverPackage -Source $Source -Destination $target -FileSystem $fileSystem `
            -OnProgress {
            param($Progress)

            if ([int] $Progress.Percent -lt ([int] $percentState.Last + 5) -and
                [int] $Progress.Percent -ne 100) { return }

            if ([int] $Progress.Percent -eq [int] $percentState.Last) { return }

            $percentState.Last = [int] $Progress.Percent

            Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component 'ApplyDrivers' `
                -Message ('staging {0}: {1}%' -f $name, [int] $Progress.Percent) `
                -Data ([ordered] @{
                    package = [string] $name
                    done    = [int] $Progress.Done
                    total   = [int] $Progress.Total
                    percent = [int] $Progress.Percent
                })

            # AND THEN TELL THE WINDOW TO LOOK. A record nothing reads back is a
            # record that draws nothing, which is the state this step's fallback
            # progress was in before anybody checked.
            & $updateDisplay -Context $Context
        }

        [void] $injected.Add($copied)

        $packageMillisecond = [long] (($clock.GetUtcNow()) - $startedPackage).TotalMilliseconds

        # THE .inf COUNT FIRST, BECAUSE IT IS THE ONE THAT MEANS ANYTHING.
        # This line used to read "staged Latitude 5490 (1302 file(s))". 1302 is
        # .sys, .cat, .dll, .exe and the vendor's release notes; the Latitude
        # 5490 pack is 126 .inf files, and 126 is the number that maps to
        # DEVICES. An administrator judging whether the right pack went on reads
        # the .inf count; 1302 tells them only that a folder was big.
        Write-HDTLog -Context $Context.Log -Event 'driver.staged' -Component 'ApplyDrivers' `
            -Message ('staged {0} ({1} .inf, {2} files, {3}) to {4} in {5} ms.' -f
                $name, [int] $copied.InfCount, [int] $copied.FileCount,
                (Format-HDTConsoleByteCount -Byte ([long] $copied.ByteCount) -Compact),
                $target, $packageMillisecond) `
            -Data ([ordered] @{
                source     = [string] $Source
                target     = [string] $target
                infCount   = [int] $copied.InfCount
                fileCount  = [int] $copied.FileCount
                byteCount  = [long] $copied.ByteCount
                durationMs = [long] $packageMillisecond
            })
    }

    # -- the cross-match, run after everything is on the disk -------------
    #
    # PARSED FROM THE STAGED COPY, NOT FROM THE SHARE. The .inf files are on
    # W:\Drivers by the time this runs, on a local disk; re-reading 126 of them
    # back across SMB to say the same thing would add seconds to a step that has
    # just spent 48 of them, for no better answer.
    #
    # THE FRAMING IS THE POINT, AND THE OBVIOUS VERSION IS WORSE THAN SILENCE.
    # "118 devices, 112 not covered" is true and useless: most devices are served
    # by Windows in-box drivers, so that number is both normal and alarming, and
    # an administrator who reads it twice learns to ignore the line. Two
    # questions earn their place - is this the right pack, and is anything that
    # would strand the machine unserved by it.
    $report = {
        # THE REPORT IS A COURTESY AND MAY NOT DEMAND A SERVICE. Read directly
        # rather than through GetRequired: on the group path the Cim service was
        # never needed, and a run configured without one must still stage its
        # drivers rather than fail at the very end for the want of a comment on
        # what it just did.
        $cimService = $Context.Service.Cim
        if ($null -eq $cimService) { return }

        $stagedFile = @(Get-HDTDriverPackageFile -Path $stageRoot -FileSystem $fileSystem)
        $stagedInfFile = @($stagedFile | Where-Object { $_.IsInf })

        if ($stagedInfFile.Count -eq 0) { return }

        $parsed = New-Object -TypeName System.Collections.ArrayList

        foreach ($one in $stagedInfFile) {
            # ONE UNREADABLE .inf MUST NOT EMPTY THE REPORT, which is the rule
            # Get-HDTDriver already follows for the console's grid. A vendor pack
            # with one truncated file would otherwise report that NOTHING in it
            # is relevant to the machine - a false alarm of exactly the kind this
            # is supposed to prevent.
            try {
                $driver = ConvertFrom-HDTDriverInf `
                    -Text ([string] $fileSystem.ReadAllText([string] $one.FullPath)) `
                    -InfName ([System.IO.Path]::GetFileName([string] $one.FullPath))

                [void] $parsed.Add($driver)
            } catch {
                continue
            }
        }

        $machineDevice = @(Get-HDTPresentDevice -Cim $cimService)
        $coverage = Compare-HDTDriverInventory -Device $machineDevice -Driver @($parsed)

        # IS THIS THE RIGHT PACK? A pack for another model claims almost nothing
        # this machine reports, and that shows up in one number.
        Write-HDTLog -Context $Context.Log -Event 'driver.match' -Component 'ApplyDrivers' `
            -Message ('{0} of {1} staged .inf file(s) claim a hardware id this machine reports. This is a guide to whether the right pack was staged, not a prediction: it does not rank drivers or read signatures, dates or versions, and a device with no staged .inf is usually served by a driver in-box in Windows.' -f
                [int] $coverage.RelevantCount, [int] $coverage.DriverCount) `
            -Data ([ordered] @{
                staged      = [int] $coverage.DriverCount
                relevant    = [int] $coverage.RelevantCount
                deviceCount = [int] $coverage.DeviceCount
            })

        # IS ANYTHING THAT MATTERS UNSERVED? Only the classes that strand a
        # machine, because an unserved audio device is not one somebody has to
        # drive back out to - and listing it would bury the ones that are.
        if (@($coverage.UnmatchedCriticalDevice).Count -gt 0) {
            $named = @($coverage.UnmatchedCriticalDevice | ForEach-Object {
                    $firstId = ''
                    if (@($_.HardwareId).Count -gt 0) { $firstId = [string] @($_.HardwareId)[0] }

                    # THE MOST SPECIFIC ID, WHICH IS THE ONE A VENDOR'S DOWNLOAD
                    # PAGE IS SEARCHED FOR - and the one MDT logs, in
                    # ZTIDrivers's "Skipping Device <id> No 3rd party drivers
                    # found."
                    "'{0}' ({1}, {2})" -f $_.Name, $_.Class, $firstId
                })

            # A CAP, BECAUSE A LINE NOBODY FINISHES READING IS A LINE NOBODY
            # READS. The class and bus filters already take the lab host from 118
            # devices to 5, so this should never fire on a healthy machine - it
            # is here for the one that enumerates thirty NICs, where the useful
            # information is the first few and the count, not a paragraph.
            $shown = @($named)
            if ($shown.Count -gt 8) {
                $shown = @(@($named)[0..7] + ('and {0} more' -f ($named.Count - 8)))
            }

            Write-HDTLog -Context $Context.Log -Event 'driver.match' -Component 'ApplyDrivers' `
                -Severity Warning `
                -Message ('no staged .inf claims an id for {0} of the {1} device(s) in the classes that can strand a machine ({2}): {3}. Windows may still serve these from its own in-box drivers - this is a prompt to check, not a prediction of failure.' -f
                    @($coverage.UnmatchedCriticalDevice).Count, [int] $coverage.CriticalDeviceCount,
                    (@($coverage.CriticalClass) -join ', '), (@($shown) -join '; ')) `
                -Data ([ordered] @{
                    unmatched = [int] @($coverage.UnmatchedCriticalDevice).Count
                    critical  = [int] $coverage.CriticalDeviceCount
                })
        } else {
            Write-HDTLog -Context $Context.Log -Event 'driver.match' -Component 'ApplyDrivers' `
                -Message ('every one of the {0} device(s) in the classes that can strand a machine is claimed by a staged .inf.' -f
                    [int] $coverage.CriticalDeviceCount) `
                -Data ([ordered] @{ unmatched = 0; critical = [int] $coverage.CriticalDeviceCount })
        }

        # AND THE WORKING, AT Debug. Which .inf matched which device, off which
        # kind of id - the evidence behind the two lines above, for the run where
        # somebody disagrees with them.
        foreach ($one in @($coverage.RelevantDriver)) {
            Write-HDTLog -Context $Context.Log -Event 'driver.match' -Component 'ApplyDrivers' -Severity Debug `
                -Message ("{0} claims {1}, which '{2}' reports as a {3}" -f
                    $one.InfName, $one.MatchedId, $one.DeviceName, $one.Source) `
                -Data ([ordered] @{
                    infName    = [string] $one.InfName
                    class      = [string] $one.Class
                    matchedId  = [string] $one.MatchedId
                    source     = [string] $one.Source
                    deviceName = [string] $one.DeviceName
                })
        }
    }

    # -- the working, before anything is copied ---------------------------
    #
    # AT Debug, WHICH IS DESIGN 4.4's DECISION AND NOT A HEDGE: an Info run drops
    # these and a share that wants them sets logLevel: Debug. What goes here is
    # everything a person would otherwise have to reproduce the deployment to
    # find out.
    #
    # NONE OF IT MAY COST THE DEPLOYMENT. This is evidence about the run, not
    # part of it - a machine must not fail to get its drivers because the
    # explanation of what it was about to get could not be assembled.
    try {
        # WHAT THE RULE PRODUCED AND WHERE IT CAME FROM. HDTDriverGroup is the
        # variable that decides this whole step, and until now its value appeared
        # in the log only already expanded into a path. When the path is wrong,
        # the question is which rule wrote it.
        $groupVariable = ''
        if ($Context.Variable.Contains('HDTDriverGroup')) {
            $groupVariable = [string] $Context.Variable['HDTDriverGroup']
        }

        Write-HDTLog -Context $Context.Log -Event 'driver.group' -Component 'ApplyDrivers' -Severity Debug `
            -Message ("HDTDriverGroup is '{0}'; this step's group property is '{1}', which expanded to '{2}'" -f
                $groupVariable, $groupWritten, $group) `
            -Data ([ordered] @{
                variable = [string] $groupVariable
                written  = [string] $group
                resolved = [string] $groupPath
            })

        if ($groupFound) {
            # THE .inf COUNT OF THE SOURCE, BEFORE IT MOVES. If this is small and
            # the machine is a laptop, the wrong folder was named - and knowing
            # that before the 48-second copy is better than after it.
            $sourceFile = @(Get-HDTDriverPackageFile -Path $groupPath -FileSystem $fileSystem)

            Write-HDTLog -Context $Context.Log -Event 'driver.group' -Component 'ApplyDrivers' -Severity Debug `
                -Message ('{0} holds {1} .inf file(s) in {2} file(s), {3}' -f
                    $groupPath, @($sourceFile | Where-Object { $_.IsInf }).Count, $sourceFile.Count,
                    (Format-HDTConsoleByteCount -Byte ([long] (@($sourceFile | Measure-Object -Property Length -Sum).Sum)) -Compact)) `
                -Data ([ordered] @{
                    group     = [string] $groupPath
                    infCount  = [int] @($sourceFile | Where-Object { $_.IsInf }).Count
                    fileCount = [int] $sourceFile.Count
                })
        }

        # WHAT THE MACHINE SAYS IT IS MADE OF, AND THE IDS THAT MATTER.
        # The whole inventory is in Gather\devices.json; what belongs in the
        # driver step's log is the handful of classes whose absence strands a
        # machine - MDT logs one line per device and the volume is why its own
        # per-id line is commented out in ZTIDrivers.wsf.
        $cimForLog = $Context.Service.Cim

        if ($null -ne $cimForLog) {
            $seenDevice = @(Get-HDTPresentDevice -Cim $cimForLog)

            # THE SAME RULE THE REPORT USES, and it must stay the same rule: a
            # Debug list that named a different set from the warning would have a
            # technician comparing two lists that disagree for no visible reason.
            # Compare-HDTDriverInventory owns the definition; this borrows it by
            # calling it with no drivers, which answers the classification
            # without pretending anything matched.
            $shape = Compare-HDTDriverInventory -Device $seenDevice -Driver @()
            $criticalClass = [string[]] @($shape.CriticalClass)
            $criticalBus = [string[]] @($shape.CriticalBus)

            Write-HDTLog -Context $Context.Log -Event 'driver.enumerate' -Component 'ApplyDrivers' -Severity Debug `
                -Message ('{0} device(s) reported hardware ids' -f $seenDevice.Count) `
                -Data ([ordered] @{ deviceCount = [int] $seenDevice.Count })

            # FILTERED IN A LOOP RATHER THAN A Where-Object CLAUSE. Working out
            # the enumerator needs two statements, and a nested scriptblock
            # inside Where-Object does not see $_ the way it reads as though it
            # does - the pipeline variable belongs to the Where-Object block, not
            # to a block invoked from inside it.
            $criticalDevice = New-Object -TypeName System.Collections.ArrayList

            foreach ($candidate in $seenDevice) {
                if ($criticalClass -notcontains [string] $candidate.Class) { continue }

                $id = [string] $candidate.DeviceId
                $at = $id.IndexOf([char] 0x5C)
                $enumerator = $id
                if ($at -ge 0) { $enumerator = $id.Substring(0, $at) }

                if ($criticalBus -notcontains $enumerator.ToUpperInvariant()) { continue }

                [void] $criticalDevice.Add($candidate)
            }

            foreach ($one in $criticalDevice) {
                $firstId = ''
                if (@($one.HardwareID).Count -gt 0) { $firstId = [string] @($one.HardwareID)[0] }

                Write-HDTLog -Context $Context.Log -Event 'driver.enumerate' -Component 'ApplyDrivers' -Severity Debug `
                    -Message ("{0}: '{1}' {2}" -f $one.Class, $one.Name, $firstId) `
                    -Data ([ordered] @{
                        class      = [string] $one.Class
                        deviceName = [string] $one.Name
                        hardwareId = [string] $firstId
                    })
            }
        }
    } catch {
        Write-HDTLog -Context $Context.Log -Event 'driver.enumerate' -Component 'ApplyDrivers' -Severity Debug `
            -Message ('the pre-staging detail could not be assembled: {0}. Staging continues.' -f [string] $_.Exception.Message)
    }

    try {
        if ($groupFound -and $mode -eq 'all') {
            # THE WHOLE FOLDER, COPIED - which is what MDT does with a vendor
            # pack of a hundred and forty .inf files, and what the answer file's
            # DriverPaths then points Windows at.
            & $stage $groupPath $group
        } else {
            if (-not $groupFound) {
                $why = 'no group was named'
                if (-not [string]::IsNullOrWhiteSpace($group)) {
                    $why = "the group folder '{0}' is not on the share" -f $groupPath
                }

                # THE REASON, NOT JUST THE FACT. "It fell back" and "it fell back
                # because somebody's rule built a path that is not there" are
                # different bugs with the same symptom.
                Write-HDTLog -Context $Context.Log -Event 'driver.fallback' -Component 'ApplyDrivers' `
                    -Message ('falling back to PnP match: {0}' -f $why) `
                    -Data ([ordered] @{ reason = [string] $why; group = [string] $groupPath })
            }

            $cim = $Context.Service.GetRequired('Cim', 'ApplyDrivers')
            $device = @(Get-HDTPresentDevice -Cim $cim)

            Write-HDTLog -Context $Context.Log -Event 'driver.enumerate' -Component 'ApplyDrivers' `
                -Message ('{0} devices reported hardware ids' -f $device.Count) `
                -Data ([ordered] @{ deviceCount = [int] $device.Count })

            # SCOPED TO THE GROUP WHEN THERE IS ONE - mode 'matching' over a
            # resolved folder is MDT's "install only matching drivers from the
            # selection profile", and it must not wander into the rest of the
            # store.
            $driverArgument = @{ Root = [string] $Context.WorkspaceRoot; FileSystem = $fileSystem }
            if ($groupFound) { $driverArgument['Path'] = [string] $group }

            $candidate = @(Get-HDTDriver @driverArgument)

            # MDT'S SELECTION PROFILE, NARROWING WHAT IS CONSIDERED. It is
            # filtered by FULL PATH rather than by re-reading each folder,
            # because a profile's include paths are authored share-relative and
            # Get-HDTDriver counts from inside Drivers\ - matching those two
            # spellings against each other is the kind of off-by-one-segment
            # bug that silently scopes to nothing.
            #
            # A PROFILE THAT INCLUDES NOTHING PRESENT IS IGNORED, not obeyed. An
            # empty scope would match no driver at all and report it as "this
            # machine needs nothing", which is indistinguishable from success.
            if (-not [string]::IsNullOrWhiteSpace($profileName)) {
                $include = @(Expand-HDTSelectionProfile -Root ([string] $Context.WorkspaceRoot) `
                        -Id $profileName -FileSystem $fileSystem | Where-Object { $_.Present })

                Write-HDTLog -Context $Context.Log -Event 'driver.fallback' -Component 'ApplyDrivers' `
                    -Message ("selection profile '{0}' includes {1} folder(s) present on the share" -f $profileName, $include.Count) `
                    -Data ([ordered] @{
                        reason  = 'selection profile'
                        profile = [string] $profileName
                        folders = [int] $include.Count
                    })

                if ($include.Count -gt 0) {
                    $scoped = New-Object -TypeName System.Collections.ArrayList

                    foreach ($one in $candidate) {
                        $full = [string] $one.FullPath

                        foreach ($folder in $include) {
                            $prefix = ([string] $folder.FullPath).TrimEnd('\') + '\'

                            if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                                [void] $scoped.Add($one)
                                break
                            }
                        }
                    }

                    $candidate = @($scoped)
                }
            }

            $match = @(Get-HDTDriverMatch -Device $device -Driver $candidate)
            $matchedCount = $match.Count
            $pnpRan = $true

            # WHAT THE TECHNICIAN SEES WHILE THIS RUNS, and until now that was
            # nothing. On a Latitude 5490 this loop injected 82 drivers in 670
            # seconds - eleven minutes of a progress window showing the same
            # frame, because the elapsed time on it is derived from the FIRST
            # and LAST record in the log and nothing told the display to re-read
            # while the step was working. Somebody sitting in front of it had no
            # way to tell a working machine from a hung one.
            #
            # THE RECORDS WERE ALREADY THERE. Every driver already writes
            # driver.match and driver.injected as it happens; they simply landed
            # in the JSONL with nobody looking. This adds the step.progress the
            # window already knows how to draw, and the nudge that makes it
            # look - exactly what Invoke-HDTApplyImageStep does from its DISM
            # callback.
            #
            # EVERY DRIVER, NOT EVERY FIFTH. ApplyImage throttles because DISM
            # reports a hundred times in a few minutes; this reports 82 times in
            # eleven, and a bar that moves once a driver is the whole point.
            # NOT $injected: THAT NAME IS ALREADY AN ArrayList declared above,
            # which the $inject closure appends every injected package to and
            # which the step's own result counts at the end. Reusing it as a
            # counter turned it into an [int] the first time round the loop, so
            # the closure's .Add() threw and the step reported Failed - six
            # tests, all of them right.
            $progressAt = 0

            foreach ($one in $match) {
                Write-HDTLog -Context $Context.Log -Event 'driver.match' -Component 'ApplyDrivers' `
                    -Message ("{0} matches {1} at rank {2}" -f [string] $one.Driver.InfName, [string] $one.MatchedId, [int] $one.Rank) `
                    -Data ([ordered] @{
                        inf        = [string] $one.Driver.FullPath
                        infName    = [string] $one.Driver.InfName
                        matchedId  = [string] $one.MatchedId
                        rank       = [int] $one.Rank
                        source     = [string] $one.Source
                        deviceName = [string] $one.DeviceName
                        version    = [string] $one.Driver.Version
                        class      = [string] $one.Driver.Class
                    })

                # THE PACKAGE, NOT THE .inf. Driver.FullPath is the .inf file
                # itself; a driver is that file plus the .sys, .cat and .dll
                # beside and below it, and copying the .inf alone stages
                # something Windows cannot install. Driver.Folder is the
                # share-relative directory, which is also the shape the
                # destination takes under <OSVolume>\Drivers.
                & $stage (Split-Path -Path ([string] $one.Driver.FullPath) -Parent) ([string] $one.Driver.Folder)

                $progressAt++

                $percent = 100
                if ($matchedCount -gt 0) {
                    $percent = [int] [System.Math]::Floor(($progressAt / $matchedCount) * 100)
                }

                Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component 'ApplyDrivers' `
                    -Message ('staging driver {0} of {1}: {2}' -f $progressAt, $matchedCount, [string] $one.Driver.InfName) `
                    -Data ([ordered] @{
                        infName = [string] $one.Driver.InfName
                        target  = $applyPath
                        done    = $progressAt
                        total   = $matchedCount
                        percent = $percent
                    })

                # AND THEN TELL THE WINDOW TO LOOK. Update-HDTProgressDisplay
                # re-reads the log and hands the host a new snapshot; without
                # this the record above is written and never drawn, which is the
                # state this step has always been in.
                & $updateDisplay -Context $Context
            }
        }
    } catch {
        return (& $fail ("staging drivers to {0} failed: {1}" -f $stageRoot, [string] $_.Exception.Message) '')
    }

    $durationMillisecond = [long] (($clock.GetUtcNow()) - $startedUtc).TotalMilliseconds

    $stagedInf = 0
    $stagedByte = [long] 0
    foreach ($one in $injected) {
        $stagedInf += [int] $one.InfCount
        $stagedByte += [long] $one.ByteCount
    }

    $data = [ordered] @{
        group      = [string] $groupPath
        written    = [string] $group
        groupFound = [bool] $groupFound
        mode       = [string] $mode
        target     = [string] $applyPath
        # `injected` WAS THE NAME AND IT CONTRADICTED THE MESSAGE BESIDE IT.
        # The line reads "staged N driver package(s)"; the payload called the
        # same number injected, which is what this step did through DISM until
        # the per-driver commit cost eleven minutes on a Latitude. Nothing is
        # injected any more - the packages are copied and Windows installs them
        # at first boot - so the payload now says what happened.
        staged     = [int] $injected.Count
        infCount   = [int] $stagedInf
        byteCount  = [long] $stagedByte
        durationMs = [long] $durationMillisecond
    }

    # `matched` ONLY WHEN SOMETHING WAS MATCHED, and this was actively
    # misleading. The group path never consults the PnP ranking - that is the
    # whole point of Total Control - so `matched` was 0 on every normal
    # deployment, sitting in the payload beside a successful staging. An
    # administrator reading it concluded their hardware matched none of the
    # drivers they had just shipped and went debugging a problem that did not
    # exist. A number that is only ever zero is not a measurement.
    if ($pnpRan) { $data['matched'] = [int] $matchedCount }

    if ($injected.Count -eq 0) {
        # LOUD, AND STILL COMPLETED. The deployment continues on inbox drivers,
        # which is MDT's behaviour - but a technician reading the log has to see
        # that this machine got nothing.
        #
        # MDT DOES NOT SAY THIS AT ALL, and that is the gap being closed.
        # ZTIDrivers logs a per-device "Skipping Device ... No 3rd party drivers
        # found" and no summary; its only group-level equivalent is
        # ZTIConfigFile's "No matching Selection Profiles and/or Groups found."
        # at VERBOSE, in a different file. PSD is silent when there is no
        # fallback path configured. So the one sentence that explains a machine
        # with no network card was, in both prior arts, invisible.
        $message = ('no drivers were staged to {0}. Windows will install only the drivers in-box in the ' +
            'applied image, which for a machine needing an OEM network or storage driver means it may come ' +
            'up unable to see its network or its disk.') -f $stageRoot

        Write-HDTLog -Context $Context.Log -Event 'driver.staged' -Component 'ApplyDrivers' `
            -Severity Warning -Message $message -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    }

    # -- what actually installs these, said out loud ----------------------
    #
    # THE LOG USED TO END AT "staged", WHICH LEFT NO THREAD TO PULL. Staging only
    # COPIES; the thing that installs the drivers is the answer file's
    # PnpCustomizationsNonWinPE DriverPaths, applied in the offlineServicing
    # pass. That is exactly what was broken here until the step order changed -
    # drivers were staged AFTER the unattend was written, so the path went in
    # pointing at an empty folder - and an administrator reading "staged 1
    # driver package(s)" had nothing telling them where to look next.
    #
    # MDT NAMES ITS CONSUMER TOO, in its own vocabulary: ZTIDrivers logs
    # "Updated DevicePath=..." after editing the offline SOFTWARE hive. Same
    # idea, different mechanism.
    $message = 'staged {0} driver package(s) ({1} .inf, {2}) to {3} in {4} ms.' -f
        $injected.Count, $stagedInf, (Format-HDTConsoleByteCount -Byte $stagedByte -Compact),
        $stageRoot, $durationMillisecond

    # ONE RECORD, NOT TWO. The consumer sentence is part of what the summary
    # SAYS, not a second thing that happened - and `driver.staged` already means
    # "a package was staged", one record per package, which a step's own tests
    # count. Adding the sentence under that name made a single package look like
    # two.
    #
    # THE STEP RESULT KEEPS THE SHORT FORM. It is what the progress card shows,
    # where a paragraph would not fit; the log is where the explanation belongs.
    $said = ('{0} Windows installs them from there during the offlineServicing pass, because the ApplyUnattend ' +
        'step writes that path into the answer file as PnpCustomizationsNonWinPE DriverPaths - staging alone ' +
        'only copies the files.') -f $message

    $data['consumer'] = 'PnpCustomizationsNonWinPE/DriverPaths'

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'ApplyDrivers' -Message $said -Data $data

    # -- and whether the pack was the right one --------------------------
    #
    # A REPORT, NOT A VERDICT - and the wording is load-bearing. See
    # Compare-HDTDriverInventory: this does not rank drivers, read a signature,
    # a date or a version, and knows nothing about the in-box drivers in the
    # image being applied, which are what serve most of these devices. A device
    # named here is one THE STAGED PACK does not claim, which is not the same as
    # a device that will not work.
    #
    # IT MUST NEVER COST THE DEPLOYMENT. The drivers are already on the disk by
    # the time this runs; a parse that trips over one malformed .inf must not
    # turn a staged machine into a failed step.
    #
    # ON THE GROUP PATH ONLY, AND THAT IS NOT AN OPTIMISATION. The fallback
    # CHOSE its packages by matching them against this machine, so every .inf it
    # staged is relevant by construction and a report saying so tells nobody
    # anything - it would restate the driver.match records the fallback has
    # already written, doubling them in the log. The group path is where the
    # question is real: a folder was copied WHOLE because somebody's rule named
    # it, and until now nothing ever checked that folder against the machine.
    if ($groupFound -and $mode -eq 'all') {
        try {
            & $report
        } catch {
            Write-HDTLog -Context $Context.Log -Event 'driver.match' -Component 'ApplyDrivers' -Severity Debug `
                -Message ('the staged drivers could not be cross-matched against this machine: {0}. The drivers are staged; only the report was skipped.' -f
                    [string] $_.Exception.Message)
        }
    }

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
