function Get-HDTConsoleNewMedia {
    <#
        .SYNOPSIS
            What the New Media dialog offers: this share's selection profiles.

        .DESCRIPTION
            THE NEW MEDIA DIALOG, ANSWERED WITHOUT A WINDOW. It asks four
            questions - id, name, selection profile, output - and writes one
            file through New-HDTMedia, which plan 07-01 already built and
            unit-tested. What it OFFERS is the interesting part, and it is
            decided here so ShowNewMedia can show rows without deciding
            anything itself.

            THE PROFILE LIST IS THE SHARE'S AND THE TOOLKIT'S OWN, through
            Get-HDTSelectionProfile - the same command New-HDTMedia checks the
            typed value against. A picker offering something New-HDTMedia
            would refuse is a dialog that fails on its last press; every value
            this returns is one New-HDTMedia will accept.

            A SHARE WITH NO Control\selection-profiles.yaml STILL ANSWERS.
            Get-HDTSelectionProfile falls back to the built-ins - everything,
            all-drivers - on its own, so there is nothing to catch here.

        .PARAMETER Workspace
            The deployment share's root.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with SelectionProfile.

        .EXAMPLE
            (Get-HDTConsoleNewMedia -Workspace C:\HDTLab\Share).SelectionProfile
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Media is a mass noun here and the singular name of one object, matching New-HDTMedia (DESIGN 6.2) and the dialog this answers for. The analyzer reads it as the Latin plural of medium.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Workspace,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # -FileSystem IS FORWARDED, and 07-03's own plan named the exact defect a
    # dropped forward produces here: Get-HDTSelectionProfile defaults to the
    # REAL adapter, so a call that omitted it would answer from whatever this
    # machine happens to have on disk rather than from the share this dialog
    # was opened on.
    $available = @(Get-HDTSelectionProfile -Root $Workspace -FileSystem $FileSystem)

    return [pscustomobject] @{
        SelectionProfile = [pscustomobject[]] @($available)
    }
}
