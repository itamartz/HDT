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

        .PARAMETER Clock
            An IClock, used to stamp updatedUtc. Mandatory: PROJECT constraint 4
            forbids engine logic from reading the wall clock directly.

        .PARAMETER MirrorPath
            A second location to write the identical document to, conventionally
            the target volume's \HDT\state.json once one is formatted.

        .OUTPUTS
            None.

        .EXAMPLE
            Save-HDTRunState -State $state -Path 'X:\HDT\state.json' `
                -FileSystem $fileSystem -Clock $clock -MirrorPath 'W:\HDT\state.json'
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

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
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

    $State.updatedUtc = $Clock.GetUtcNow().ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    # Serialised once, so the mirror is byte-for-byte the document at Path.
    $json = ConvertTo-Json -InputObject $State -Depth 8

    if ($PSCmdlet.ShouldProcess($Path, 'Write run state')) {
        $FileSystem.WriteAllText($Path, $json)
    }

    if ($PSBoundParameters.ContainsKey('MirrorPath')) {
        if ($PSCmdlet.ShouldProcess($MirrorPath, 'Mirror run state')) {
            $FileSystem.WriteAllText($MirrorPath, $json)
        }
    }
}
