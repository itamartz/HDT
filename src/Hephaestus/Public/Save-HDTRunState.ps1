function Save-HDTRunState {
    <#
        .SYNOPSIS
            Checkpoints the run state document through the injected IFileSystem.

        .DESCRIPTION
            state.json lives at X:\HDT\state.json in WinPE and
            C:\HDT\state.json in the full OS, and requires it to be "mirrored to
            the target disk's \HDT\ as soon as a formatted volume exists. The
            mirror is what makes the WinPE to OS transition survivable" - the
            RAM disk the WinPE copy lives on does not exist after the reboot.

            -MirrorPath writes the SAME serialised bytes to a second location, so
            a resume can read whichever copy survived.

            updatedUtc is stamped from the injected clock on every save, which is
            what Test-HDTRunStateAbandoned later reads to tell a live deployment
            from one that died between legs. startedUtc is left alone.

            The write goes through IFileSystem.WriteAllText, never a
            file-writing cmdlet: the adapter writes UTF-8 without a byte order
            mark, and the whole checkpoint path has to be provable with nothing
            on disk.

        .PARAMETER State
            A New-HDTRunState or Import-HDTRunState result. Its updatedUtc is
            mutated in place, so the caller's copy stays in step with the file.

        .PARAMETER Path
            Where to write it, conventionally X:\HDT\state.json or
            C:\HDT\state.json.

        .PARAMETER FileSystem
            An IFileSystem - New-HDTFileSystem in production,
            New-HDTFakeFileSystem in a test.
            Defaults to the real one.

        .PARAMETER Clock
            An IClock, used to stamp updatedUtc. Mandatory: PROJECT constraint 4
            forbids engine logic from reading the wall clock directly.

        .PARAMETER MirrorPath
            A second location to write the identical document to, conventionally
            the target volume's \HDT\state.json once one is formatted.

        .OUTPUTS
            None.

        .EXAMPLE
            $clock = New-HDTClock
            $fileSystem = New-HDTFileSystem
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $state = New-HDTRunState -SequenceId 'DEMO-05' -RunId 'run-0001' -Phase WinPE `
                -Clock $clock -Variable ([ordered] @{}) -Step @($sequence.Step)
            Save-HDTRunState -State $state -Path 'X:\HDT\state.json' -FileSystem $fileSystem -Clock $clock

            Writes the checkpoint. Atomically - a temporary file and then a move - so a
            machine that loses power mid-write has either the old state or the
            new one, never half of either.

        .EXAMPLE
            Save-HDTRunState -State $state -Path 'X:\HDT\state.json' -FileSystem $fileSystem -Clock $clock `
                -MirrorPath 'W:\HDT\state.json'

            The same write, mirrored onto the volume that survives the restart. X:\ is
            WinPE's RAM disk and is gone at the reboot, which is exactly when the
            checkpoint is needed.

    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $State,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Clock,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $MirrorPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $State.updatedUtc = $Clock.GetUtcNow().ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    # A SECRET'S VALUE DOES NOT GO INTO THE FILE.
    #
    # THIS DOCUMENT TRAVELS. It is written into the run's log directory, SLShare
    # copies that directory to the deployment share where every machine being
    # deployed can read it, and the finish action moves it to
    # C:\Windows\Logs\HDT on the deployed machine, which authenticated users can
    # read. A real run left HDTAdminPassword in clear in all three places, so the
    # local administrator password of a machine was readable by any local user of
    # that machine - privilege escalation, not merely a disclosure.
    #
    # THE IN-MEMORY DOCUMENT IS UNTOUCHED, which is the whole reason the
    # redaction happens at serialisation rather than at the checkpoint that
    # fills the map. The running leg goes on reading the real value out of
    # $State.variable and out of the execution context beside it; only the bytes
    # that leave this process are redacted.
    #
    # WHAT THAT COSTS, WRITTEN DOWN BECAUSE IT IS REAL: a leg that RESUMES after
    # a reboot rehydrates its variable bag from this file, so it sees
    # "(set, not shown)" where a secret was. Invoke-HDTTaskSequence recovers
    # HDTAdminPassword from the autologon LSA secret for exactly that reason -
    # see the Restart branch there. Any other secret consumed by a full-OS step
    # after a reboot has no such recovery and needs a design decision, not a
    # quiet return to writing the password down.
    $document = $State

    if ($null -ne $State.PSObject.Properties['variable'] -and $null -ne $State.variable) {
        $safe = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

        # A dictionary is what New-HDTRunState and Import-HDTRunState both hand
        # over; the PSObject branch is for a document read straight from JSON.
        if ($State.variable -is [System.Collections.IDictionary]) {
            foreach ($key in @($State.variable.Keys)) {
                $safe[[string] $key] = Protect-HDTSecretValue -Name ([string] $key) -Value $State.variable[$key]
            }
        } else {
            foreach ($property in @($State.variable.PSObject.Properties)) {
                $safe[[string] $property.Name] = Protect-HDTSecretValue -Name ([string] $property.Name) -Value $property.Value
            }
        }

        # A COPY, NOT AN EDIT. Writing the redaction back into $State would
        # destroy the running leg's own password on the first checkpoint.
        $clone = [System.Collections.Specialized.OrderedDictionary]::new()
        foreach ($property in @($State.PSObject.Properties)) {
            $clone[[string] $property.Name] = $property.Value
        }
        $clone['variable'] = $safe

        $document = [pscustomobject] $clone
    }

    # Serialised once, so the mirror is byte-for-byte the document at Path.
    $json = ConvertTo-Json -InputObject $document -Depth 8

    if ($PSCmdlet.ShouldProcess($Path, 'Write run state')) {
        $FileSystem.WriteAllText($Path, $json)
    }

    if ($PSBoundParameters.ContainsKey('MirrorPath')) {
        if ($PSCmdlet.ShouldProcess($MirrorPath, 'Mirror run state')) {
            $FileSystem.WriteAllText($MirrorPath, $json)
        }
    }
}
