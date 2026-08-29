function Get-HDTConsoleTitle {
    <#
        .SYNOPSIS
            The console's title bar text: the product name from the string
            table, with the engine version after it.

        .DESCRIPTION
            WHICH ENGINE AM I LOOKING AT? Until this existed the only way to
            answer that was to type a command. A stale boot image carrying
            engine 0.8.0 against a share that had moved on cost a morning, and
            a glance at a title bar would have ended it in a second.

            THE TITLE BAR IS WHERE IT BELONGS ON THIS WINDOW. It is on screen
            the whole time, it is what a screenshot attached to a support
            question catches, and it takes no room a control wanted. The child
            dialogs - the boot image editor, the sequence editor, the import
            windows - deliberately do not carry it: they run in the same process
            as the console that opened them, so a version on each of them is one
            number written six times, which is noise and six places to drift.

            THE STATIC HALF IS THE TABLE'S AND THE NUMBER IS THE BUILD'S. Every
            other word on the console comes from Strings\en-us.psd1, found by
            control name, and the title is no exception - 'HDTConsoleWindow.Title'
            in the Console block. What a table cannot hold is a value that
            changes when somebody edits the engine, so the version is composed
            around the table's text here rather than written into it.

            AND IT IS NEVER A LITERAL. Get-HDTModuleVersion reads the manifest
            the build stamps, so a title that disagrees with the manifest is
            impossible rather than merely unlikely. A hard-coded number would be
            the exact failure this exists to stop.

            A MISSING VERSION GIVES THE PLAIN NAME. Hephaestus.psm1 can be
            dot-sourced rather than imported, and $MyInvocation.MyCommand.Module
            is $null when it is; a title ending in a trailing space would be a
            worse answer than no number at all.

        .PARAMETER Text
            The product name. Omitted, the string table's Console block decides
            it - which is what the console does, so the table stays the one
            place the words are written.

        .PARAMETER Version
            The version to show. Omitted, Get-HDTModuleVersion decides it. Pass
            $null or an empty string for a title with no version on it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String

        .EXAMPLE
            Get-HDTConsoleTitle

            'Hephaestus Deployment Toolkit 0.10.2' - the shipped name and the
            version of the module answering.

        .EXAMPLE
            Get-HDTConsoleTitle -Text 'HDT' -Version '0.9.9'

            'HDT 0.9.9'. Both halves given, which is what a test does.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text = '',

        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [object] $Version
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $name = [string] $Text

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [string] (Get-HDTStringTable -Page 'Console')['HDTConsoleWindow.Title']
    }

    # NOT BOUND IS NOT THE SAME AS BOUND TO $null. Omitting -Version means "ask
    # the manifest"; passing $null means "there is no version, show none" - and
    # a caller that has already read it must be able to say so without this
    # reading it again.
    $stamp = ''
    if ($PSBoundParameters.ContainsKey('Version')) {
        if ($null -ne $Version) { $stamp = ([string] $Version).Trim() }
    } else {
        $module = Get-HDTModuleVersion
        if ($null -ne $module) { $stamp = ([string] $module).Trim() }
    }

    if ([string]::IsNullOrWhiteSpace($stamp)) { return $name.Trim() }

    return ('{0} {1}' -f $name.Trim(), $stamp)
}
