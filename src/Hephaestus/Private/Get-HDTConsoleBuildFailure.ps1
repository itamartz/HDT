function Get-HDTConsoleBuildFailure {
    <#
        .SYNOPSIS
            What the build window says when a build died without reporting why.

        .DESCRIPTION
            A RUNSPACE CAN FAIL BEFORE THE COMMAND RUNS AT ALL - a module that
            will not import, for instance - so Update-HDTBootImage never gets far
            enough to report its own failure. The error exists only in the
            runspace's streams, and a window that does not go looking for it
            tells the technician nothing about a build that just took two
            minutes.

            EndInvoke IS WHAT RAISES THE RUNSPACE'S TERMINATING ERROR, and that
            is the lesson this was built from. A build that threw OUTSIDE its own
            try - the ISO step is outside it - reports nothing AND leaves
            Streams.Error empty, so the window said "the build ended without
            saying why" about a failure PowerShell had been holding all along.

            THE ORDER IS THEREFORE NOT ARBITRARY. What EndInvoke raised comes
            first, because it is the error that stopped the build. The error
            stream is the fallback, for a failure that was never terminating but
            still ended the run. The generic sentence is what is left when there
            genuinely is nothing.

            AND THE GENERIC SENTENCE IS STILL AN ANSWER. A blank detail box on a
            failed build reads as a window that is broken rather than a build
            that is, and sends somebody looking in the wrong place.

            A BLANK IS NOT A MESSAGE. An empty or whitespace-only entry is
            skipped on both sides rather than displayed, because a box containing
            one space is the blank box this exists to avoid.

        .PARAMETER Raised
            What EndInvoke threw, if anything.

        .PARAMETER Streamed
            The runspace's error stream messages, most recent run first.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the sentence to show.

        .EXAMPLE
            Get-HDTConsoleBuildFailure -Raised 'oscdimg exited with 1'

        .EXAMPLE
            try { [void] $shell.EndInvoke($handle) } catch { $raised = $_.Exception.Message }
            $detailText.Text = Get-HDTConsoleBuildFailure -Raised $raised -Streamed @($shell.Streams.Error.Exception.Message)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Raised = '',

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Streamed = @()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # WHAT ENDINVOKE RAISED COMES FIRST. See the order note above.
    if (-not [string]::IsNullOrWhiteSpace($Raised)) { return $Raised }

    if ($null -ne $Streamed) {
        foreach ($one in @($Streamed)) {
            # A BLANK IS NOT A MESSAGE.
            if (-not [string]::IsNullOrWhiteSpace([string] $one)) { return [string] $one }
        }
    }

    # STILL AN ANSWER. See the note above.
    return 'the build ended without saying why'
}
