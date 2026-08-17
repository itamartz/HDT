function ConvertFrom-HDTSequenceLine {
    <#
        .SYNOPSIS
            Reads a sequence document out of lines that are not on disk yet.

        .DESCRIPTION
            ConvertFrom-HDTWorkspaceLine, for sequence.yaml. An editing command
            holds lines rather than a file - Save-HDTSequenceDocument is the only
            thing that writes - so the guard "does this still parse" has to run
            against text.

            IT IS THE GUARD ON BOTH SIDES OF A SPLICE. Read before, to refuse
            editing a document that was already broken; read after, so a command
            that produced something unreadable says so instead of handing it back
            for Save to write.

            THE LOCATOR IS THE FILE'S NAME, not a path. These lines are not on a
            share yet, and a message naming one the administrator has never seen
            is worse than a message naming none.

        .PARAMETER Line
            The document, already split into lines.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - as
            Import-HDTSequenceDocument returns.

        .EXAMPLE
            [void] (ConvertFrom-HDTSequenceLine -Line $line)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $label = 'sequence.yaml'

    $reader = New-HDTFileSystemFromText -Path $label -Text (@($Line) -join "`n")

    return Import-HDTSequenceDocument -Path $label -FileSystem $reader
}
