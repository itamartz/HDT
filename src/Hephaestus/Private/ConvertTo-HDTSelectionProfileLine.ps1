function ConvertTo-HDTSelectionProfileLine {
    <#
        .SYNOPSIS
            One selection profile, written as the lines it is in the document.

        .DESCRIPTION
            The renderer New- and Set- both splice with, so a profile written
            today and a profile rewritten tomorrow are spelled the same way and a
            diff shows what actually changed rather than a reflow.

            EVERY VALUE GOES THROUGH THE SHARED QUOTER. A profile name is
            whatever an administrator typed - 'Boot critical: Dell and HP' has a
            colon in it, and written bare that is a mapping. An include path is
            full of backslashes, which is why the quoter's single quotes matter:
            in a double-quoted YAML scalar '\W' is an escape sequence and
            'Drivers\WinPE' would not survive the trip.

            AN EMPTY include IS WRITTEN 'include: []', NOT OMITTED. The validator
            requires the key, and a profile being built up over an afternoon has
            to be a document the engine still loads.

        .PARAMETER Id
            The profile id.

        .PARAMETER Name
            What the console's picker shows.

        .PARAMETER Include
            The share-relative folders, in the order they should be injected.

        .PARAMETER Indent
            The column the entry's dash sits at.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[]

        .EXAMPLE
            ConvertTo-HDTSelectionProfileLine -Id 'boot-critical' -Name 'Boot critical - Dell and HP' -Include 'Drivers\WinPE\Dell WinPE 11 x64' -Indent 2
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Position = 2)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Include = @(),

        [Parameter()]
        [ValidateRange(0, 32)]
        [int] $Indent = 2
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $dash = ' ' * $Indent
    $key = ' ' * ($Indent + 2)
    $item = ' ' * ($Indent + 4)

    $line = New-Object -TypeName System.Collections.ArrayList

    [void] $line.Add(('{0}- id: {1}' -f $dash, (ConvertTo-HDTRuleScalarText -Value $Id)))
    [void] $line.Add(('{0}name: {1}' -f $key, (ConvertTo-HDTRuleScalarText -Value $Name)))

    if (@($Include).Count -eq 0) {
        [void] $line.Add(('{0}include: []' -f $key))
    } else {
        [void] $line.Add(('{0}include:' -f $key))

        foreach ($current in @($Include)) {
            [void] $line.Add(('{0}- {1}' -f $item, (ConvertTo-HDTRuleScalarText -Value ([string] $current))))
        }
    }

    return [string[]] @($line)
}
