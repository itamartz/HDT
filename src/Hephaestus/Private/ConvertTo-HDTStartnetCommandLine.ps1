function ConvertTo-HDTStartnetCommandLine {
    <#
        .SYNOPSIS
            Turns a start command as the administrator authored it into the line
            startnet.cmd actually carries.

        .DESCRIPTION
            ONE RULE, AND IT IS ABOUT cmd.exe RATHER THAN ABOUT HDT: a batch
            file invoked from a batch file TRANSFERS control and does not come
            back. A bare `X:\Tools\run.cmd` line in startnet.cmd means the entry
            command below it - the deployment - is never reached, and the
            machine sits wherever run.cmd left it, having booted, initialised
            and started the administrator's tools. It looks exactly like a
            deployment that hung.

            So a .cmd or .bat is emitted with `call`. What the administrator
            typed is what workspace.yaml keeps; this is the translation, applied
            where cmd is written.

            IT IS ITS OWN FUNCTION BECAUSE TWO THINGS NEED THE SAME ANSWER.
            Get-HDTStartnetScript writes the file; Get-HDTConsoleBootImageSetting shows
            the WinPE window what the file will say. A window that displayed the
            raw document line would be hiding the single most surprising thing
            about the file it builds, and a second copy of this rule is a second
            copy to get wrong.

            ALREADY-DIRECTED LINES ARE LEFT ALONE. `call` twice is a rewrite of
            an instruction that was already right, and `start` returns
            immediately by design - it is what an administrator writes for a
            tool that has to stay up.

        .PARAMETER Command
            The command as authored.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the line startnet.cmd carries.

        .EXAMPLE
            ConvertTo-HDTStartnetCommandLine -Command 'X:\Tools\run.cmd'

            call X:\Tools\run.cmd

        .EXAMPLE
            ConvertTo-HDTStartnetCommandLine -Command 'X:\Tools\bginfo64.exe /timer:0'

            Unchanged - an .exe is a process, and cmd.exe carries on by itself.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Command
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $text = [string] $Command
    $leading = $text -replace '^\s+', ''

    # The first token, whether or not it is quoted. "X:\Program Files\a.cmd" is
    # one token with a space in it, and splitting on whitespace first would read
    # it as "X:\Program.
    $first = ''
    if ($leading -match '^"([^"]+)"') {
        $first = [string] $Matches[1]
    } else {
        $first = [string] @($leading -split '\s+')[0]
    }

    if ($leading -match '^(call|start)\s') { return $text }
    if ($first -notmatch '\.(cmd|bat)$') { return $text }

    return ('call {0}' -f $text)
}
