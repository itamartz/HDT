function Invoke-HDTApplyUpdatesStep {
    <#
        .SYNOPSIS
            Applies imported Windows updates to the applied OS volume, offline,
            before the machine first boots.

        .DESCRIPTION
            MDT'S Packages NODE, IN HDT'S SHAPE. The updates an administrator
            imported into WindowsUpdates\ are injected into the volume the image
            was just laid onto, so the machine boots patched rather than spending
            its first hour on Windows Update. This is NOT the deferred
            WindowsUpdate step in DESIGN 10.1: that one is online, full-OS and
            talks to WSUS. This one is offline servicing in WinPE and shares
            nothing with it but a subject.

            THE PACKAGE IS HANDED TO DISM AS IT WAS DOWNLOADED, and that was
            measured rather than assumed. A modern .msu is a WIM container
            holding an express package - a .wim beside a .psf carrying the deltas
            - and pointing /Add-Package at that inner .wim fails 0x80070057.
            Handing dism the .msu works, on both packages, against both a client
            and a server image. So nothing is unpacked here, at import or at
            apply, which is also why the store is the size of the downloads.

            THE EXIT CODE IS NOT THE VERDICT. dism exited 0xC0000409 after a
            Windows 11 apply that had plainly worked - the image went from
            10.0.26100.1742 to 10.0.26100.8655 and its package count went from 85
            to 159 - and exited 0 after the equivalent Server apply. So this step
            asks the IMAGE what it has afterwards, through GetPackage, and
            believes that. It is also the only check immune to dism's prose being
            localised, since nothing in the adapter pins a language.

            EVERY PACKAGE GETS ITS OWN LOG RECORD, never one summary for the
            pass. Twenty updates in a sequence is twenty questions somebody will
            ask afterwards - which one was already in the image, which one wanted
            a prerequisite, which one actually failed - and update.apply carries
            the KB, the release, dism's code and the outcome for each.

            NOT APPLICABLE IS NOT A FAILURE, and this is where the step parts
            company with a naive reading of DISM's exit codes. 0x800F081E means
            the package does not apply to this image, which is the ORDINARY
            result of importing a broad set and letting a sequence pick from it.
            MDT swallows every error here - ZTIPatches logs a non-zero DISM
            return and still returns Success - and this step keeps the half of
            that which is right (apply everything, never stop at the first
            problem) and rejects the half which is not (report success
            regardless). A package that failed for any other reason fails the
            step, AFTER every other package has been tried.

        .PARAMETER Step
            The step, carrying release and target.

        .PARAMETER Context
            The execution context: services, variables and the log.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            A New-HDTStepResult. Data carries release, target, considered,
            applied, alreadyPresent, notApplicable and failed.

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\PNP-TEST\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'ApplyUpdates' })[0]
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs'
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'C:\HDTLab\Share' `
                -Variable ([ordered] @{ HDTOSVolume = 'W' }) -Service (New-HDTServiceCatalog) -Log $log

            Invoke-HDTApplyUpdatesStep -Step $step -Context $context

            Applies every update filed under the step's release to the volume
            HDTOSVolume names, writing one log record per package.

        .EXAMPLE
            $result = Invoke-HDTApplyUpdatesStep -Step $step -Context $context
            $result.Data['applied']
            $result.Data['notApplicable']

            How many landed and how many did not apply to this image. A package
            that is not applicable is not a failure - importing a broad set and
            letting a sequence pick from it is the ordinary workflow.
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
            -Component 'ApplyUpdates' -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    try {
        $release = Get-HDTStepProperty -Step $Step -Name 'release' -Default '' -Context $Context -Expand -As String
        $target = Get-HDTStepProperty -Step $Step -Name 'target' -Default 'primary' -Context $Context -Expand -As String

        # What the author wrote, unexpanded, so a refusal can name the variable
        # that was meant to fill an empty target - ApplyDrivers' rule, and for
        # the same reason: the expanded value alone cannot say which rule built it.
        $targetWritten = Get-HDTStepProperty -Step $Step -Name 'target' -Default 'primary' -As String
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    try {
        $fileSystem = $Context.Service.GetRequired('FileSystem', 'ApplyUpdates')
        $image = $Context.Service.GetRequired('Image', 'ApplyUpdates')
    } catch {
        return (& $fail ([string] $_.Exception.Message) '')
    }

    # -- where -------------------------------------------------------------

    $letter = $target

    if ($target -eq 'primary') { $letter = [string] $Context.Variable['HDTOSVolume'] }

    if ($null -eq $letter) { $letter = '' }
    $letter = $letter.Trim().TrimEnd('\').TrimEnd(':')

    if ($letter.Length -eq 0) {
        $said = "step '{0}' services the primary volume and HDTOSVolume is not set. The partition step publishes it; HDT will not guess a volume to inject updates into." -f $Step.Name

        if ($targetWritten -match '^\s*%([^%]+)%\s*$') {
            $said = "step '{0}' services %{1}%, which is not set. The partition step publishes it; HDT will not guess a volume to inject updates into." -f
                $Step.Name, [string] $Matches[1]
        }

        return (& $fail $said 'HDTConfigurationError')
    }

    $osRoot = '{0}:\' -f $letter

    # -- what --------------------------------------------------------------

    $workspaceRoot = [string] $Context.WorkspaceRoot

    try {
        # ALREADY IN APPLY ORDER. Get-HDTWindowsUpdate sorts through
        # Get-HDTUpdateApplyOrder - servicing stack first, then by the build each
        # update produces - so the step does not re-decide an ordering that is
        # decided in one place.
        $update = @(Get-HDTWindowsUpdate -WorkspaceRoot $workspaceRoot -FileSystem $fileSystem)
    } catch {
        return (& $fail ("step '{0}' could not read the workspace's Windows updates: {1}" -f
                $Step.Name, [string] $_.Exception.Message) 'HDTConfigurationError')
    }

    # AN EMPTY release IS "EVERYTHING IMPORTED", which is the setting for a share
    # deploying one operating system. It is a real choice, not a missing value,
    # so it is not an error.
    if (-not [string]::IsNullOrWhiteSpace($release)) {
        $update = @($update | Where-Object { [string] $_.Release -eq $release })
    }

    # A DISABLED UPDATE IS ONE SOMEBODY TOOK OUT OF SERVICE WITHOUT DELETING IT,
    # which is how an update that turned out to break something is withdrawn
    # while the evidence is kept.
    $update = @($update | Where-Object { [bool] $_.Enabled })

    # step.progress AND NOT update.apply, BECAUSE THIS RECORD IS ABOUT NO
    # PARTICULAR UPDATE. update.apply is documented as one update applied, and
    # anything filtering it reads data.kb; a kb-less record in that stream is a
    # blank row in every report that renders one - which is exactly the defect
    # that split var.resolve from var.unresolved.
    Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component 'ApplyUpdates' `
        -Message ("step '{0}' considering {1} update(s) for {2}, into {3}" -f
            $Step.Name, $update.Count, $(if ([string]::IsNullOrWhiteSpace($release)) { 'every release' } else { $release }), $osRoot) `
        -Data ([ordered] @{
            percent    = 0
            release    = $release
            target     = $osRoot
            considered = $update.Count
        })

    if ($update.Count -eq 0) {
        # NOTHING TO DO IS NOT A FAILURE. A sequence that runs before any update
        # has been imported is a sequence somebody is building, and refusing it
        # would make the step impossible to add before its content exists.
        return (New-HDTStepResult -Status Completed `
                -Message ("no Windows update to apply for {0}" -f
                    $(if ([string]::IsNullOrWhiteSpace($release)) { 'this workspace' } else { "release '$release'" })) `
                -Data ([ordered] @{
                    release        = $release
                    target         = $osRoot
                    considered     = 0
                    applied        = 0
                    alreadyPresent = 0
                    notApplicable  = 0
                    failed         = 0
                }))
    }

    # -- apply -------------------------------------------------------------

    $applied = 0
    $alreadyPresent = 0
    $notApplicable = 0
    $failedRow = New-Object -TypeName System.Collections.ArrayList

    $index = 0

    foreach ($current in $update) {

        $index = $index + 1

        Write-HDTLog -Context $Context.Log -Event 'step.progress' -Component 'ApplyUpdates' `
            -Message ("applying {0} ({1} of {2})" -f $current.Kb, $index, $update.Count) `
            -Data ([ordered] @{
                percent = [int] ([math]::Floor((($index - 1) * 100) / $update.Count))
                kb      = [string] $current.Kb
                index   = $index
                total   = $update.Count
            })

        # AND THEN TELL THE WINDOW TO LOOK. Update-HDTProgressDisplay re-reads
        # the log and hands the host a new snapshot; without this the record
        # above is written and never drawn. The same two lines ApplyImage,
        # ApplyDrivers and InstallApplications use, and it is documented never to
        # fail a deployment.
        #
        # IT MATTERS MORE HERE THAN ALMOST ANYWHERE. A cumulative update is eight
        # to twelve minutes of one frame - measured, 8m35s for KB5094126 and
        # 12m24s for KB5094125 - and this line is the only thing that moves in
        # front of whoever is standing at the machine.
        Update-HDTProgressDisplay -Context $Context

        # WHAT THE IMAGE HAD BEFORE, so "already present" can be told from
        # "applied" - and so a package identity that was there all along is not
        # counted as this step's work.
        $before = @()
        try {
            $before = @($image.GetPackage($osRoot) | ForEach-Object { [string] $_.Name })
        } catch {
            $before = @()
        }

        $wasPresent = $false
        if (-not [string]::IsNullOrWhiteSpace([string] $current.PackageId)) {
            $wasPresent = @($before | Where-Object { Test-HDTUpdatePackageMatch -Installed $_ -PackageId ([string] $current.PackageId) }).Count -gt 0
        }

        if ($wasPresent) {
            $alreadyPresent = $alreadyPresent + 1

            Write-HDTLog -Context $Context.Log -Event 'update.apply' -Component 'ApplyUpdates' `
                -Message ("{0} was already in the image, so it was not applied again" -f $current.Kb) `
                -Data ([ordered] @{
                    kb        = [string] $current.Kb
                    release   = [string] $current.Release
                    outcome   = 'AlreadyPresent'
                    packageId = [string] $current.PackageId
                })

            continue
        }

        $run = $null
        try {
            $run = $image.AddPackage($osRoot, [string] $current.PackagePath)
        } catch {
            [void] $failedRow.Add([string] $current.Kb)

            Write-HDTLog -Context $Context.Log -Event 'update.apply' -Component 'ApplyUpdates' -Severity Error `
                -Message ("{0} could not be applied: {1}" -f $current.Kb, [string] $_.Exception.Message) `
                -Data ([ordered] @{
                    kb      = [string] $current.Kb
                    release = [string] $current.Release
                    outcome = 'Failed'
                })

            continue
        }

        $exitCode = [int] $run.ExitCode

        # WHAT THE IMAGE HAS NOW, WHICH IS THE VERDICT. Not the exit code: dism
        # exited 0xC0000409 after an apply that had demonstrably worked and 0
        # after another, so the number is evidence and the image is the truth.
        $after = @()
        try {
            $after = @($image.GetPackage($osRoot) | ForEach-Object { [string] $_.Name })
        } catch {
            $after = @()
        }

        $landed = $false
        if (-not [string]::IsNullOrWhiteSpace([string] $current.PackageId)) {
            $landed = @($after | Where-Object { Test-HDTUpdatePackageMatch -Installed $_ -PackageId ([string] $current.PackageId) }).Count -gt 0
        }

        $outcome = Get-HDTUpdateApplyOutcome -ExitCode $exitCode -Landed $landed `
            -HasPackageId (-not [string]::IsNullOrWhiteSpace([string] $current.PackageId)) `
            -PackageCountChanged ($after.Count -ne $before.Count)

        if ($outcome.Outcome -eq 'Applied') { $applied = $applied + 1 }
        if ($outcome.Outcome -eq 'NotApplicable') { $notApplicable = $notApplicable + 1 }
        if ($outcome.Outcome -eq 'Failed') { [void] $failedRow.Add([string] $current.Kb) }

        Write-HDTLog -Context $Context.Log -Event 'update.apply' -Component 'ApplyUpdates' `
            -Severity $outcome.Severity `
            -Message ("{0} ({1}): {2}" -f $current.Kb, $current.Release, $outcome.Message) `
            -Data ([ordered] @{
                kb        = [string] $current.Kb
                release   = [string] $current.Release
                outcome   = [string] $outcome.Outcome
                exitCode  = $exitCode
                packageId = [string] $current.PackageId
                package   = [string] $current.FileName
            })
    }

    $data = [ordered] @{
        release        = $release
        target         = $osRoot
        considered     = $update.Count
        applied        = $applied
        alreadyPresent = $alreadyPresent
        notApplicable  = $notApplicable
        failed         = $failedRow.Count
    }

    if ($failedRow.Count -gt 0) {
        # EVERY PACKAGE WAS TRIED FIRST, AND THE FAILURE NAMES ALL OF THEM. MDT
        # stops at neither, and reports neither; this step does the first half
        # its way and refuses the second.
        $said = "step '{0}': {1} of {2} update(s) could not be applied to {3}: {4}. The others were applied; see the update.apply records for each." -f
            $Step.Name, $failedRow.Count, $update.Count, $osRoot, (@($failedRow) -join ', ')

        # THE COUNTS TRAVEL WITH THE FAILURE, NOT ONLY WITH SUCCESS. "One of two
        # failed" and "both failed" are different machines to walk up to, and a
        # failure result carrying nothing but an errorId makes them look the same
        # in the report - so the same Data the success path returns is returned
        # here, with the errorId added rather than substituted for it.
        $data['errorId'] = 'HDTUpdateError'
        $data['failedKb'] = (@($failedRow) -join ', ')

        Write-HDTLog -Context $Context.Log -Message $said -Severity Error -Event step.fail `
            -Component 'ApplyUpdates' -Data $data

        return (New-HDTStepResult -Status Failed -Message $said -Data $data)
    }

    return (New-HDTStepResult -Status Completed `
            -Message ("{0} update(s) applied to {1}, {2} already present, {3} not applicable" -f
                $applied, $osRoot, $alreadyPresent, $notApplicable) `
            -Data $data)
}
