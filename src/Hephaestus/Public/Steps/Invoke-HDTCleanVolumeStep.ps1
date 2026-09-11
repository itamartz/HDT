function Invoke-HDTCleanVolumeStep {
    <#
        .SYNOPSIS
            Empties the deployment target volume, leaving the run's own state
            standing, so an image can be applied over a bare volume.

        .DESCRIPTION
            THE STEP A REFRESH IS MADE OF. DESIGN 3.2: a Refresh does not
            repartition and does not format - it DELETES. DISM /Apply-Image
            OVERLAYS a volume; it does not empty one, so without this step the
            previous Windows\, Program Files\, Users\ and ProgramData\ survive
            underneath the new installation and the machine looks deployed while
            carrying the last installation's files.

              - name: Clean the OS volume
                type: CleanVolume
                volume: primary          # 'primary' = %HDTOSVolume%, or a letter

            IT DELETES RATHER THAN FORMATS BECAUSE THE RUN'S OWN STATE IS
            STANDING ON THE VOLUME BEING CLEANED. state.json is mirrored to
            <volume>\HDT\state.json, the staged boot image is under
            <volume>\HDT\Boot and the logs are beside them - all of it the leg
            that came back is made of. A format would take every one of them.
            Get-HDTCleanVolumePreservedName is the set that survives and the
            reason each name is on it, and this step logs both.

            THE PARTITION TABLE IS NOT TOUCHED, and holding it apart from the
            volume contents is the mistake DESIGN 3.2 exists to foreclose. The
            table was already correct - Windows was booting from it - and
            repartitioning would destroy the staged WinPE the run depends on to
            come back through. DiskPartition therefore stays out of a Refresh
            sequence entirely, and this step does a different job.

            THREE GUARDS, EACH WITH A TEST THAT PROVES NOTHING WAS DELETED WHEN
            IT FIRED:

              1. Assert-HDTCleanVolumeTarget. It is given the volume and refuses
                 an ambiguous one rather than guessing, the same refusal
                 DiskPartition makes about a disk - and it is where CLAUDE.md's
                 "never build a delete target by enumerating a parent directory"
                 is answered rather than waived. Read that function.
              2. SupportsShouldProcess. Under -WhatIf the step enumerates, logs
                 exactly what it would delete and what it would keep, and calls
                 no delete method at all.
              3. The preserved set, applied to folders AND to the files sitting
                 in the root, so a name that must survive survives wherever it
                 is.

            THE ORDER IS MDT'S, LTIApply.wsf:1245-1317. Subfolders first at
            :1265-1282, then the root files at :1308-1315 - a root file is in no
            subfolder, so the folder loop never reaches it and a bootmgr or a
            pagefile from the last installation would otherwise survive the
            clean.

            AND ONE RETRY THROUGH AN ACL RESET, which is MDT's ResetFolder at
            :1564 called from :1285-1299. IFileSystem carries the icacls half -
            GrantAccess - and takeown on the adapter is a file-only method, so
            the reset here is the grant: Modify to Administrators, then one more
            delete. A folder whose ACL denies the caller is the commonest reason
            a delete refuses on a volume built by somebody else's deployment.

            IT FAILS WHERE MDT WARNS, AND THAT DIVERGENCE IS DELIBERATE.
            LTIApply.wsf:1297-1299 logs "Unable to delete " and carries on, so a
            locked folder survives into the new installation and nothing
            anywhere fails. HDT fails the step, for the reason already written
            into the resume guard, which fails rather than skips: a half-cleaned
            volume is a machine that looks deployed and is not, carrying a
            previous installation's Program Files into a new one, and the
            administrator who has to explain it a week later is reading a log
            that recorded the cause as a warning.

            EVERYTHING GOES THROUGH IFileSystem (rule 5), so the whole step -
            the enumeration, the preserved set, the retry and the failure - runs
            under Pester against the hand-written fake.

            AND EVERY RECORD IT WRITES HAS AN EVENT OF ITS OWN, DESIGN 4.4.2's
            volume.* family: volume.target for the volume it settled on,
            volume.clean for the tally before and after, volume.preserve for
            each entry kept and why, volume.delete for each entry that went, and
            volume.retry for the refusal that made it reset an ACL. The failure
            keeps step.fail, because a clean that could not delete something
            makes the same claim every failed step makes.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument. It may carry
            'volume': a drive letter, a variable that expands to one, or
            'primary', which is %HDTOSVolume% and the default.

        .PARAMETER Context
            A New-HDTExecutionContext context. Its Service catalog must carry a
            FileSystem and an Environment service.

        .OUTPUTS
            A New-HDTStepResult. Data carries volume, deleted and preserved, or
            errorId on a refusal.

        .EXAMPLE
            $clock = New-HDTClock
            $service = New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock `
                -Environment (New-HDTEnvironmentProvider)
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot '\\srv\HDTShare' -Variable ([ordered] @{ HDTOSVolume = 'C' }) `
                -Service $service -Log $log

            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\REFRESH-WIN11\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'CleanVolume' })[0]

            Invoke-HDTCleanVolumeStep -Step $step -Context $context

            Empties the volume the run published as HDTOSVolume, immediately
            before the image is applied over it. Building the context is what
            the engine does before the first step; a step cannot be run without
            one.

        .EXAMPLE
            Invoke-HDTCleanVolumeStep -Step $step -Context $context -WhatIf

            Lists what it would delete and what it would keep, and deletes
            nothing. This is the step that empties an operating system volume;
            -WhatIf is how you find out which one it picked before it picks it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
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

    $component = 'CleanVolume'

    $fail = {
        param([string] $Message, [string] $ErrorId)

        $data = [ordered] @{}
        if (-not [string]::IsNullOrWhiteSpace($ErrorId)) { $data['errorId'] = $ErrorId }

        Write-HDTLog -Context $Context.Log -Message $Message -Severity Error -Event step.fail `
            -Component $component -Data $data

        return (New-HDTStepResult -Status Failed -Message $Message -Data $data)
    }

    # -- what the step asked for ------------------------------------------

    try {
        $asked = [string] (Get-HDTStepProperty -Step $Step -Name 'volume' -Default 'primary' -Context $Context -Expand)
        $fileSystem = $Context.Service.GetRequired('FileSystem', $component)
        $environment = $Context.Service.GetRequired('Environment', $component)
    } catch {
        return (& $fail ([string] $_.Exception.Message) 'HDTConfigurationError')
    }

    # 'primary' IS THE VOLUME THE RUN PUBLISHED, which is ApplyImage's idiom for
    # the same question - the step after this one applies to the same letter,
    # and two steps naming it two different ways is how they come to disagree.
    $named = $asked

    if ($named.Trim() -eq 'primary') {
        $named = [string] $Context.Variable['HDTOSVolume']
    }

    # -- the target, established before anything is deleted ---------------

    try {
        $running = [string] $environment.GetVariable('SystemDrive')
        $root = Assert-HDTCleanVolumeTarget -Volume $named -FileSystem $fileSystem -SystemDrive $running
    } catch {
        return (& $fail ("step '{0}': {1}" -f $Step.Name, [string] $_.Exception.Message) 'HDTConfigurationError')
    }

    # EVERY RECORD THIS STEP WRITES HAS AN EVENT OF ITS OWN (DESIGN 4.4.2's
    # volume.* family). The question asked of a clean afterwards is never "did it
    # run" - it is "what did it take, and what did it leave" - and a record under
    # the `message` default is one the console and ConvertTo-HDTReport can only
    # grep.
    Write-HDTLog -Context $Context.Log -Component $component -Event volume.target `
        -Message ("{0} is this deployment's target volume: it carries this run's state directory, and the engine is running from {1}." -f $root, $running) `
        -Data ([ordered] @{ volume = $root; systemDrive = $running; step = [string] $Step.Name })

    # -- what is standing on it -------------------------------------------

    try {
        $folder = [string[]] @($fileSystem.GetDirectory($root))
        $entry = [string[]] @($fileSystem.GetChildItem($root))
    } catch {
        return (& $fail ("step '{0}': {1} could not be read: {2}" -f $Step.Name, $root, [string] $_.Exception.Message) 'HDTFileSystemError')
    }

    # A ROOT FILE IS AN ENTRY THAT IS NOT A FOLDER. IFileSystem has no
    # GetFile, and inventing one for this step would put a method on the
    # adapter that only one caller ever uses; the difference of the two
    # enumerations is the same answer and both are already contract-tested.
    $isFolder = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($one in $folder) { $isFolder[$one] = $true }

    $file = [string[]] @($entry | Where-Object { -not $isFolder.ContainsKey([string] $_) })

    # -- the plan, and the reason for every exemption in it ---------------

    $preserved = @(Get-HDTCleanVolumePreservedName)

    $reasonOf = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $preserved) { $reasonOf[[string] $row.Name] = [string] $row.Reason }

    $doomed = New-Object -TypeName System.Collections.ArrayList
    $kept = New-Object -TypeName System.Collections.ArrayList

    # FOLDERS FIRST, THEN THE ROOT FILES, WHICH IS MDT'S ORDER at :1265 and
    # :1308. Both lists are classified against the same set, so a preserved
    # name survives whichever kind of thing it turns out to be.
    foreach ($path in @(@($folder) + @($file))) {
        $leaf = [IO.Path]::GetFileName([string] $path)

        if ($reasonOf.ContainsKey($leaf)) {
            [void] $kept.Add([string] $path)

            # LOGGED WITH THE REASON, NOT MERELY LISTED. A bare list of
            # survivors makes every one of them look like something that failed
            # to delete, and this log is read once, at the worst possible
            # moment, by somebody who was not there when it ran.
            Write-HDTLog -Context $Context.Log -Component $component -Event volume.preserve `
                -Message ("keeping {0}: {1}" -f $path, $reasonOf[$leaf]) `
                -Data ([ordered] @{ path = [string] $path; name = $leaf; reason = $reasonOf[$leaf] })

            continue
        }

        [void] $doomed.Add([string] $path)
    }

    $data = [ordered] @{
        volume    = $root
        deleted   = [string[]] @($doomed)
        preserved = [string[]] @($kept)
    }

    # THE TALLY, AND IT IS WRITTEN TWICE UNDER ONE NAME - here before the first
    # delete and again after the last. Two records, one claim, which is
    # var.resolve's rule about a claim rather than a writer.
    Write-HDTLog -Context $Context.Log -Component $component -Event volume.clean `
        -Message ("{0} carries {1} entries: {2} will be deleted and {3} kept.{4}{5}" -f
            $root, (@($folder).Count + @($file).Count), $doomed.Count, $kept.Count,
            [System.Environment]::NewLine, ((@($doomed) | ForEach-Object { '  delete ' + $_ }) -join [System.Environment]::NewLine)) `
        -Data $data

    if (-not $PSCmdlet.ShouldProcess(
            ('{0} ({1} entries)' -f $root, $doomed.Count), 'Delete everything except this run''s own state')) {

        return (New-HDTStepResult -Status Completed -Data $data `
                -Message ('{0} would have been emptied: {1} entries deleted, {2} kept.' -f $root, $doomed.Count, $kept.Count))
    }

    # -- the deletions ----------------------------------------------------

    foreach ($path in @($doomed)) {

        # RECURSIVE, WHICH IS WHAT rd /s /q IS. A folder at a time rather than a
        # file at a time is also the only shape that finishes: Windows\ alone is
        # a hundred thousand files, and a per-file loop through the adapter
        # would make a two-minute delete an hour.
        try {
            $fileSystem.RemoveItem([string] $path, $true)
            Write-HDTLog -Context $Context.Log -Component $component -Event volume.delete `
                -Message ('deleted {0}' -f $path) -Data ([ordered] @{ path = [string] $path; reset = $false })

            continue
        } catch {
            $first = $_
        }

        # THE RETRY, AND WHAT IT IS FOR. MDT's ResetFolder, LTIApply.wsf:1564,
        # reached here from :1285-1299: a folder whose ACL denies the caller
        # refuses to be removed, and granting Administrators Modify over the
        # tree is what makes the second attempt land. S-1-5-32-544 rather than a
        # name, because icacls resolves names against the machine's locale.
        Write-HDTLog -Context $Context.Log -Component $component -Event volume.retry -Severity Warning `
            -Message ("{0} refused to be deleted ({1}: {2}). Taking ownership of it and everything under it, granting Administrators Modify, and trying once more - a denying ACL is the commonest reason a delete refuses on a volume some other deployment built, and on a deployed Windows the owner is TrustedInstaller from Program Files down, so the take has to come first or the grant has nothing to write on." -f
                $path, $first.Exception.GetType().FullName, [string] $first.Exception.Message) `
            -Data ([ordered] @{
                path      = [string] $path
                exception = $first.Exception.GetType().FullName
                message   = [string] $first.Exception.Message
            })

        try {
            # THE TAKE BEFORE THE GRANT. icacls cannot rewrite an ACL on
            # something this account does not own, and it runs with /C so it
            # carries on past every refusal and still exits 0 - a grant that
            # changed nothing and reported success. A deployed Windows is owned
            # by TrustedInstaller from C:\Program Files down, so without this
            # the retry was the same delete a second time.
            $fileSystem.TakeOwnership([string] $path)
            $fileSystem.GrantAccess([string] $path, '*S-1-5-32-544', 'Modify')
            $fileSystem.RemoveItem([string] $path, $true)
        } catch {
            # THE DIVERGENCE FROM MDT, WHICH ONLY WARNS HERE. Everything the
            # record can carry goes into it: the type, the path, the innermost
            # message and the stack. A flattened sentence is what makes this
            # unreadable a week later on a machine nobody can touch.
            $innermost = $_.Exception
            while ($null -ne $innermost.InnerException) { $innermost = $innermost.InnerException }

            $stack = ''
            if ($null -ne $_.ScriptStackTrace) { $stack = [string] $_.ScriptStackTrace }

            $said = ("step '{0}': {1} could not be deleted from {2}, so the volume is only half cleaned. {3}: {4}. First attempt: {5}: {6}." -f
                $Step.Name, $path, $root,
                $_.Exception.GetType().FullName, [string] $innermost.Message,
                $first.Exception.GetType().FullName, [string] $first.Exception.Message)

            Write-HDTLog -Context $Context.Log -Component $component -Event step.fail -Severity Error `
                -Message ("{0}{1}{2}" -f $said, [System.Environment]::NewLine, $stack) `
                -Data ([ordered] @{
                    errorId    = 'HDTFileSystemError'
                    path       = [string] $path
                    volume     = $root
                    exception  = $_.Exception.GetType().FullName
                    message    = [string] $innermost.Message
                    stackTrace = $stack
                })

            $data['errorId'] = 'HDTFileSystemError'

            return (New-HDTStepResult -Status Failed -Message $said -Data $data)
        }

        Write-HDTLog -Context $Context.Log -Component $component -Event volume.delete `
            -Message ('deleted {0}, after an ACL reset' -f $path) `
            -Data ([ordered] @{ path = [string] $path; reset = $true })
    }

    Write-HDTLog -Context $Context.Log -Component $component -Event volume.clean `
        -Message ('{0} is empty but for this run''s own state: {1} entries deleted, {2} kept.' -f
            $root, $doomed.Count, $kept.Count) -Data $data

    return (New-HDTStepResult -Status Completed -Data $data `
            -Message ('{0} emptied: {1} entries deleted, {2} kept.' -f $root, $doomed.Count, $kept.Count))
}
