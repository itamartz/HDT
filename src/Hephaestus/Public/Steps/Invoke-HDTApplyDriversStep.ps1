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
            A New-HDTStepResult. Data carries group, injected, matched and
            durationMs, or errorId on a refusal.

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
            $result.Data['matched']
            $result.Data['injected']

            How many drivers the machine matched, and how many went in. They differ
            when DISM refused one - and both being zero is a completed step that
            deployed nothing, which is why it is a warning in the log rather than
            a silent success.

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
    Write-HDTLog -Context $Context.Log -Event 'driver.group' -Component 'ApplyDrivers' `
        -Message ("driver group '{0}' {1}" -f $groupPath, $(if ($groupFound) { 'resolved' } else { 'is not on the share' })) `
        -Data ([ordered] @{
            group   = [string] $groupPath
            written = [string] $group
            found   = [bool] $groupFound
            mode    = [string] $mode
        })

    $clock = $Context.Service.Clock
    $startedUtc = $clock.GetUtcNow()

    $injected = New-Object -TypeName System.Collections.ArrayList
    $matchedCount = 0

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

        $copied = Copy-HDTDriverPackage -Source $Source -Destination $target -FileSystem $fileSystem

        [void] $injected.Add($copied)

        Write-HDTLog -Context $Context.Log -Event 'driver.staged' -Component 'ApplyDrivers' `
            -Message ('staged {0} ({1} file(s)) to {2}' -f (Split-Path -Path $Source -Leaf), [int] $copied.FileCount, $target) `
            -Data ([ordered] @{
                source    = [string] $Source
                target    = [string] $target
                fileCount = [int] $copied.FileCount
            })
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

    $data = [ordered] @{
        group      = [string] $groupPath
        groupFound = [bool] $groupFound
        mode       = [string] $mode
        target     = [string] $applyPath
        matched    = [int] $matchedCount
        injected   = [int] $injected.Count
        durationMs = [long] $durationMillisecond
    }

    if ($injected.Count -eq 0) {
        # LOUD, AND STILL COMPLETED. The deployment continues on inbox drivers,
        # which is MDT's behaviour - but a technician reading the log has to see
        # that this machine got nothing.
        $message = 'no drivers were staged to {0}. The deployment continues on the drivers inbox in the applied image.' -f $stageRoot

        Write-HDTLog -Context $Context.Log -Event 'driver.staged' -Component 'ApplyDrivers' `
            -Severity Warning -Message $message -Data $data

        return (New-HDTStepResult -Status Completed -Message $message -Data $data)
    }

    $message = 'staged {0} driver package(s) to {1} in {2} ms.' -f $injected.Count, $stageRoot, $durationMillisecond

    Write-HDTLog -Context $Context.Log -Event 'native.exec' -Component 'ApplyDrivers' -Message $message -Data $data

    return (New-HDTStepResult -Status Completed -Message $message -Data $data)
}
