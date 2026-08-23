function Get-HDTConsoleApplicationLabel {
    <#
        .SYNOPSIS
            What an application is called on screen - its name, with the version
            when the name does not already carry it.

        .DESCRIPTION
            NOT THE ID, WHICH THE OTHER TWO CATEGORIES SHOW. An application's id
            is composed FROM its name and version (New-HDTApplicationName), so a
            row showing both reads 'Igor-Pavlov-7-Zip-24.09 - Igor Pavlov 7-Zip
            24.09': the same sentence twice, once with the spaces hyphenated.

            AND THE VERSION IS WHAT MAKES TWO ENTRIES TELLABLE APART, so an entry
            whose name is just 'Acrobat Reader' gets it appended - and one whose
            name already ends with it does not say it twice.

            IT IS SHARED because the tree and the task sequence editor's
            application page must agree about it. Two copies of a display rule
            become two display rules the moment one of them is fixed, and then
            the row somebody ticks in the editor is not the row they read in the
            tree.

        .PARAMETER Name
            The application's name, as app.yaml records it.

        .PARAMETER Version
            Which version this entry installs. Empty is ordinary - a share full
            of entries written before the three-box dialog existed has none.

        .PARAMETER Id
            The folder name, used when the entry carries no name at all.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsoleApplicationLabel -Name 'Igor Pavlov 7-Zip' -Version '24.09' -Id 'Igor-Pavlov-7-Zip-24.09'

            'Igor Pavlov 7-Zip 24.09'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Name = '',

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Version = '',

        [Parameter(Position = 2)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Id = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $text = [string] $Name

    # THE ID IS THE FALLBACK, because a share whose app.yaml carries no name
    # leaves the folder as the only thing anybody has to go on.
    if ([string]::IsNullOrWhiteSpace($text)) { $text = [string] $Id }

    $stated = [string] $Version

    if (-not [string]::IsNullOrWhiteSpace($stated) -and $text -notmatch [regex]::Escape($stated)) {
        $text = '{0} {1}' -f $text, $stated
    }

    return [string] $text
}
