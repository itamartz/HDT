function Save-HDTOperatingSystemDocument {
    <#
        .SYNOPSIS
            Writes an os.yaml back to the share, after checking it.

        .DESCRIPTION
            THE ONLY COMMAND THAT WRITES A CATALOG ENTRY, and the one place the
            check lives. Set-HDTOperatingSystemProperty returns lines and touches
            nothing; this validates them with Assert-HDTOperatingSystemDocument
            and only then replaces the file - the same split, and the same
            reason, as Save-HDTSequenceDocument.

            A WINDOW THAT WROTE AN UNREADABLE os.yaml would take the share's
            Operating Systems branch down with it: the console would show
            '(unreadable)' where the media used to be, and nothing on that screen
            would say what had gone wrong or how to get it back. Refusing before
            the write leaves the file that was already there.

            THE FILE'S OWN LINE ENDINGS ARE KEPT. A document written CRLF stays
            CRLF, so an edit is a one-line diff rather than a whole-file one -
            "a UI that reformats the file breaks git review" (DESIGN 12).

        .PARAMETER Path
            The os.yaml to write.

        .PARAMETER Line
            The document, as lines.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the path written.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\OperatingSystems\Win11-LTSC-2024\os.yaml'))
            $line = Set-HDTOperatingSystemProperty -Line $line -Name 'Windows 11 LTSC 2024'
            Save-HDTOperatingSystemDocument -Path 'C:\HDTLab\Share\OperatingSystems\Win11-LTSC-2024\os.yaml' -Line $line

            Writes the lines back. Every editor in this module hands back lines rather
            than a document, and this is what puts them on disk.

        .EXAMPLE
            Save-HDTOperatingSystemDocument -Path 'C:\HDTLab\Share\OperatingSystems\Win11-LTSC-2024\os.yaml' -Line $line -WhatIf

            Says what it would write and writes nothing. The write is atomic - a
            temporary file, then a move - so an interrupted save cannot leave a
            half-written os.yaml behind.

        .LINK
            Set-HDTOperatingSystemProperty
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
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

    $text = @($Line) -join "`r`n"

    # THE FILE'S OWN ENDINGS, read before it is replaced.
    if ($FileSystem.TestPath($Path)) {
        $existing = [string] $FileSystem.ReadAllText($Path)
        if ($existing -notmatch "`r`n" -and $existing -match "`n") {
            $text = @($Line) -join "`n"
        }
    }

    # CHECKED BEFORE IT IS WRITTEN, NEVER AFTER.
    [void] (Assert-HDTOperatingSystemDocument -Document (ConvertFrom-HDTYaml -Yaml $text -Path $Path) -Path $Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'write the operating system document')) { return $Path }

    $FileSystem.WriteAllText($Path, $text)

    return $Path
}
