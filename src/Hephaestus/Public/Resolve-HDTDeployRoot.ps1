function Resolve-HDTDeployRoot {
    <#
        .SYNOPSIS
            Answers "which drive is the content on" without naming a letter.

        .DESCRIPTION
            THE DIFFERENCE BETWEEN A BOOT IMAGE THAT DEPLOYS AND ONE THAT SITS
            THERE. A lab test recorded WinPE assigning the CONTENT DISK C:
            and the RAM disk X:, so a deployRoot baked into bootstrap.json at
            build time cannot know what a machine that has not booted yet will
            hand out. This turns what the image says into a path that exists on
            this machine.

            THE ENUMERATION IS DELIBERATELY NOT ITS JOB. The caller hands it
            candidate volume roots; this decides between them. That is the same
            split Select-HDTTargetDisk already uses - the service enumerates, the
            function decides - and it is what keeps the whole decision provable
            under Pester on a machine with one disk.

            SIX RULES:

              1. Smb -> the deployRoot unchanged, Source 'Configured'. A UNC
                 needs no volume, and the share is not reachable until the
                 provider maps it, so nothing is probed.
              2. Local, ROOTED, and the marker is under it -> unchanged,
                 Source 'Configured'.
              3. Local, VOLUME-RELATIVE (one leading separator, not two) -> the
                 marker is looked for under each candidate IN THE ORDER GIVEN,
                 first hit wins, Source 'Discovered'.
              4. Local, rooted, but the marker is NOT there -> the same probe,
                 using the path's volume-relative form, and a warning naming
                 both. A boot image that was right yesterday should not be
                 unbootable because a disk was added.
              5. Nothing matched -> HDTConfigurationError naming the deployRoot,
                 the marker AND every candidate it looked at, in order. That
                 sentence is the last thing a machine with no operator will ever
                 say, so it says everything a human needs to fix it.
              6. More than one candidate matched -> the first wins and a warning
                 names all of them. Refusing would strand a machine over a stale
                 second copy; silence would hide the ambiguity.

            The marker defaults to rules.yaml, the rules file, which sits at
            the root of every workspace.

            Candidate on the returned row is what it considered, so RESULT.json
            can record what the machine SAW as well as what it chose - which is
            what a support call needs when the answer was wrong.

            NO DRIVE LETTER IS WRITTEN IN THIS FILE, and
            tests/unit/Resolve-HDTDeployRoot.Tests.ps1 asserts it over the
            comment-free token stream.

        .PARAMETER DeployRoot
            What bootstrap.json says. A UNC share, a rooted local path, or a
            volume-relative path beginning with one separator.

        .PARAMETER Provider
            Smb or Local.

        .PARAMETER CandidateRoot
            The volume roots to look under, in priority order. The caller
            enumerates them; Start-HDTDeployment.ps1 uses
            [System.IO.DriveInfo]::GetDrives().

        .PARAMETER Marker
            The file that identifies a workspace root. Defaults to rules.yaml.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, Source
            (Configured or Discovered), Marker and Candidate.

        .EXAMPLE
            Resolve-HDTDeployRoot -DeployRoot '\\server\HdtShare' -Provider Smb

            The share, unchanged, Source Configured.

        .EXAMPLE
            $volume = @([System.IO.DriveInfo]::GetDrives() |
                Where-Object { $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName })
            Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local -CandidateRoot $volume

            What the boot image carries, turned into the volume this machine
            actually has.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $DeployRoot,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('Smb', 'Local')]
        [string] $Provider,

        [Parameter()]
        [AllowNull()]
        [string[]] $CandidateRoot,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Marker = 'rules.yaml',

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) {
        $FileSystem = New-HDTFileSystem
    }

    $row = {
        param([string] $Path, [string] $Source, [string[]] $Candidate)

        return [pscustomobject] ([ordered] @{
                Path      = $Path
                Source    = $Source
                Marker    = $Marker
                Candidate = [string[]] $Candidate
            })
    }

    # RULE 1. A UNC needs no volume, and probing a share nothing has mapped yet
    # would fail on every correct configuration.
    if ($Provider -eq 'Smb') {
        return (& $row $DeployRoot 'Configured' @())
    }

    $candidate = [string[]] @($CandidateRoot | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # GetPathRoot rather than a regular expression, so no drive letter is written
    # in this file at all: 'D:\Share' gives 'D:\', '\Share' gives one separator,
    # '\\server\share\x' gives the share and a relative path gives nothing.
    $pathRoot = [string] [System.IO.Path]::GetPathRoot($DeployRoot)
    $isRooted = $pathRoot.Length -gt 1

    # RULE 2. Configured, and there.
    if ($isRooted -and $FileSystem.TestPath([System.IO.Path]::Combine($DeployRoot, $Marker))) {
        return (& $row $DeployRoot 'Configured' $candidate)
    }

    # RULES 3 and 4 share the probe. The volume-relative form of a rooted path is
    # what is left after its own root is taken off.
    $relative = $DeployRoot
    if ($pathRoot.Length -gt 0) {
        $relative = $DeployRoot.Substring($pathRoot.Length)
    }
    $relative = $relative.Trim('\', '/')

    $matched = New-Object -TypeName System.Collections.ArrayList

    foreach ($volume in $candidate) {
        $probe = $volume
        if (-not [string]::IsNullOrEmpty($relative)) {
            $probe = [System.IO.Path]::Combine($volume, $relative)
        }

        if ($FileSystem.TestPath([System.IO.Path]::Combine($probe, $Marker))) {
            [void] $matched.Add($probe)
        }
    }

    # RULE 5. Everything it looked at, in the order it looked.
    if ($matched.Count -eq 0) {
        $looked = 'no candidate volume was offered at all'
        if ($candidate.Count -gt 0) {
            $looked = "the candidate volumes it looked under, in order, were: {0}" -f ($candidate -join ', ')
        }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                    -Message ("the deployment content could not be found. bootstrap.json names deployRoot '{0}', the workspace marker is '{1}', and {2}. Nothing under any of them carries the marker, so this machine has no content to deploy from." -f
                        $DeployRoot, $Marker, $looked) `
                    -TargetObject $DeployRoot `
                    -Category ObjectNotFound))
    }

    $chosen = [string] $matched[0]

    # RULE 6. First wins, and say what else was there.
    if ($matched.Count -gt 1) {
        Write-Warning ("More than one candidate volume carries '{0}': {1}. HDT is using '{2}', the first in the order it was given - refusing would strand this machine over a stale second copy, but a deployment reading the wrong one is worth saying out loud." -f
            $Marker, (@($matched) -join ', '), $chosen)
    }

    # RULE 4's warning. A boot image that was right yesterday should not be
    # unbootable because a disk was added, but the drift is worth a line.
    if ($isRooted) {
        Write-Warning ("bootstrap.json names deployRoot '{0}', and '{1}' is not there. The content was found at '{2}' instead - the volume letters this machine was given are not the ones the boot image was built with." -f
            $DeployRoot, [System.IO.Path]::Combine($DeployRoot, $Marker), $chosen)
    }

    return (& $row $chosen 'Discovered' $candidate)
}
