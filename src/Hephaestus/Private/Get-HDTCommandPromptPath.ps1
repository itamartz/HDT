function Get-HDTCommandPromptPath {
    <#
        .SYNOPSIS
            The executable a command prompt opens from on this machine.

        .DESCRIPTION
            ONE RULE, TWO CALLERS, WHICH IS WHY IT IS A FUNCTION.
            Start-HDTCommandPrompt resolved ComSpec inline and that was fine
            while it was the only thing opening a prompt. F8 in the PROGRESS
            window is the second caller, and it cannot use that command at all:
            that window runs in its own STA runspace with no Hephaestus module
            loaded, so it is handed the path and starts it there.

            Two copies of "which cmd.exe" is two answers on the machine where it
            matters, so there is one.

            A MISSING ComSpec IS NOT AN ERROR. The technician pressed F8 because
            something on this machine is already wrong; answering "I could not
            read an environment variable" is the least useful thing this could
            do. So ComSpec wins when it says something and 'cmd.exe' is used
            when it does not - WinPE always has one on the path.

        .PARAMETER Environment
            An IEnvironmentProvider. Null is not an error and means 'cmd.exe'.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - always a usable value, never empty.

        .EXAMPLE
            Get-HDTCommandPromptPath -Environment (New-HDTEnvironmentProvider)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object] $Environment
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Environment) { return 'cmd.exe' }

    $comSpec = [string] $Environment.GetVariable('ComSpec')
    if ([string]::IsNullOrWhiteSpace($comSpec)) { return 'cmd.exe' }

    return $comSpec
}
