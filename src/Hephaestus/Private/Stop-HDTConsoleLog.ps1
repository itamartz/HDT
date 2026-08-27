function Stop-HDTConsoleLog {
    <#
        .SYNOPSIS
            Closes the console's log for this session.

        .DESCRIPTION
            RECORDS THAT THE WINDOW CLOSED, which is a fact worth having: a log
            that simply stops leaves a reader unable to tell a console somebody
            closed from one that died, and those want opposite investigations.

            AND IT CLEARS THE MODULE-SCOPE CONTEXT. Start-HDTConsoleLog holds one
            because the scriptblock Get-HDTHandlerCall returns has no other
            channel to reach it; anything held in module scope outlives the thing
            that made it unless something puts it down. A test that inherited a
            previous session's context would write into a directory it never
            named, and the next failure would be a mystery.

            IT NEVER THROWS, for the reason Start-HDTConsoleLog does not: this
            runs while a window is closing, often because something has already
            gone wrong, and a teardown that fails on top of that helps nobody.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            None.

        .EXAMPLE
            Stop-HDTConsoleLog

        .EXAMPLE
            try { Show-HDTConsole -Path 'C:\HDTLab\Share' } finally { Stop-HDTConsoleLog }

            The shape that matters: the close is recorded even when the window
            came down because something threw.

        .LINK
            Start-HDTConsoleLog
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Closes the current session log; it changes nothing on the deployment share.')]
    [CmdletBinding()]
    [OutputType([void])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    try {
        if ($null -ne $script:HDTConsoleLogContext) {
            Write-HDTLog -Context $script:HDTConsoleLogContext -Event 'console.session' `
                -Component 'Console' -Message 'console closed'
        }
    } catch {
        Write-Verbose ("the console log could not be closed cleanly: {0}" -f [string] $_.Exception.Message)
    }

    $script:HDTConsoleLogContext = $null
}
