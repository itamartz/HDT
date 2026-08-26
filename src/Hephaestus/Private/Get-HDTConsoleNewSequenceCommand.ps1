function Get-HDTConsoleNewSequenceCommand {
    <#
        .SYNOPSIS
            The New Task Sequence window's footer line: the whole invocation
            Create would run, as an administrator would retype it.

        .DESCRIPTION
            DESIGN 12 IS THE WHOLE REASON THIS EXISTS - "every action it
            performs maps to a cmdlet invocation, and the console shows that
            invocation, so an admin can learn the automation surface by clicking
            around, and script anything they can do in the UI."

            THE FOOTER USED TO NAME A DIFFERENT COMMAND FROM THE BUTTON BESIDE
            IT. The window collects seven answers and Create passes four of them
            through -Variable - the operating system, the registered owner, the
            organisation and the local administrator password. The line showed
            the first three parameters and stopped, so an administrator who
            copied it, which is the one thing the line is for, got a task
            sequence with no operating system and no administrator password, and
            nothing on screen had said so.

            THE PASSWORD IS NAMED AND NOT PRINTED. It is stored readable in the
            sequence, deliberately and for MDT's reason - WinPE uses it with
            nobody present - and Get-HDTConsoleNewSequence says so in the hint on
            that box. A footer is none of those places: it is selectable, it is
            what gets copied into a ticket, and it is what a screenshot of this
            window carries. So the KEY appears, because a line that quietly
            dropped it would be the same defect over again, and the VALUE is the
            label in angle brackets for somebody to replace.

            WHICH KEY IS SECRET IS NOT DECIDED HERE. Get-HDTConsoleNewSequence
            marks it, this reads the mark, and a key added there tomorrow is
            masked by that row alone. A caller that passes no -Setting has
            declared no secret and gets none masked, which is the honest reading
            of an absent declaration rather than a guess about key names.

            AN EMPTY HASH IS NOT AN ANSWER. Create omits -Variable when nothing
            beyond the id, the name and the template was typed, and so does this.

        .PARAMETER Workspace
            The share the sequence is being created on.

        .PARAMETER Id
            The task sequence id, which is also its folder name.

        .PARAMETER Name
            What the sequence is called.

        .PARAMETER Template
            The template it is built from. Unquoted in the line, because it is a
            value from a fixed set rather than free text.

        .PARAMETER Variable
            The variables Create would write, in the order it would write them.
            Empty, or omitted, renders no -Variable at all.

        .PARAMETER Setting
            Get-HDTConsoleNewSequence's Setting rows, which is where a key is
            marked Secret. Omitted, nothing is masked.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - one line, ready to paste.

        .EXAMPLE
            Get-HDTConsoleNewSequenceCommand -Workspace 'C:\Share' -Id 'WIN11' `
                -Name 'Windows 11' -Template 'client'

            New-HDTTaskSequence -Workspace 'C:\Share' -Id 'WIN11' -Name 'Windows 11' -Template client
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Workspace,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Id,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string] $Name,

        [Parameter(Position = 3)]
        [AllowEmptyString()]
        [string] $Template = 'client',

        [Parameter()]
        [AllowNull()]
        [object] $Variable,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Setting
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A POWERSHELL LITERAL, NOT A VALUE WITH QUOTES ROUND IT. A share called
    # Frank's is ordinary, and a line that broke on one would be a line nobody
    # could paste - which is the only thing this string is for.
    $literal = {
        param([string] $Value)

        return "'" + ($Value -replace "'", "''") + "'"
    }

    $line = "New-HDTTaskSequence -Workspace {0} -Id {1} -Name {2} -Template {3}" -f
        (& $literal $Workspace), (& $literal $Id), (& $literal $Name), $Template

    if ($null -eq $Variable) { return $line }

    $key = @($Variable.Keys)
    if ($key.Count -eq 0) { return $line }

    # THE KEYS THE SETTING ROWS MARK Secret, as a plain list. A row that carries
    # no Secret property at all is not secret: this window's rows all have one,
    # and a caller passing its own rows should not have to.
    $secret = New-Object -TypeName System.Collections.ArrayList
    $label = @{}

    foreach ($row in @($Setting)) {
        if ($null -eq $row) { continue }
        if (-not ($row.PSObject.Properties.Name -contains 'Secret')) { continue }
        if (-not [bool] $row.Secret) { continue }

        [void] $secret.Add([string] $row.Key)
        $label[[string] $row.Key] = [string] $row.Label
    }

    $pair = New-Object -TypeName System.Collections.ArrayList

    foreach ($one in $key) {
        $name = [string] $one
        $value = [string] $Variable[$one]

        if ($secret -contains $name) {
            $stand = $name
            if ($label.ContainsKey($name)) { $stand = ([string] $label[$name]).ToLowerInvariant() }

            $value = '<{0}>' -f $stand
        }

        [void] $pair.Add(('{0} = {1}' -f $name, (& $literal $value)))
    }

    # [ordered], BECAUSE CREATE PASSES ONE. A plain hash pasted back would write
    # the same variables in whatever order it enumerated them, and the file this
    # window produces would stop being the file the line produces.
    return '{0} -Variable ([ordered] @{{ {1} }})' -f $line, (@($pair) -join '; ')
}
