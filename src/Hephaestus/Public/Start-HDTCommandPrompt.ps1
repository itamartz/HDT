function Start-HDTCommandPrompt {
    <#
        .SYNOPSIS
            Opens a command prompt for the technician - MDT's "Exit to Command
            Prompt".

        .DESCRIPTION
            THE BUTTON HAD NO CALLER. The wizard has offered Open CMD since W2
            and returned 'CommandPrompt' by design, leaving the prompt to the
            caller - and no caller ever opened one. Pressing it closed the
            window and produced nothing at all, on every machine. This is what
            makes it do something.

            WHY IT DOES NOT GO THROUGH IProcessService.Start. That method
            redirects both pipes, sets CreateNoWindow and waits for exit -
            correct for a command line step and wrong in all three ways here.
            A prompt opened through it would be invisible AND would freeze the
            wizard that opened it. StartInteractive is the separate verb.

            A MISSING ComSpec IS NOT A REASON TO REFUSE. The technician asked
            for a prompt because something on this machine is already wrong;
            answering "I could not read an environment variable" is the least
            useful thing this could do. So ComSpec wins when it says something
            and 'cmd.exe' is used when it does not.

            NOR IS A PROMPT THAT WOULD NOT OPEN. The wizard window is already
            closing by the time this runs, so an exception here would take the
            deployment with it and leave a blank screen - strictly worse than
            the missing prompt it would be reporting. It comes back as Started
            false with the reason, and the caller decides.

            THE CONSOLE IS NOT THIS COMMAND'S BUSINESS. In WinPE the payload
            hid the console to put the wizard on screen and restores it with
            Hide-HDTShellWindow -Restore; that is a Win32 call on this process's
            own window and has nothing to do with starting another one. Two
            things, two commands, at one call site.

        .PARAMETER WorkingDirectory
            Where the prompt opens. Omitted, it inherits this process's.

        .PARAMETER Process
            An IProcessService. Defaults to the real adapter.

        .PARAMETER Environment
            An IEnvironmentProvider, for ComSpec. Defaults to the real adapter;
            null is not an error and means 'cmd.exe'.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Started, FilePath,
            ProcessId and Message.

        .EXAMPLE
            Start-HDTCommandPrompt

            Opens a prompt in a window of its own.

        .EXAMPLE
            if ($answer.Action -eq 'CommandPrompt') {
                [void] (Start-HDTCommandPrompt)
                [void] (Hide-HDTShellWindow -Restore)
                return
            }

            What every wizard caller does: open the prompt, put the console the
            wizard hid back, and stop - the technician asked to leave.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens an interactive window the technician explicitly asked for; it changes no system state and a confirmation prompt on a machine with no keyboard focus is worse than the action.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string] $WorkingDirectory = '',

        [Parameter()]
        [AllowNull()]
        [object] $Process,

        [Parameter()]
        [AllowNull()]
        [object] $Environment
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Process) { $Process = New-HDTProcessService }
    if (-not $PSBoundParameters.ContainsKey('Environment')) { $Environment = New-HDTEnvironmentProvider }

    $filePath = 'cmd.exe'
    if ($null -ne $Environment) {
        $comSpec = [string] $Environment.GetVariable('ComSpec')
        if (-not [string]::IsNullOrWhiteSpace($comSpec)) { $filePath = $comSpec }
    }

    # NO ARGUMENTS. cmd.exe /c would run nothing and close again immediately,
    # which from the technician's side is the same dead button this replaces.
    try {
        $started = $Process.StartInteractive($filePath, '', $WorkingDirectory)

        return [pscustomobject] @{
            Started   = $true
            FilePath  = $filePath
            ProcessId = [int] $started.ProcessId
            Message   = ''
        }
    } catch {
        return [pscustomobject] @{
            Started   = $false
            FilePath  = $filePath
            ProcessId = 0
            Message   = ('the command prompt ''{0}'' could not be opened: {1}' -f $filePath, [string] $_.Exception.Message)
        }
    }
}
