function Resolve-HDTErrorMessage {
    <#
        .SYNOPSIS
            The sentence somebody wrote, out of the layers of plumbing wrapped
            around it.

        .DESCRIPTION
            WHAT THE CONSOLE SHOWED A TECHNICIAN, verbatim, when a task sequence
            held two steps with the same name:

              Exception calling "Show" with "13" argument(s): "Exception calling
              "ShowDialog" with "0" argument(s): "Exception calling "ShowEditor"
              with "10" argument(s): "Exception calling "ShowDialog" with "0"
              argument(s): "Tattoo: this task sequence holds 2 steps called
              'Tattoo', so the one to act on is ambiguous. Rename one of them
              first.""""

            The last clause is the message. Everything in front of it is
            PowerShell saying that a method called a method called a method -
            true, and of no use whatever to the person in front of the window.
            The engine had written a good sentence and the dialog buried it four
            levels down behind a wall of quotes.

            WHY IT HAPPENS. Every ScriptMethod hop wraps a failure in a
            MethodInvocationException whose Message QUOTES the inner one, so
            reading .Exception.Message gets the outermost - which contains all of
            them, nested. The chain grows one layer per hop, and the console's
            host is several hops deep by design.

            SO IT WALKS TO THE BOTTOM. .InnerException is the real exception at
            every level; the innermost is the one that was actually thrown, and
            its Message is what a person should read.

            IT NEVER RETURNS NOTHING. A dialog with an empty body tells a
            technician less than no dialog at all, so an exception with a blank
            message falls back to its type name, and a null falls back to a
            sentence saying so. Both are worse than a real message and better
            than a blank window.

            IT IS PUBLIC BECAUSE THE LAUNCHER IS NOT IN THE MODULE.
            Start-HDTConsole.ps1 sits beside the manifest and imports it, so a
            private helper would be invisible to the one caller that needs it -
            the same reason the payloads use public commands.

        .PARAMETER Exception
            The exception to unwrap.

        .PARAMETER ErrorRecord
            An ErrorRecord to unwrap instead, which is what a catch block holds.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the innermost message, never empty.

        .EXAMPLE
            try { ... } catch { [System.Windows.MessageBox]::Show((Resolve-HDTErrorMessage -ErrorRecord $_)) }

            What the console launcher does, and why its dialogs are readable.

        .EXAMPLE
            Resolve-HDTErrorMessage -Exception $exception

            'this task sequence holds 2 steps called Tattoo, so the one to act
            on is ambiguous' - rather than four lines of "Exception calling".
    #>
    [CmdletBinding(DefaultParameterSetName = 'Exception')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Exception')]
        [AllowNull()]
        [System.Exception] $Exception,

        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ErrorRecord')]
        [AllowNull()]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $current = $Exception

    if ($PSCmdlet.ParameterSetName -eq 'ErrorRecord') {
        $current = $null
        if ($null -ne $ErrorRecord) { $current = $ErrorRecord.Exception }
    }

    if ($null -eq $current) {
        return 'The operation failed, and no exception was recorded to say why.'
    }

    # TO THE BOTTOM OF THE CHAIN. Bounded, because a cyclic InnerException would
    # otherwise be a console that hangs instead of a console that reports - and a
    # hang is the one failure nobody can screenshot.
    $guard = 0
    while ($null -ne $current.InnerException -and $guard -lt 32) {
        $current = $current.InnerException
        $guard++
    }

    $message = [string] $current.Message

    if ([string]::IsNullOrWhiteSpace($message)) {
        return ('{0} was thrown, and it carried no message.' -f $current.GetType().FullName)
    }

    return $message
}
