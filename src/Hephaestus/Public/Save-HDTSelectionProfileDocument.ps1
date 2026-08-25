function Save-HDTSelectionProfileDocument {
    <#
        .SYNOPSIS
            Writes a selection profile document, refusing to write one the engine
            could not read back.

        .DESCRIPTION
            The only thing in this family that touches the share. New-, Set- and
            Remove- return lines; this is what makes them a file.

            NOTHING UNREADABLE REACHES THE SHARE. The lines are parsed and
            validated from an IN-MEMORY copy at the real path first, so a message
            names the file the administrator is editing, and a failure leaves what
            was already there untouched. A boot image build reads this document;
            a half-written one is a build that fails at the point drivers are
            injected, minutes in.

            IT KEEPS THE FILE'S OWN LINE ENDINGS. A document authored on this
            share stays CRLF and one that arrived LF stays LF, so a save does not
            show up as every line changed in a diff.

        .PARAMETER Path
            The document to write - Control\selection-profiles.yaml on the share.

        .PARAMETER Line
            The document, as lines.

        .PARAMETER FileSystem
            The IFileSystem to write with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Saved, Path and
            Count - the number of profiles the document now declares.

        .EXAMPLE
            $path = 'C:\HDTLab\Share\Control\selection-profiles.yaml'
            $line = New-HDTSelectionProfile -Line ([string[]] @()) -Id 'boot-critical' -Name 'Boot critical - Dell and HP' -Include 'Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64'
            Save-HDTSelectionProfileDocument -Path $path -Line $line

            The first profile on a share, written.

        .EXAMPLE
            $path = 'C:\HDTLab\Share\Control\selection-profiles.yaml'
            $line = [string[]] @([System.IO.File]::ReadAllLines($path))
            $line = Remove-HDTSelectionProfile -Line $line -Id 'dell-winpe'
            Save-HDTSelectionProfileDocument -Path $path -Line $line -WhatIf

            What the save would do, without doing it. The document is still
            parsed and validated first, so this reports an unreadable edit
            without writing one.

        .LINK
            New-HDTSelectionProfile

        .LINK
            Get-HDTSelectionProfile
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # -- the file's own line endings ------------------------------------------

    $newLine = "`r`n"

    if ($FileSystem.TestPath($Path)) {
        $existing = [string] $FileSystem.ReadAllText($Path)

        # A lone LF anywhere means the file is not CRLF; a CR always paired with
        # an LF means it is.
        if ($existing -match "[^`r]`n" -or $existing -match "^`n") {
            $newLine = "`n"
        }
    }

    $text = ($Line -join $newLine)

    # -- the engine has to be able to read it ---------------------------------

    $document = ConvertFrom-HDTYaml -Yaml $text -Path $Path
    Assert-HDTSelectionProfileDocument -Document $document -Path $Path

    $count = 0
    if (($null -ne $document) -and $document.Contains('profiles') -and ($null -ne $document['profiles'])) {
        $count = @($document['profiles']).Count
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write the selection profile document')) {
        return [pscustomobject] @{ Saved = $false; Path = $Path; Count = $count }
    }

    $FileSystem.WriteAllText($Path, $text)

    return [pscustomobject] @{ Saved = $true; Path = $Path; Count = $count }
}
